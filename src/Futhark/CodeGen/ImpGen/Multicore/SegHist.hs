module Futhark.CodeGen.ImpGen.Multicore.SegHist
  ( compileSegHist,
  )
where

import Control.Monad
import Data.List (zip4, zip5)
import qualified Futhark.CodeGen.ImpCode.Multicore as Imp
import Futhark.CodeGen.ImpGen
import Futhark.CodeGen.ImpGen.Multicore.Base
import Futhark.CodeGen.ImpGen.Multicore.SegRed (compileSegRed')
import Futhark.IR.MCMem
import Futhark.MonadFreshNames
import Futhark.Util (chunks, splitFromEnd, takeLast)
import Futhark.Util.IntegralExp (rem)
import Prelude hiding (quot, rem)

compileSegHist ::
  Pat MCMem ->
  SegSpace ->
  [HistOp MCMem] ->
  KernelBody MCMem ->
  TV Int32 ->
  MulticoreGen Imp.Code
compileSegHist pat space histops kbody nsubtasks
  | [_] <- unSegSpace space =
    nonsegmentedHist pat space histops kbody nsubtasks
  | otherwise =
    segmentedHist pat space histops kbody

-- | Split some list into chunks equal to the number of values
-- returned by each 'SegBinOp'
segHistOpChunks :: [HistOp rep] -> [a] -> [[a]]
segHistOpChunks = chunks . map (length . histNeutral)

nonsegmentedHist ::
  Pat MCMem ->
  SegSpace ->
  [HistOp MCMem] ->
  KernelBody MCMem ->
  TV Int32 ->
  MulticoreGen Imp.Code
nonsegmentedHist pat space histops kbody num_histos = do
  let ns = map snd $ unSegSpace space
      ns_64 = map toInt64Exp ns
      num_histos' = tvExp num_histos
      hist_width = toInt64Exp $ histWidth $ head histops
      use_subhistogram = sExt64 num_histos' * hist_width .<=. product ns_64

  histops' <- renameHistOpLambda histops

  -- Only do something if there is actually input.
  collect $
    sUnless (product ns_64 .==. 0) $ do
      flat_idx <- dPrim "iter" int64
      sIf
        use_subhistogram
        (subHistogram pat flat_idx space histops num_histos kbody)
        (atomicHistogram pat flat_idx space histops' kbody)

-- |
-- Atomic Histogram approach
-- The implementation has three sub-strategies depending on the
-- type of the operator
-- 1. If values are integral scalars, a direct-supported atomic update is used.
-- 2. If values are on one memory location, e.g. a float, then a
-- CAS operation is used to perform the update, where the float is
-- casted to an integral scalar.
-- 1. and 2. currently only works for 32-bit and 64-bit types,
-- but GCC has support for 8-, 16- and 128- bit types as well.
-- 3. Otherwise a locking based approach is used
onOpAtomic :: HistOp MCMem -> MulticoreGen ([VName] -> [Imp.TExp Int64] -> MulticoreGen ())
onOpAtomic op = do
  atomics <- hostAtomics <$> askEnv
  let lambda = histOp op
      do_op = atomicUpdateLocking atomics lambda
  case do_op of
    AtomicPrim f -> return f
    AtomicCAS f -> return f
    AtomicLocking f -> do
      -- Allocate a static array of locks
      -- as in the GPU backend
      let num_locks = 100151 -- This number is taken from the GPU backend
          dims =
            map toInt64Exp $
              shapeDims (histShape op) ++ [histWidth op]
      locks <-
        sStaticArray "hist_locks" DefaultSpace int32 $
          Imp.ArrayZeros num_locks
      let l' = Locking locks 0 1 0 (pure . (`rem` fromIntegral num_locks) . flattenIndex dims)
      return $ f l'

atomicHistogram ::
  Pat MCMem ->
  TV Int64 ->
  SegSpace ->
  [HistOp MCMem] ->
  KernelBody MCMem ->
  MulticoreGen ()
atomicHistogram pat flat_idx space histops kbody = do
  let (is, ns) = unzip $ unSegSpace space
      ns_64 = map toInt64Exp ns
  let num_red_res = length histops + sum (map (length . histNeutral) histops)
      (all_red_pes, map_pes) = splitAt num_red_res $ patElems pat

  atomicOps <- mapM onOpAtomic histops

  body <- collect $ do
    zipWithM_ dPrimV_ is $ unflattenIndex ns_64 $ tvExp flat_idx
    compileStms mempty (kernelBodyStms kbody) $ do
      let (red_res, map_res) = splitFromEnd (length map_pes) $ kernelBodyResult kbody
          perOp = chunks $ map (length . histDest) histops
          (buckets, vs) = splitAt (length histops) red_res

      let pes_per_op = chunks (map (length . histDest) histops) all_red_pes
      forM_ (zip5 histops (perOp vs) buckets atomicOps pes_per_op) $
        \(HistOp dest_w _ _ _ shape lam, vs', bucket, do_op, dest_res) -> do
          let (_is_params, vs_params) = splitAt (length vs') $ lambdaParams lam
              dest_w' = toInt64Exp dest_w
              bucket' = toInt64Exp $ kernelResultSubExp bucket
              bucket_in_bounds = bucket' .<. dest_w' .&&. 0 .<=. bucket'

          sComment "save map-out results" $
            forM_ (zip map_pes map_res) $ \(pe, res) ->
              copyDWIMFix (patElemName pe) (map Imp.vi64 is) (kernelResultSubExp res) []

          sComment "perform updates" $
            sWhen bucket_in_bounds $ do
              let bucket_is = map Imp.vi64 (init is) ++ [bucket']
              dLParams $ lambdaParams lam
              sLoopNest shape $ \is' -> do
                forM_ (zip vs_params vs') $ \(p, res) ->
                  copyDWIMFix (paramName p) [] (kernelResultSubExp res) is'
                do_op (map patElemName dest_res) (bucket_is ++ is')

  free_params <- freeParams body (segFlat space : [tvVar flat_idx])
  emit $ Imp.Op $ Imp.ParLoop "atomic_seg_hist" (tvVar flat_idx) mempty body mempty free_params $ segFlat space

updateHisto :: HistOp MCMem -> [VName] -> [Imp.TExp Int64] -> MulticoreGen ()
updateHisto op arrs bucket = do
  let acc_params = take (length arrs) $ lambdaParams $ histOp op
      bind_acc_params =
        forM_ (zip acc_params arrs) $ \(acc_p, arr) ->
          copyDWIMFix (paramName acc_p) [] (Var arr) bucket
      op_body = compileBody' [] $ lambdaBody $ histOp op
      writeArray arr val = copyDWIMFix arr bucket val []
      do_hist = zipWithM_ writeArray arrs $ map resSubExp $ bodyResult $ lambdaBody $ histOp op

  sComment "Start of body" $ do
    dLParams acc_params
    bind_acc_params
    op_body
    do_hist

-- Generates num_histos sub-histograms of the size
-- of the destination histogram
-- Then for each chunk of the input each subhistogram
-- is computed and finally combined through a segmented reduction
-- across the histogram indicies.
-- This is expected to be fast if len(histDest) is small
subHistogram ::
  Pat MCMem ->
  TV Int64 ->
  SegSpace ->
  [HistOp MCMem] ->
  TV Int32 ->
  KernelBody MCMem ->
  MulticoreGen ()
subHistogram pat flat_idx space histops num_histos kbody = do
  emit $ Imp.DebugPrint "subHistogram segHist" Nothing

  let (is, ns) = unzip $ unSegSpace space
      ns_64 = map toInt64Exp ns

  let pes = patElems pat
      num_red_res = length histops + sum (map (length . histNeutral) histops)
      map_pes = drop num_red_res pes
      per_red_pes = segHistOpChunks histops $ patElems pat

  -- Allocate array of subhistograms in the calling thread.  Each
  -- tasks will work in its own private allocations (to avoid false
  -- sharing), but this is where they will ultimately copy their
  -- results.
  global_subhistograms <- forM histops $ \histop ->
    forM (histType histop) $ \t -> do
      let shape = Shape [tvSize num_histos] <> arrayShape t
      sAllocArray "subhistogram" (elemType t) shape DefaultSpace

  let tid' = Imp.vi64 $ segFlat space
      flat_idx' = tvExp flat_idx

  (local_subhistograms, prebody) <- collect' $ do
    zipWithM_ dPrimV_ is $ unflattenIndex ns_64 $ sExt64 flat_idx'

    forM (zip per_red_pes histops) $ \(pes', histop) -> do
      op_local_subhistograms <- forM (histType histop) $ \t ->
        sAllocArray "subhistogram" (elemType t) (arrayShape t) DefaultSpace

      forM_ (zip3 pes' op_local_subhistograms (histNeutral histop)) $ \(pe, hist, ne) ->
        -- First thread initializes histogram with dest vals. Others
        -- initialize with neutral element
        sIf
          (tid' .==. 0)
          (copyDWIMFix hist [] (Var $ patElemName pe) [])
          ( sFor "i" (toInt64Exp $ histWidth histop) $ \i ->
              sLoopNest (histShape histop) $ \vec_is ->
                copyDWIMFix hist (i : vec_is) ne []
          )

      return op_local_subhistograms

  -- Generate loop body of parallel function
  body <- collect $ do
    zipWithM_ dPrimV_ is $ unflattenIndex ns_64 $ sExt64 flat_idx'
    compileStms mempty (kernelBodyStms kbody) $ do
      let (red_res, map_res) = splitFromEnd (length map_pes) $ kernelBodyResult kbody
          (buckets, vs) = splitAt (length histops) red_res
          perOp = chunks $ map (length . histDest) histops

      sComment "save map-out results" $
        forM_ (zip map_pes map_res) $ \(pe, res) ->
          copyDWIMFix
            (patElemName pe)
            (map Imp.vi64 is)
            (kernelResultSubExp res)
            []

      forM_ (zip4 histops local_subhistograms buckets (perOp vs)) $
        \( histop@(HistOp dest_w _ _ _ shape lam),
           histop_subhistograms,
           bucket,
           vs'
           ) -> do
            let bucket' = toInt64Exp $ kernelResultSubExp bucket
                dest_w' = toInt64Exp dest_w
                bucket_in_bounds = bucket' .<. dest_w' .&&. 0 .<=. bucket'
                vs_params = takeLast (length vs') $ lambdaParams lam
                bucket_is = [bucket']

            sComment "perform updates" $
              sWhen bucket_in_bounds $ do
                dLParams $ lambdaParams lam
                sLoopNest shape $ \is' -> do
                  forM_ (zip vs_params vs') $ \(p, res) ->
                    copyDWIMFix (paramName p) [] (kernelResultSubExp res) is'
                  updateHisto histop histop_subhistograms (bucket_is ++ is')

  -- Copy the task-local subhistograms to the global subhistograms,
  -- where they will be combined.
  postbody <- collect $
    forM_ (zip (concat global_subhistograms) (concat local_subhistograms)) $
      \(global, local) -> copyDWIMFix global [tid'] (Var local) []

  free_params <- freeParams (prebody <> body <> postbody) (segFlat space : [tvVar flat_idx])
  let (body_allocs, body') = extractAllocations body
  emit $ Imp.Op $ Imp.ParLoop "seghist_stage_1" (tvVar flat_idx) (body_allocs <> prebody) body' postbody free_params $ segFlat space

  -- Perform a segmented reduction over the subhistograms
  forM_ (zip3 per_red_pes global_subhistograms histops) $ \(red_pes, hists, op) -> do
    bucket_id <- newVName "bucket_id"
    subhistogram_id <- newVName "subhistogram_id"

    let num_buckets = histWidth op
        segred_space =
          SegSpace (segFlat space) $
            segment_dims
              ++ [(bucket_id, num_buckets)]
              ++ [(subhistogram_id, tvSize num_histos)]

        segred_op = SegBinOp Noncommutative (histOp op) (histNeutral op) (histShape op)

    nsubtasks_red <- dPrim "num_tasks" $ IntType Int32
    red_code <- compileSegRed' (Pat red_pes) segred_space [segred_op] nsubtasks_red $ \red_cont ->
      red_cont $
        flip map hists $ \subhisto ->
          ( Var subhisto,
            map Imp.vi64 $
              map fst segment_dims ++ [subhistogram_id, bucket_id]
          )

    let ns_red = map (toInt64Exp . snd) $ unSegSpace segred_space
        iterations = product $ init ns_red -- The segmented reduction is sequential over the inner most dimension
        scheduler_info = Imp.SchedulerInfo (tvVar nsubtasks_red) (untyped iterations) Imp.Static
        red_task = Imp.ParallelTask red_code $ segFlat space
    free_params_red <- freeParams red_code [segFlat space, tvVar nsubtasks_red]
    emit $ Imp.Op $ Imp.Segop "seghist_red" free_params_red red_task Nothing mempty scheduler_info
  where
    segment_dims = init $ unSegSpace space

-- This implementation for a Segmented Hist only
-- parallelize over the segments,
-- where each segment is updated sequentially.
segmentedHist ::
  Pat MCMem ->
  SegSpace ->
  [HistOp MCMem] ->
  KernelBody MCMem ->
  MulticoreGen Imp.Code
segmentedHist pat space histops kbody = do
  emit $ Imp.DebugPrint "Segmented segHist" Nothing
  -- Iteration variable over the segments
  segments_i <- dPrim "segment_iter" $ IntType Int64
  collect $ do
    par_body <- compileSegHistBody (tvExp segments_i) pat space histops kbody
    free_params <- freeParams par_body [segFlat space, tvVar segments_i]
    let (body_allocs, body') = extractAllocations par_body
    emit $ Imp.Op $ Imp.ParLoop "segmented_hist" (tvVar segments_i) body_allocs body' mempty free_params $ segFlat space

compileSegHistBody ::
  Imp.TExp Int64 ->
  Pat MCMem ->
  SegSpace ->
  [HistOp MCMem] ->
  KernelBody MCMem ->
  MulticoreGen Imp.Code
compileSegHistBody idx pat space histops kbody = do
  let (is, ns) = unzip $ unSegSpace space
      ns_64 = map toInt64Exp ns

  let num_red_res = length histops + sum (map (length . histNeutral) histops)
      map_pes = drop num_red_res $ patElems pat
      per_red_pes = segHistOpChunks histops $ patElems pat

  collect $ do
    let inner_bound = last ns_64
    sFor "i" inner_bound $ \i -> do
      zipWithM_ dPrimV_ (init is) $ unflattenIndex (init ns_64) idx
      dPrimV_ (last is) i

      compileStms mempty (kernelBodyStms kbody) $ do
        let (red_res, map_res) =
              splitFromEnd (length map_pes) $
                map kernelResultSubExp $ kernelBodyResult kbody
            (buckets, vs) = splitAt (length histops) red_res
            perOp = chunks $ map (length . histDest) histops

        forM_ (zip4 per_red_pes histops (perOp vs) buckets) $
          \(red_pes, HistOp dest_w _ _ _ shape lam, vs', bucket) -> do
            let (is_params, vs_params) = splitAt (length vs') $ lambdaParams lam
                bucket' = toInt64Exp bucket
                dest_w' = toInt64Exp dest_w
                bucket_in_bounds = bucket' .<. dest_w' .&&. 0 .<=. bucket'

            sComment "save map-out results" $
              forM_ (zip map_pes map_res) $ \(pe, res) ->
                copyDWIMFix (patElemName pe) (map Imp.vi64 is) res []

            sComment "perform updates" $
              sWhen bucket_in_bounds $ do
                dLParams $ lambdaParams lam
                sLoopNest shape $ \vec_is -> do
                  -- Index
                  let buck = toInt64Exp bucket
                  forM_ (zip red_pes is_params) $ \(pe, p) ->
                    copyDWIMFix (paramName p) [] (Var $ patElemName pe) (map Imp.vi64 (init is) ++ [buck] ++ vec_is)
                  -- Value at index
                  forM_ (zip vs_params vs') $ \(p, v) ->
                    copyDWIMFix (paramName p) [] v vec_is
                  compileStms mempty (bodyStms $ lambdaBody lam) $
                    forM_ (zip red_pes $ map resSubExp $ bodyResult $ lambdaBody lam) $
                      \(pe, se) -> copyDWIMFix (patElemName pe) (map Imp.vi64 (init is) ++ [buck] ++ vec_is) se []
