{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
module Futhark.CodeGen.ImpGen.Kernels.Base
  ( KernelConstants (..)
  , keyWithEntryPoint
  , CallKernelGen
  , InKernelGen
  , HostEnv (..)
  , KernelEnv (..)
  , computeThreadChunkSize
  , groupReduce
  , groupScan
  , isActive
  , sKernelThread
  , sKernelGroup
  , sReplicate
  , sIota
  , sCopy
  , compileThreadResult
  , compileGroupResult
  , virtualiseGroups
  , groupLoop
  , kernelLoop
  , groupCoverSpace
  , precomputeSegOpIDs

  , atomicUpdateLocking
  , AtomicBinOp
  , Locking(..)
  , AtomicUpdate(..)
  , DoAtomicUpdate
  )
  where

import Control.Monad.Except
import Data.Maybe
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (elemIndex, find, nub, zip4)

import Prelude hiding (quot, rem)

import Futhark.Error
import Futhark.MonadFreshNames
import Futhark.Transform.Rename
import Futhark.Representation.KernelsMem
import qualified Futhark.Representation.Mem.IxFun as IxFun
import qualified Futhark.CodeGen.ImpCode.Kernels as Imp
import Futhark.CodeGen.ImpGen
import Futhark.Util.IntegralExp (quotRoundingUp, quot, rem)
import Futhark.Util (chunks, maybeNth, mapAccumLM, takeLast, dropLast)

newtype HostEnv = HostEnv
  { hostAtomics :: AtomicBinOp }

data KernelEnv = KernelEnv
  { kernelAtomics :: AtomicBinOp
  , kernelConstants :: KernelConstants
  }

type CallKernelGen = ImpM KernelsMem HostEnv Imp.HostOp
type InKernelGen = ImpM KernelsMem KernelEnv Imp.KernelOp

data KernelConstants =
  KernelConstants
  { kernelGlobalThreadId :: Imp.Exp
  , kernelLocalThreadId :: Imp.Exp
  , kernelGroupId :: Imp.Exp
  , kernelGlobalThreadIdVar :: VName
  , kernelLocalThreadIdVar :: VName
  , kernelGroupIdVar :: VName
  , kernelNumGroups :: Imp.Exp
  , kernelGroupSize :: Imp.Exp
  , kernelNumThreads :: Imp.Exp
  , kernelWaveSize :: Imp.Exp
  , kernelThreadActive :: Imp.Exp
  , kernelLocalIdMap :: M.Map [SubExp] [Imp.Exp]
    -- ^ A mapping from dimensions of nested SegOps to already
    -- computed local thread IDs.
  }

segOpSizes :: Stms KernelsMem -> S.Set [SubExp]
segOpSizes = onStms
  where onStms = foldMap (onExp . stmExp)
        onExp (Op (Inner (SegOp op))) =
          S.singleton $ map snd $ unSegSpace $ segSpace op
        onExp (If _ tbranch fbranch _) =
          onStms (bodyStms tbranch) <> onStms (bodyStms fbranch)
        onExp (DoLoop _ _ _ body) =
          onStms (bodyStms body)
        onExp _ = mempty

precomputeSegOpIDs :: Stms KernelsMem -> InKernelGen a -> InKernelGen a
precomputeSegOpIDs stms m = do
  ltid <- kernelLocalThreadId . kernelConstants <$> askEnv
  new_ids <- M.fromList <$> mapM (mkMap ltid) (S.toList (segOpSizes stms))
  let f env = env { kernelConstants =
                      (kernelConstants env) { kernelLocalIdMap = new_ids }
                  }
  localEnv f m
  where mkMap ltid dims = do
          dims' <- mapM toExp dims
          ids' <- mapM (dPrimVE "ltid_pre") $ unflattenIndex dims' ltid
          return (dims, ids')

keyWithEntryPoint :: Maybe Name -> Name -> Name
keyWithEntryPoint fname key =
  nameFromString $ maybe "" ((++".") . nameToString) fname ++ nameToString key

allocLocal :: AllocCompiler KernelsMem r Imp.KernelOp
allocLocal mem size =
  sOp $ Imp.LocalAlloc mem size

kernelAlloc :: Pattern KernelsMem
            -> SubExp -> Space
            -> InKernelGen ()
kernelAlloc (Pattern _ [_]) _ ScalarSpace{} =
  -- Handled by the declaration of the memory block, which is then
  -- translated to an actual scalar variable during C code generation.
  return ()
kernelAlloc (Pattern _ [mem]) size (Space "local") = do
  size' <- toExp size
  allocLocal (patElemName mem) $ Imp.bytes size'
kernelAlloc (Pattern _ [mem]) _ _ =
  compilerLimitationS $ "Cannot allocate memory block " ++ pretty mem ++ " in kernel."
kernelAlloc dest _ _ =
  error $ "Invalid target for in-kernel allocation: " ++ show dest

splitSpace :: (ToExp w, ToExp i, ToExp elems_per_thread) =>
              Pattern KernelsMem -> SplitOrdering -> w -> i -> elems_per_thread
           -> ImpM lore r op ()
splitSpace (Pattern [] [size]) o w i elems_per_thread = do
  num_elements <- Imp.elements <$> toExp w
  i' <- toExp i
  elems_per_thread' <- Imp.elements <$> toExp elems_per_thread
  computeThreadChunkSize o i' elems_per_thread' num_elements (patElemName size)
splitSpace pat _ _ _ _ =
  error $ "Invalid target for splitSpace: " ++ pretty pat

compileThreadExp :: ExpCompiler KernelsMem KernelEnv Imp.KernelOp
compileThreadExp (Pattern _ [dest]) (BasicOp (ArrayLit es _)) =
  forM_ (zip [0..] es) $ \(i,e) ->
  copyDWIMFix (patElemName dest) [fromIntegral (i::Int32)] e []
compileThreadExp dest e =
  defCompileExp dest e


-- | Assign iterations of a for-loop to all threads in the kernel.
-- The passed-in function is invoked with the (symbolic) iteration.
-- 'threadOperations' will be in effect in the body.  For
-- multidimensional loops, use 'groupCoverSpace'.
kernelLoop :: Imp.Exp -> Imp.Exp -> Imp.Exp
           -> (Imp.Exp -> InKernelGen ()) -> InKernelGen ()
kernelLoop tid num_threads n f =
  localOps threadOperations $
  if n == num_threads then
    f tid
  else do
    -- Compute how many elements this thread is responsible for.
    -- Formula: (n - tid) / num_threads (rounded up).
    let elems_for_this = (n - tid) `quotRoundingUp` num_threads

    sFor "i" elems_for_this $ \i -> f $
      i * num_threads + tid

-- | Assign iterations of a for-loop to threads in the workgroup.  The
-- passed-in function is invoked with the (symbolic) iteration.  For
-- multidimensional loops, use 'groupCoverSpace'.
groupLoop :: Imp.Exp
          -> (Imp.Exp -> InKernelGen ()) -> InKernelGen ()
groupLoop n f = do
  constants <- kernelConstants <$> askEnv
  kernelLoop (kernelLocalThreadId constants) (kernelGroupSize constants) n f

-- | Iterate collectively though a multidimensional space, such that
-- all threads in the group participate.  The passed-in function is
-- invoked with a (symbolic) point in the index space.
groupCoverSpace :: [Imp.Exp]
                -> ([Imp.Exp] -> InKernelGen ()) -> InKernelGen ()
groupCoverSpace ds f =
  groupLoop (product ds) $ f . unflattenIndex ds

compileGroupExp :: ExpCompiler KernelsMem KernelEnv Imp.KernelOp
-- The static arrays stuff does not work inside kernels.
compileGroupExp (Pattern _ [dest]) (BasicOp (ArrayLit es _)) =
  forM_ (zip [0..] es) $ \(i,e) ->
  copyDWIMFix (patElemName dest) [fromIntegral (i::Int32)] e []
compileGroupExp (Pattern _ [dest]) (BasicOp (Replicate ds se)) = do
  ds' <- mapM toExp $ shapeDims ds
  groupCoverSpace ds' $ \is ->
    copyDWIMFix (patElemName dest) is se (drop (shapeRank ds) is)
  sOp $ Imp.Barrier Imp.FenceLocal
compileGroupExp (Pattern _ [dest]) (BasicOp (Iota n e s _)) = do
  n' <- toExp n
  e' <- toExp e
  s' <- toExp s
  groupLoop n' $ \i' -> do
    x <- dPrimV "x" $ e' + i' * s'
    copyDWIMFix (patElemName dest) [i'] (Var x) []
  sOp $ Imp.Barrier Imp.FenceLocal
compileGroupExp dest e =
  defCompileExp dest e

sanityCheckLevel :: SegLevel -> InKernelGen ()
sanityCheckLevel SegThread{} = return ()
sanityCheckLevel SegGroup{} =
  error "compileGroupOp: unexpected group-level SegOp."

localThreadIDs :: [SubExp] -> InKernelGen [Imp.Exp]
localThreadIDs dims = do
  ltid <- kernelLocalThreadId . kernelConstants <$> askEnv
  dims' <- mapM toExp dims
  fromMaybe (unflattenIndex dims' ltid) .
    M.lookup dims . kernelLocalIdMap . kernelConstants <$> askEnv

compileGroupSpace :: SegLevel -> SegSpace -> InKernelGen ()
compileGroupSpace lvl space = do
  sanityCheckLevel lvl
  let (ltids, dims) = unzip $ unSegSpace space
  zipWithM_ dPrimV_ ltids =<< localThreadIDs dims
  ltid <- kernelLocalThreadId . kernelConstants <$> askEnv
  dPrimV_ (segFlat space) ltid

-- Construct the necessary lock arrays for an intra-group histogram.
prepareIntraGroupSegHist :: Count GroupSize SubExp
                         -> [HistOp KernelsMem]
                         -> InKernelGen [[Imp.Exp] -> InKernelGen ()]
prepareIntraGroupSegHist group_size =
  fmap snd . mapAccumLM onOp Nothing
  where
    onOp l op = do

      constants <- kernelConstants <$> askEnv
      atomicBinOp <- kernelAtomics <$> askEnv

      let local_subhistos = histDest op

      case (l, atomicUpdateLocking atomicBinOp $ histOp op) of
        (_, AtomicPrim f) -> return (l, f (Space "local") local_subhistos)
        (_, AtomicCAS f) -> return (l, f (Space "local") local_subhistos)
        (Just l', AtomicLocking f) -> return (l, f l' (Space "local") local_subhistos)
        (Nothing, AtomicLocking f) -> do
          locks <- newVName "locks"
          num_locks <- toExp $ unCount group_size

          let dims = map (toExp' int32) $
                     shapeDims (histShape op) ++
                     [histWidth op]
              l' = Locking locks 0 1 0 (pure . (`rem` num_locks) . flattenIndex dims)
              locks_t = Array int32 (Shape [unCount group_size]) NoUniqueness

          locks_mem <- sAlloc "locks_mem" (typeSize locks_t) $ Space "local"
          dArray locks int32 (arrayShape locks_t) $
            ArrayIn locks_mem $ IxFun.iota $
            map (primExpFromSubExp int32) $ arrayDims locks_t

          sComment "All locks start out unlocked" $
            groupCoverSpace [kernelGroupSize constants] $ \is ->
            copyDWIMFix locks is (intConst Int32 0) []

          return (Just l', f l' (Space "local") local_subhistos)

whenActive :: SegLevel -> SegSpace -> InKernelGen () -> InKernelGen ()
whenActive lvl space m
  | SegNoVirtFull <- segVirt lvl = m
  | otherwise = sWhen (isActive $ unSegSpace space) m

compileGroupOp :: OpCompiler KernelsMem KernelEnv Imp.KernelOp

compileGroupOp pat (Alloc size space) =
  kernelAlloc pat size space

compileGroupOp pat (Inner (SizeOp (SplitSpace o w i elems_per_thread))) =
  splitSpace pat o w i elems_per_thread

compileGroupOp pat (Inner (SegOp (SegMap lvl space _ body))) = do
  void $ compileGroupSpace lvl space

  whenActive lvl space $ localOps threadOperations $
    compileStms mempty (kernelBodyStms body) $
    zipWithM_ (compileThreadResult space) (patternElements pat) $
    kernelBodyResult body

  sOp $ Imp.ErrorSync Imp.FenceLocal

compileGroupOp pat (Inner (SegOp (SegScan lvl space scan_op _ _ body))) = do
  compileGroupSpace lvl space
  let (ltids, dims) = unzip $ unSegSpace space
  dims' <- mapM toExp dims

  whenActive lvl space $
    compileStms mempty (kernelBodyStms body) $
    forM_ (zip (patternNames pat) $ kernelBodyResult body) $ \(dest, res) ->
    copyDWIMFix dest
    (map (`Imp.var` int32) ltids)
    (kernelResultSubExp res) []

  sOp $ Imp.ErrorSync Imp.FenceLocal

  let segment_size = last dims'
      crossesSegment from to = (to-from) .>. (to `rem` segment_size)
  groupScan (Just crossesSegment) (product dims') (product dims') scan_op $
    patternNames pat

compileGroupOp pat (Inner (SegOp (SegRed lvl space ops _ body))) = do
  compileGroupSpace lvl space

  let (ltids, dims) = unzip $ unSegSpace space
      (red_pes, map_pes) =
        splitAt (segRedResults ops) $ patternElements pat

  dims' <- mapM toExp dims

  let mkTempArr t =
        sAllocArray "red_arr" (elemType t) (Shape dims <> arrayShape t) $ Space "local"
  tmp_arrs <- mapM mkTempArr $ concatMap (lambdaReturnType . segRedLambda) ops
  let tmps_for_ops = chunks (map (length . segRedNeutral) ops) tmp_arrs

  whenActive lvl space $
    compileStms mempty (kernelBodyStms body) $ do
    let (red_res, map_res) =
          splitAt (segRedResults ops) $ kernelBodyResult body
    forM_ (zip tmp_arrs red_res) $ \(dest, res) ->
      copyDWIMFix dest (map (`Imp.var` int32) ltids) (kernelResultSubExp res) []
    zipWithM_ (compileThreadResult space) map_pes map_res

  sOp $ Imp.ErrorSync Imp.FenceLocal

  case dims' of
    -- Nonsegmented case (or rather, a single segment) - this we can
    -- handle directly with a group-level reduction.
    [dim'] -> do
      forM_ (zip ops tmps_for_ops) $ \(op, tmps) ->
        groupReduce dim' (segRedLambda op) tmps

      sOp $ Imp.ErrorSync Imp.FenceLocal

      forM_ (zip red_pes tmp_arrs) $ \(pe, arr) ->
        copyDWIMFix (patElemName pe) [] (Var arr) [0]

    _ -> do
      -- Segmented intra-group reductions are turned into (regular)
      -- segmented scans.  It is possible that this can be done
      -- better, but at least this approach is simple.

      -- groupScan operates on flattened arrays.  This does not
      -- involve copying anything; merely playing with the index
      -- function.
      dims_flat <- dPrimV "dims_flat" $ product dims'
      let flatten arr = do
            ArrayEntry arr_loc pt <- lookupArray arr
            let flat_shape = Shape $ Var dims_flat :
                             drop (length ltids) (memLocationShape arr_loc)
            sArray "red_arr_flat" pt flat_shape $
              ArrayIn (memLocationName arr_loc) $
              IxFun.iota $ map (primExpFromSubExp int32) $ shapeDims flat_shape

      let segment_size = last dims'
          crossesSegment from to = (to-from) .>. (to `rem` segment_size)

      forM_ (zip ops tmps_for_ops) $ \(op, tmps) -> do
        tmps_flat <- mapM flatten tmps
        groupScan (Just crossesSegment) (product dims') (product dims')
          (segRedLambda op) tmps_flat

      sOp $ Imp.ErrorSync Imp.FenceLocal

      forM_ (zip red_pes tmp_arrs) $ \(pe, arr) ->
        copyDWIM (patElemName pe) [] (Var arr)
        (map (unitSlice 0) (init dims') ++ [DimFix $ last dims'-1])

      sOp $ Imp.Barrier Imp.FenceLocal

compileGroupOp pat (Inner (SegOp (SegHist lvl space ops _ kbody))) = do
  compileGroupSpace lvl space
  let ltids = map fst $ unSegSpace space

  -- We don't need the red_pes, because it is guaranteed by our type
  -- rules that they occupy the same memory as the destinations for
  -- the ops.
  let num_red_res = length ops + sum (map (length . histNeutral) ops)
      (_red_pes, map_pes) =
        splitAt num_red_res $ patternElements pat

  ops' <- prepareIntraGroupSegHist (segGroupSize lvl) ops

  -- Ensure that all locks have been initialised.
  sOp $ Imp.Barrier Imp.FenceLocal

  whenActive lvl space $
    compileStms mempty (kernelBodyStms kbody) $ do
    let (red_res, map_res) = splitAt num_red_res $ kernelBodyResult kbody
        (red_is, red_vs) = splitAt (length ops) $ map kernelResultSubExp red_res
    zipWithM_ (compileThreadResult space) map_pes map_res

    let vs_per_op = chunks (map (length . histDest) ops) red_vs

    forM_ (zip4 red_is vs_per_op ops' ops) $
      \(bin, op_vs, do_op, HistOp dest_w _ _ _ shape lam) -> do
        let bin' = toExp' int32 bin
            dest_w' = toExp' int32 dest_w
            bin_in_bounds = 0 .<=. bin' .&&. bin' .<. dest_w'
            bin_is = map (`Imp.var` int32) (init ltids) ++ [bin']
            vs_params = takeLast (length op_vs) $ lambdaParams lam

        sComment "perform atomic updates" $
          sWhen bin_in_bounds $ do
          dLParams $ lambdaParams lam
          sLoopNest shape $ \is -> do
            forM_ (zip vs_params op_vs) $ \(p, v) ->
              copyDWIMFix (paramName p) [] v is
            do_op (bin_is ++ is)

  sOp $ Imp.ErrorSync Imp.FenceLocal

compileGroupOp pat _ =
  compilerBugS $ "compileGroupOp: cannot compile rhs of binding " ++ pretty pat

compileThreadOp :: OpCompiler KernelsMem KernelEnv Imp.KernelOp
compileThreadOp pat (Alloc size space) =
  kernelAlloc pat size space
compileThreadOp pat (Inner (SizeOp (SplitSpace o w i elems_per_thread))) =
  splitSpace pat o w i elems_per_thread
compileThreadOp pat _ =
  compilerBugS $ "compileThreadOp: cannot compile rhs of binding " ++ pretty pat

-- | Locking strategy used for an atomic update.
data Locking =
  Locking { lockingArray :: VName
            -- ^ Array containing the lock.
          , lockingIsUnlocked :: Imp.Exp
            -- ^ Value for us to consider the lock free.
          , lockingToLock :: Imp.Exp
            -- ^ What to write when we lock it.
          , lockingToUnlock :: Imp.Exp
            -- ^ What to write when we unlock it.
          , lockingMapping :: [Imp.Exp] -> [Imp.Exp]
            -- ^ A transformation from the logical lock index to the
            -- physical position in the array.  This can also be used
            -- to make the lock array smaller.
          }

-- | A function for generating code for an atomic update.  Assumes
-- that the bucket is in-bounds.
type DoAtomicUpdate lore r =
  Space -> [VName] -> [Imp.Exp] -> ImpM lore r Imp.KernelOp ()

-- | The mechanism that will be used for performing the atomic update.
-- Approximates how efficient it will be.  Ordered from most to least
-- efficient.
data AtomicUpdate lore r
  = AtomicPrim (DoAtomicUpdate lore r)
    -- ^ Supported directly by primitive.
  | AtomicCAS (DoAtomicUpdate lore r)
    -- ^ Can be done by efficient swaps.
  | AtomicLocking (Locking -> DoAtomicUpdate lore r)
    -- ^ Requires explicit locking.

-- | Is there an atomic 'BinOp' corresponding to this 'BinOp'?
type AtomicBinOp =
  BinOp ->
  Maybe (VName -> VName -> Count Imp.Elements Imp.Exp -> Imp.Exp -> Imp.AtomicOp)

-- | 'atomicUpdate', but where it is explicitly visible whether a
-- locking strategy is necessary.
atomicUpdateLocking :: AtomicBinOp -> Lambda KernelsMem
                    -> AtomicUpdate KernelsMem KernelEnv

atomicUpdateLocking atomicBinOp lam
  | Just ops_and_ts <- splitOp lam,
    all (\(_, t, _, _) -> primBitSize t == 32) ops_and_ts =
    primOrCas ops_and_ts $ \space arrs bucket ->
  -- If the operator is a vectorised binary operator on 32-bit values,
  -- we can use a particularly efficient implementation. If the
  -- operator has an atomic implementation we use that, otherwise it
  -- is still a binary operator which can be implemented by atomic
  -- compare-and-swap if 32 bits.
  forM_ (zip arrs ops_and_ts) $ \(a, (op, t, x, y)) -> do

  -- Common variables.
  old <- dPrim "old" t

  (arr', _a_space, bucket_offset) <- fullyIndexArray a bucket

  case opHasAtomicSupport space old arr' bucket_offset op of
    Just f -> sOp $ f $ Imp.var y t
    Nothing -> atomicUpdateCAS space t a old bucket x $
      x <-- Imp.BinOpExp op (Imp.var x t) (Imp.var y t)

  where opHasAtomicSupport space old arr' bucket' bop = do
          let atomic f = Imp.Atomic space . f old arr' bucket'
          atomic <$> atomicBinOp bop

        primOrCas ops
          | all isPrim ops = AtomicPrim
          | otherwise      = AtomicCAS

        isPrim (op, _, _, _) = isJust $ atomicBinOp op

-- If the operator functions purely on single 32-bit values, we can
-- use an implementation based on CAS, no matter what the operator
-- does.
atomicUpdateLocking _ op
  | [Prim t] <- lambdaReturnType op,
    [xp, _] <- lambdaParams op,
    primBitSize t == 32 = AtomicCAS $ \space [arr] bucket -> do
      old <- dPrim "old" t
      atomicUpdateCAS space t arr old bucket (paramName xp) $
        compileBody' [xp] $ lambdaBody op

atomicUpdateLocking _ op = AtomicLocking $ \locking space arrs bucket -> do
  old <- dPrim "old" int32
  continue <- newVName "continue"
  dPrimVol_ continue Bool
  continue <-- true

  -- Correctly index into locks.
  (locks', _locks_space, locks_offset) <-
    fullyIndexArray (lockingArray locking) $ lockingMapping locking bucket

  -- Critical section
  let try_acquire_lock =
        sOp $ Imp.Atomic space $
        Imp.AtomicCmpXchg int32 old locks' locks_offset
        (lockingIsUnlocked locking) (lockingToLock locking)
      lock_acquired = Imp.var old int32 .==. lockingIsUnlocked locking
      -- Even the releasing is done with an atomic rather than a
      -- simple write, for memory coherency reasons.
      release_lock =
        sOp $ Imp.Atomic space $
        Imp.AtomicCmpXchg int32 old locks' locks_offset
        (lockingToLock locking) (lockingToUnlock locking)
      break_loop = continue <-- false

  -- Preparing parameters. It is assumed that the caller has already
  -- filled the arr_params. We copy the current value to the
  -- accumulator parameters.
  --
  -- Note the use of 'everythingVolatile' when reading and writing the
  -- buckets.  This was necessary to ensure correct execution on a
  -- newer NVIDIA GPU (RTX 2080).  The 'volatile' modifiers likely
  -- make the writes pass through the (SM-local) L1 cache, which is
  -- necessary here, because we are really doing device-wide
  -- synchronisation without atomics (naughty!).
  let (acc_params, _arr_params) = splitAt (length arrs) $ lambdaParams op
      bind_acc_params =
        everythingVolatile $
        sComment "bind lhs" $
        forM_ (zip acc_params arrs) $ \(acc_p, arr) ->
        copyDWIMFix (paramName acc_p) [] (Var arr) bucket

  let op_body = sComment "execute operation" $
                compileBody' acc_params $ lambdaBody op

      do_hist =
        everythingVolatile $
        sComment "update global result" $
        zipWithM_ (writeArray bucket) arrs $ map (Var . paramName) acc_params

      fence = case space of Space "local" -> sOp $ Imp.MemFence Imp.FenceLocal
                            _             -> sOp $ Imp.MemFence Imp.FenceGlobal


  -- While-loop: Try to insert your value
  sWhile (Imp.var continue Bool) $ do
    try_acquire_lock
    sWhen lock_acquired $ do
      dLParams acc_params
      bind_acc_params
      op_body
      do_hist
      fence
      release_lock
      break_loop
    fence
  where writeArray bucket arr val = copyDWIMFix arr bucket val []

atomicUpdateCAS :: Space -> PrimType
                -> VName -> VName
                -> [Imp.Exp] -> VName
                -> InKernelGen ()
                -> InKernelGen ()
atomicUpdateCAS space t arr old bucket x do_op = do
  -- Code generation target:
  --
  -- old = d_his[idx];
  -- do {
  --   assumed = old;
  --   x = do_op(assumed, y);
  --   old = atomicCAS(&d_his[idx], assumed, tmp);
  -- } while(assumed != old);
  assumed <- dPrim "assumed" t
  run_loop <- dPrimV "run_loop" 1

  -- XXX: CUDA may generate really bad code if this is not a volatile
  -- read.  Unclear why.  The later reads are volatile, so maybe
  -- that's it.
  everythingVolatile $ copyDWIMFix old [] (Var arr) bucket

  (arr', _a_space, bucket_offset) <- fullyIndexArray arr bucket

  -- While-loop: Try to insert your value
  let (toBits, fromBits) =
        case t of FloatType Float32 -> (\v -> Imp.FunExp "to_bits32" [v] int32,
                                        \v -> Imp.FunExp "from_bits32" [v] t)
                  _                 -> (id, id)
  sWhile (Imp.var run_loop int32) $ do
    assumed <-- Imp.var old t
    x <-- Imp.var assumed t
    do_op
    old_bits <- dPrim "old_bits" int32
    sOp $ Imp.Atomic space $
      Imp.AtomicCmpXchg int32 old_bits arr' bucket_offset
      (toBits (Imp.var assumed t)) (toBits (Imp.var x t))
    old <-- fromBits (Imp.var old_bits int32)
    sWhen (toBits (Imp.var assumed t) .==. Imp.var old_bits int32)
      (run_loop <-- 0)

-- | Horizontally fission a lambda that models a binary operator.
splitOp :: Attributes lore => Lambda lore -> Maybe [(BinOp, PrimType, VName, VName)]
splitOp lam = mapM splitStm $ bodyResult $ lambdaBody lam
  where n = length $ lambdaReturnType lam
        splitStm (Var res) = do
          Let (Pattern [] [pe]) _ (BasicOp (BinOp op (Var x) (Var y))) <-
            find (([res]==) . patternNames . stmPattern) $
            stmsToList $ bodyStms $ lambdaBody lam
          i <- Var res `elemIndex` bodyResult (lambdaBody lam)
          xp <- maybeNth i $ lambdaParams lam
          yp <- maybeNth (n+i) $ lambdaParams lam
          guard $ paramName xp == x
          guard $ paramName yp == y
          Prim t <- Just $ patElemType pe
          return (op, t, paramName xp, paramName yp)
        splitStm _ = Nothing

computeKernelUses :: FreeIn a =>
                     a -> [VName]
                  -> CallKernelGen [Imp.KernelUse]
computeKernelUses kernel_body bound_in_kernel = do
  let actually_free = freeIn kernel_body `namesSubtract` namesFromList bound_in_kernel
  -- Compute the variables that we need to pass to the kernel.
  nub <$> readsFromSet actually_free

readsFromSet :: Names -> CallKernelGen [Imp.KernelUse]
readsFromSet free =
  fmap catMaybes $
  forM (namesToList free) $ \var -> do
    t <- lookupType var
    vtable <- getVTable
    case t of
      Array {} -> return Nothing
      Mem (Space "local") -> return Nothing
      Mem {} -> return $ Just $ Imp.MemoryUse var
      Prim bt ->
        isConstExp vtable (Imp.var var bt) >>= \case
          Just ce -> return $ Just $ Imp.ConstUse var ce
          Nothing | bt == Cert -> return Nothing
                  | otherwise  -> return $ Just $ Imp.ScalarUse var bt

isConstExp :: VTable KernelsMem -> Imp.Exp
           -> ImpM lore r op (Maybe Imp.KernelConstExp)
isConstExp vtable size = do
  fname <- askFunction
  let onLeaf (Imp.ScalarVar name) _ = lookupConstExp name
      onLeaf (Imp.SizeOf pt) _ = Just $ primByteSize pt
      onLeaf Imp.Index{} _ = Nothing
      lookupConstExp name =
        constExp =<< hasExp =<< M.lookup name vtable
      constExp (Op (Inner (SizeOp (GetSize key _)))) =
        Just $ LeafExp (Imp.SizeConst $ keyWithEntryPoint fname key) int32
      constExp e = primExpFromExp lookupConstExp e
  return $ replaceInPrimExpM onLeaf size
  where hasExp (ArrayVar e _) = e
        hasExp (ScalarVar e _) = e
        hasExp (MemVar e _) = e

computeThreadChunkSize :: SplitOrdering
                       -> Imp.Exp
                       -> Imp.Count Imp.Elements Imp.Exp
                       -> Imp.Count Imp.Elements Imp.Exp
                       -> VName
                       -> ImpM lore r op ()
computeThreadChunkSize (SplitStrided stride) thread_index elements_per_thread num_elements chunk_var = do
  stride' <- toExp stride
  chunk_var <--
    Imp.BinOpExp (SMin Int32)
    (Imp.unCount elements_per_thread)
    ((Imp.unCount num_elements - thread_index) `quotRoundingUp` stride')

computeThreadChunkSize SplitContiguous thread_index elements_per_thread num_elements chunk_var = do
  starting_point <- dPrimV "starting_point" $
    thread_index * Imp.unCount elements_per_thread
  remaining_elements <- dPrimV "remaining_elements" $
    Imp.unCount num_elements - Imp.var starting_point int32

  let no_remaining_elements = Imp.var remaining_elements int32 .<=. 0
      beyond_bounds = Imp.unCount num_elements .<=. Imp.var starting_point int32

  sIf (no_remaining_elements .||. beyond_bounds)
    (chunk_var <-- 0)
    (sIf is_last_thread
       (chunk_var <-- Imp.unCount last_thread_elements)
       (chunk_var <-- Imp.unCount elements_per_thread))
  where last_thread_elements =
          num_elements - Imp.elements thread_index * elements_per_thread
        is_last_thread =
          Imp.unCount num_elements .<.
          (thread_index + 1) * Imp.unCount elements_per_thread

kernelInitialisationSimple :: Count NumGroups Imp.Exp -> Count GroupSize Imp.Exp
                           -> CallKernelGen (KernelConstants, InKernelGen ())
kernelInitialisationSimple (Count num_groups) (Count group_size) = do
  global_tid <- newVName "global_tid"
  local_tid <- newVName "local_tid"
  group_id <- newVName "group_tid"
  wave_size <- newVName "wave_size"
  inner_group_size <- newVName "group_size"
  let constants =
        KernelConstants
        (Imp.var global_tid int32)
        (Imp.var local_tid int32)
        (Imp.var group_id int32)
        global_tid local_tid group_id
        num_groups group_size (group_size*num_groups)
        (Imp.var wave_size int32)
        true
        mempty

  let set_constants = do
        dPrim_ global_tid int32
        dPrim_ local_tid int32
        dPrim_ inner_group_size int32
        dPrim_ wave_size int32
        dPrim_ group_id int32

        sOp (Imp.GetGlobalId global_tid 0)
        sOp (Imp.GetLocalId local_tid 0)
        sOp (Imp.GetLocalSize inner_group_size 0)
        sOp (Imp.GetLockstepWidth wave_size)
        sOp (Imp.GetGroupId group_id 0)

  return (constants, set_constants)

isActive :: [(VName, SubExp)] -> Imp.Exp
isActive limit = case actives of
                    [] -> Imp.ValueExp $ BoolValue True
                    x:xs -> foldl (.&&.) x xs
  where (is, ws) = unzip limit
        actives = zipWith active is $ map (toExp' Bool) ws
        active i = (Imp.var i int32 .<.)

-- | Change every memory block to be in the global address space,
-- except those who are in the local memory space.  This only affects
-- generated code - we still need to make sure that the memory is
-- actually present on the device (and dared as variables in the
-- kernel).
makeAllMemoryGlobal :: CallKernelGen a -> CallKernelGen a
makeAllMemoryGlobal =
  localDefaultSpace (Imp.Space "global") . localVTable (M.map globalMemory)
  where globalMemory (MemVar _ entry)
          | entryMemSpace entry /= Space "local" =
              MemVar Nothing entry { entryMemSpace = Imp.Space "global" }
        globalMemory entry =
          entry

groupReduce :: Imp.Exp
            -> Lambda KernelsMem
            -> [VName]
            -> InKernelGen ()
groupReduce w lam arrs = do
  offset <- dPrim "offset" int32
  groupReduceWithOffset offset w lam arrs

groupReduceWithOffset :: VName
                      -> Imp.Exp
                      -> Lambda KernelsMem
                      -> [VName]
                      -> InKernelGen ()
groupReduceWithOffset offset w lam arrs = do
  constants <- kernelConstants <$> askEnv

  let local_tid = kernelLocalThreadId constants
      global_tid = kernelGlobalThreadId constants

      barrier
        | all primType $ lambdaReturnType lam = sOp $ Imp.Barrier Imp.FenceLocal
        | otherwise                           = sOp $ Imp.Barrier Imp.FenceGlobal

      readReduceArgument param arr
        | Prim _ <- paramType param = do
            let i = local_tid + Imp.vi32 offset
            copyDWIMFix (paramName param) [] (Var arr) [i]
        | otherwise = do
            let i = global_tid + Imp.vi32 offset
            copyDWIMFix (paramName param) [] (Var arr) [i]

      writeReduceOpResult param arr
        | Prim _ <- paramType param =
            copyDWIMFix arr [local_tid] (Var $ paramName param) []
        | otherwise =
            return ()

  let (reduce_acc_params, reduce_arr_params) = splitAt (length arrs) $ lambdaParams lam

  skip_waves <- dPrim "skip_waves" int32
  dLParams $ lambdaParams lam

  offset <-- 0

  comment "participating threads read initial accumulator" $
    sWhen (local_tid .<. w) $
    zipWithM_ readReduceArgument reduce_acc_params arrs

  let do_reduce = do comment "read array element" $
                       zipWithM_ readReduceArgument reduce_arr_params arrs
                     comment "apply reduction operation" $
                       compileBody' reduce_acc_params $ lambdaBody lam
                     comment "write result of operation" $
                       zipWithM_ writeReduceOpResult reduce_acc_params arrs
      in_wave_reduce = everythingVolatile do_reduce

      wave_size = kernelWaveSize constants
      group_size = kernelGroupSize constants
      wave_id = local_tid `quot` wave_size
      in_wave_id = local_tid - wave_id * wave_size
      num_waves = (group_size + wave_size - 1) `quot` wave_size
      arg_in_bounds = local_tid + Imp.var offset int32 .<. w

      doing_in_wave_reductions =
        Imp.var offset int32 .<. wave_size
      apply_in_in_wave_iteration =
        (in_wave_id .&. (2 * Imp.var offset int32 - 1)) .==. 0
      in_wave_reductions = do
        offset <-- 1
        sWhile doing_in_wave_reductions $ do
          sWhen (arg_in_bounds .&&. apply_in_in_wave_iteration)
            in_wave_reduce
          offset <-- Imp.var offset int32 * 2

      doing_cross_wave_reductions =
        Imp.var skip_waves int32 .<. num_waves
      is_first_thread_in_wave =
        in_wave_id .==. 0
      wave_not_skipped =
        (wave_id .&. (2 * Imp.var skip_waves int32 - 1)) .==. 0
      apply_in_cross_wave_iteration =
        arg_in_bounds .&&. is_first_thread_in_wave .&&. wave_not_skipped
      cross_wave_reductions = do
        skip_waves <-- 1
        sWhile doing_cross_wave_reductions $ do
          barrier
          offset <-- Imp.var skip_waves int32 * wave_size
          sWhen apply_in_cross_wave_iteration
            do_reduce
          skip_waves <-- Imp.var skip_waves int32 * 2

  in_wave_reductions
  cross_wave_reductions

groupScan :: Maybe (Imp.Exp -> Imp.Exp -> Imp.Exp)
          -> Imp.Exp
          -> Imp.Exp
          -> Lambda KernelsMem
          -> [VName]
          -> InKernelGen ()
groupScan seg_flag arrs_full_size w lam arrs = do
  constants <- kernelConstants <$> askEnv
  renamed_lam <- renameLambda lam

  let ltid = kernelLocalThreadId constants
      (x_params, y_params) = splitAt (length arrs) $ lambdaParams lam

  dLParams (lambdaParams lam++lambdaParams renamed_lam)

  -- The scan works by splitting the group into blocks, which are
  -- scanned separately.  Typically, these blocks are smaller than
  -- the lockstep width, which enables barrier-free execution inside
  -- them.
  --
  -- We hardcode the block size here.  The only requirement is that
  -- it should not be less than the square root of the group size.
  -- With 32, we will work on groups of size 1024 or smaller, which
  -- fits every device Troels has seen.  Still, it would be nicer if
  -- it were a runtime parameter.  Some day.
  let block_size = Imp.ValueExp $ IntValue $ Int32Value 32
      simd_width = kernelWaveSize constants
      block_id = ltid `quot` block_size
      in_block_id = ltid - block_id * block_size
      doInBlockScan seg_flag' active =
        inBlockScan constants seg_flag' arrs_full_size
        simd_width block_size active arrs barrier
      ltid_in_bounds = ltid .<. w
      array_scan = not $ all primType $ lambdaReturnType lam
      barrier | array_scan =
                  sOp $ Imp.Barrier Imp.FenceGlobal
              | otherwise =
                  sOp $ Imp.Barrier Imp.FenceLocal

      group_offset = kernelGroupId constants * kernelGroupSize constants

      writeBlockResult p arr
        | primType $ paramType p =
            copyDWIM arr [DimFix block_id] (Var $ paramName p) []
        | otherwise =
            copyDWIM arr [DimFix $ group_offset + block_id] (Var $ paramName p) []

      readPrevBlockResult p arr
        | primType $ paramType p =
            copyDWIM (paramName p) [] (Var arr) [DimFix $ block_id - 1]
        | otherwise =
            copyDWIM (paramName p) [] (Var arr) [DimFix $ group_offset + block_id - 1]

  doInBlockScan seg_flag ltid_in_bounds lam
  barrier

  let is_first_block = block_id .==. 0
  when array_scan $ do
    sComment "save correct values for first block" $
      sWhen is_first_block $ forM_ (zip x_params arrs) $ \(x, arr) ->
      unless (primType $ paramType x) $
      copyDWIM arr [DimFix $ arrs_full_size + group_offset + block_size + ltid] (Var $ paramName x) []

    barrier

  let last_in_block = in_block_id .==. block_size - 1
  sComment "last thread of block 'i' writes its result to offset 'i'" $
    sWhen (last_in_block .&&. ltid_in_bounds) $ everythingVolatile $
    zipWithM_ writeBlockResult x_params arrs

  barrier

  let first_block_seg_flag = do
        flag_true <- seg_flag
        Just $ \from to ->
          flag_true (from*block_size+block_size-1) (to*block_size+block_size-1)
  comment
    "scan the first block, after which offset 'i' contains carry-in for block 'i+1'" $
    doInBlockScan first_block_seg_flag (is_first_block .&&. ltid_in_bounds) renamed_lam

  barrier

  when array_scan $ do
    sComment "move correct values for first block back a block" $
      sWhen is_first_block $ forM_ (zip x_params arrs) $ \(x, arr) ->
      unless (primType $ paramType x) $
      copyDWIM
      arr [DimFix $ arrs_full_size + group_offset + ltid]
      (Var arr) [DimFix $ arrs_full_size + group_offset + block_size + ltid]

    barrier

  let read_carry_in = do
        forM_ (zip x_params y_params) $ \(x,y) ->
          copyDWIM (paramName y) [] (Var (paramName x)) []
        zipWithM_ readPrevBlockResult x_params arrs

      y_to_x = forM_ (zip x_params y_params) $ \(x,y) ->
        when (primType (paramType x)) $
        copyDWIM (paramName x) [] (Var (paramName y)) []

      op_to_x
        | Nothing <- seg_flag =
            compileBody' x_params $ lambdaBody lam
        | Just flag_true <- seg_flag = do
            inactive <-
              dPrimVE "inactive" $ flag_true (block_id*block_size-1) ltid
            sWhen inactive y_to_x
            when array_scan barrier
            sUnless inactive $ compileBody' x_params $ lambdaBody lam

      write_final_result =
        forM_ (zip x_params arrs) $ \(p, arr) ->
        when (primType $ paramType p) $
        copyDWIM arr [DimFix ltid] (Var $ paramName p) []

  sComment "carry-in for every block except the first" $
    sUnless (is_first_block .||. Imp.UnOpExp Not ltid_in_bounds) $ do
    sComment "read operands" read_carry_in
    sComment "perform operation" op_to_x
    sComment "write final result" write_final_result

  barrier

  sComment "restore correct values for first block" $
    sWhen is_first_block $forM_ (zip3 x_params y_params arrs) $ \(x, y, arr) ->
      if primType (paramType y)
      then copyDWIM arr [DimFix ltid] (Var $ paramName y) []
      else copyDWIM (paramName x) [] (Var arr) [DimFix $ arrs_full_size + group_offset + ltid]

  barrier

inBlockScan :: KernelConstants
            -> Maybe (Imp.Exp -> Imp.Exp -> Imp.Exp)
            -> Imp.Exp
            -> Imp.Exp
            -> Imp.Exp
            -> Imp.Exp
            -> [VName]
            -> InKernelGen ()
            -> Lambda KernelsMem
            -> InKernelGen ()
inBlockScan constants seg_flag arrs_full_size lockstep_width block_size active arrs barrier scan_lam = everythingVolatile $ do
  skip_threads <- dPrim "skip_threads" int32
  let in_block_thread_active =
        Imp.var skip_threads int32 .<=. in_block_id
      actual_params = lambdaParams scan_lam
      (x_params, y_params) =
        splitAt (length actual_params `div` 2) actual_params
      y_to_x =
        forM_ (zip x_params y_params) $ \(x,y) ->
        when (primType (paramType x)) $
        copyDWIM (paramName x) [] (Var (paramName y)) []

  -- Set initial y values
  sComment "read input for in-block scan" $
    sWhen active $ do
    zipWithM_ readInitial y_params arrs
    -- Since the final result is expected to be in x_params, we may
    -- need to copy it there for the first thread in the block.
    sWhen (in_block_id .==. 0) y_to_x

  when array_scan barrier

  let op_to_x
        | Nothing <- seg_flag =
            compileBody' x_params $ lambdaBody scan_lam
        | Just flag_true <- seg_flag = do
            inactive <- dPrimVE "inactive" $
                        flag_true (ltid-Imp.var skip_threads int32) ltid
            sWhen inactive y_to_x
            when array_scan barrier
            sUnless inactive $ compileBody' x_params $ lambdaBody scan_lam

      maybeBarrier = sWhen (lockstep_width .<=. Imp.var skip_threads int32)
                     barrier

  sComment "in-block scan (hopefully no barriers needed)" $ do
    skip_threads <-- 1
    sWhile (Imp.var skip_threads int32 .<. block_size) $ do
      sWhen (in_block_thread_active .&&. active) $ do
        sComment "read operands" $
          zipWithM_ (readParam (Imp.vi32 skip_threads)) x_params arrs
        sComment "perform operation" op_to_x

      maybeBarrier

      sWhen (in_block_thread_active .&&. active) $
        sComment "write result" $
        sequence_ $ zipWith3 writeResult x_params y_params arrs

      maybeBarrier

      skip_threads <-- Imp.var skip_threads int32 * 2

  where block_id = ltid `quot` block_size
        in_block_id = ltid - block_id * block_size
        ltid = kernelLocalThreadId constants
        gtid = kernelGlobalThreadId constants
        array_scan = not $ all primType $ lambdaReturnType scan_lam

        readInitial p arr
          | primType $ paramType p =
              copyDWIM (paramName p) [] (Var arr) [DimFix ltid]
          | otherwise =
              copyDWIM (paramName p) [] (Var arr) [DimFix gtid]

        readParam behind p arr
          | primType $ paramType p =
              copyDWIM (paramName p) [] (Var arr) [DimFix $ ltid - behind]
          | otherwise =
              copyDWIM (paramName p) [] (Var arr) [DimFix $ gtid - behind + arrs_full_size]

        writeResult x y arr
          | primType $ paramType x = do
              copyDWIM arr [DimFix ltid] (Var $ paramName x) []
              copyDWIM (paramName y) [] (Var $ paramName x) []
          | otherwise =
              copyDWIM (paramName y) [] (Var $ paramName x) []

computeMapKernelGroups :: Imp.Exp -> CallKernelGen (Imp.Exp, Imp.Exp)
computeMapKernelGroups kernel_size = do
  group_size <- dPrim "group_size" int32
  fname <- askFunction
  let group_size_var = Imp.var group_size int32
      group_size_key = keyWithEntryPoint fname $ nameFromString $ pretty group_size
  sOp $ Imp.GetSize group_size group_size_key Imp.SizeGroup
  num_groups <- dPrimV "num_groups" $ kernel_size `quotRoundingUp` Imp.ConvOpExp (SExt Int32 Int32) group_size_var
  return (Imp.var num_groups int32, Imp.var group_size int32)

simpleKernelConstants :: Imp.Exp -> String
                      -> CallKernelGen (KernelConstants, InKernelGen ())
simpleKernelConstants kernel_size desc = do
  thread_gtid <- newVName $ desc ++ "_gtid"
  thread_ltid <- newVName $ desc ++ "_ltid"
  group_id <- newVName $ desc ++ "_gid"
  (num_groups, group_size) <- computeMapKernelGroups kernel_size
  let set_constants = do
        dPrim_ thread_gtid int32
        dPrim_ thread_ltid int32
        dPrim_ group_id int32
        sOp (Imp.GetGlobalId thread_gtid 0)
        sOp (Imp.GetLocalId thread_ltid 0)
        sOp (Imp.GetGroupId group_id 0)


  return (KernelConstants
          (Imp.var thread_gtid int32) (Imp.var thread_ltid int32) (Imp.var group_id int32)
          thread_gtid thread_ltid group_id
          num_groups group_size (group_size*num_groups) 0
          (Imp.var thread_gtid int32 .<. kernel_size)
          mempty,

          set_constants)

-- | For many kernels, we may not have enough physical groups to cover
-- the logical iteration space.  Some groups thus have to perform
-- double duty; we put an outer loop to accomplish this.  The
-- advantage over just launching a bazillion threads is that the cost
-- of memory expansion should be proportional to the number of
-- *physical* threads (hardware parallelism), not the amount of
-- application parallelism.
virtualiseGroups :: SegVirt
                 -> Imp.Exp
                 -> (VName -> InKernelGen ())
                 -> InKernelGen ()
virtualiseGroups SegVirt required_groups m = do
  constants <- kernelConstants <$> askEnv
  phys_group_id <- dPrim "phys_group_id" int32
  sOp $ Imp.GetGroupId phys_group_id 0
  let iterations = (required_groups - Imp.vi32 phys_group_id) `quotRoundingUp`
                   kernelNumGroups constants

  sFor "i" iterations $ \i -> do
    m =<< dPrimV "virt_group_id" (Imp.vi32 phys_group_id + i * kernelNumGroups constants)
    -- Make sure the virtual group is actually done before we let
    -- another virtual group have its way with it.
    sOp $ Imp.Barrier Imp.FenceGlobal
virtualiseGroups _ _ m = do
  gid <- kernelGroupIdVar . kernelConstants <$> askEnv
  m gid

sKernelThread :: String
              -> Count NumGroups Imp.Exp -> Count GroupSize Imp.Exp
              -> VName
              -> InKernelGen ()
              -> CallKernelGen ()
sKernelThread = sKernel threadOperations kernelGlobalThreadId

sKernelGroup :: String
             -> Count NumGroups Imp.Exp -> Count GroupSize Imp.Exp
             -> VName
             -> InKernelGen ()
             -> CallKernelGen ()
sKernelGroup = sKernel groupOperations kernelGroupId

sKernelFailureTolerant :: Bool
                       -> Operations KernelsMem KernelEnv Imp.KernelOp
                       -> KernelConstants
                       -> Name
                       -> InKernelGen ()
                       -> CallKernelGen ()
sKernelFailureTolerant tol ops constants name m = do
  HostEnv atomics <- askEnv
  body <- makeAllMemoryGlobal $ subImpM_ (KernelEnv atomics constants) ops m
  uses <- computeKernelUses body mempty
  emit $ Imp.Op $ Imp.CallKernel Imp.Kernel
    { Imp.kernelBody = body
    , Imp.kernelUses = uses
    , Imp.kernelNumGroups = [kernelNumGroups constants]
    , Imp.kernelGroupSize = [kernelGroupSize constants]
    , Imp.kernelName = name
    , Imp.kernelFailureTolerant = tol
    }

sKernel :: Operations KernelsMem KernelEnv Imp.KernelOp
        -> (KernelConstants -> Imp.Exp)
        -> String
        -> Count NumGroups Imp.Exp
        -> Count GroupSize Imp.Exp
        -> VName
        -> InKernelGen ()
        -> CallKernelGen ()
sKernel ops flatf name num_groups group_size v f = do
  (constants, set_constants) <- kernelInitialisationSimple num_groups group_size
  let name' = nameFromString $ name ++ "_" ++ show (baseTag v)
  sKernelFailureTolerant False ops constants name' $ do
    set_constants
    dPrimV_ v $ flatf constants
    f

copyInGroup :: CopyCompiler KernelsMem KernelEnv Imp.KernelOp
copyInGroup pt destloc destslice srcloc srcslice = do
  dest_space <- entryMemSpace <$> lookupMemory (memLocationName destloc)
  src_space <- entryMemSpace <$> lookupMemory (memLocationName srcloc)

  case (dest_space, src_space) of
    (ScalarSpace destds _, ScalarSpace srcds _) -> do
      let destslice' =
            replicate (length destslice - length destds) (DimFix 0) ++
            takeLast (length destds) destslice
          srcslice' =
            replicate (length srcslice - length srcds) (DimFix 0) ++
            takeLast (length srcds) srcslice
      copyElementWise pt destloc destslice' srcloc srcslice'

    _ ->
      groupCoverSpace (sliceDims destslice) $ \is -> do
      copyElementWise pt
        destloc (map DimFix $ fixSlice destslice is)
        srcloc (map DimFix $ fixSlice srcslice is)
      sOp $ Imp.Barrier Imp.FenceLocal

threadOperations, groupOperations :: Operations KernelsMem KernelEnv Imp.KernelOp
threadOperations =
  (defaultOperations compileThreadOp)
  { opsCopyCompiler = copyElementWise
  , opsExpCompiler = compileThreadExp
  , opsStmsCompiler = \_ -> defCompileStms mempty
  , opsAllocCompilers =
      M.fromList [ (Space "local", allocLocal) ]
  }
groupOperations =
  (defaultOperations compileGroupOp)
  { opsCopyCompiler = copyInGroup
  , opsExpCompiler = compileGroupExp
  , opsStmsCompiler = \_ -> defCompileStms mempty
  , opsAllocCompilers =
      M.fromList [ (Space "local", allocLocal) ]
  }

-- | Perform a Replicate with a kernel.
sReplicateKernel :: VName -> SubExp -> CallKernelGen ()
sReplicateKernel arr se = do
  t <- subExpType se
  ds <- dropLast (arrayRank t) . arrayDims <$> lookupType arr

  dims <- mapM toExp $ ds ++ arrayDims t
  (constants, set_constants) <-
    simpleKernelConstants (product dims) "replicate"

  let is' = unflattenIndex dims $ kernelGlobalThreadId constants
      name = nameFromString $ "replicate_" ++
             show (baseTag $ kernelGlobalThreadIdVar constants)

  sKernelFailureTolerant True threadOperations constants name $ do
    set_constants
    sWhen (kernelThreadActive constants) $
      copyDWIMFix arr is' se $ drop (length ds) is'

replicateFunction :: PrimType -> CallKernelGen Imp.Function
replicateFunction bt = do
  mem <- newVName "mem"
  num_elems <- newVName "num_elems"
  val <- newVName "val"

  let params = [Imp.MemParam mem (Space "device"),
                Imp.ScalarParam num_elems int32,
                Imp.ScalarParam val bt]
      shape = Shape [Var num_elems]
  function [] params $ do
    arr <- sArray "arr" bt shape $ ArrayIn mem $ IxFun.iota $
           map (primExpFromSubExp int32) $ shapeDims shape
    sReplicateKernel arr $ Var val

replicateName :: PrimType -> String
replicateName bt = "replicate_" ++ pretty bt

replicateForType :: PrimType -> CallKernelGen Name
replicateForType bt = do
  let fname = nameFromString $ "builtin#" <> replicateName bt

  exists <- hasFunction fname
  unless exists $ emitFunction fname =<< replicateFunction bt

  return fname

replicateIsFill :: VName -> SubExp -> CallKernelGen (Maybe (CallKernelGen ()))
replicateIsFill arr v = do
  ArrayEntry (MemLocation arr_mem arr_shape arr_ixfun) _ <- lookupArray arr
  v_t <- subExpType v
  case v_t of
    Prim v_t'
      | IxFun.isLinear arr_ixfun -> return $ Just $ do
          fname <- replicateForType v_t'
          emit $ Imp.Call [] fname
            [Imp.MemArg arr_mem,
             Imp.ExpArg $ product $ map (toExp' int32) arr_shape,
             Imp.ExpArg $ toExp' v_t' v]
    _ -> return Nothing

-- | Perform a Replicate with a kernel.
sReplicate :: VName -> SubExp -> CallKernelGen ()
sReplicate arr se = do
  -- If the replicate is of a particularly common and simple form
  -- (morally a memset()/fill), then we use a common function.
  is_fill <- replicateIsFill arr se

  case is_fill of
    Just m -> m
    Nothing -> sReplicateKernel arr se

-- | Perform an Iota with a kernel.
sIota :: VName -> Imp.Exp -> Imp.Exp -> Imp.Exp -> IntType
      -> CallKernelGen ()
sIota arr n x s et = do
  destloc <- entryArrayLocation <$> lookupArray arr
  (constants, set_constants) <- simpleKernelConstants n "iota"

  let name = nameFromString $ "iota_" ++
             show (baseTag $ kernelGlobalThreadIdVar constants)

  sKernelFailureTolerant True threadOperations constants name $ do
    set_constants
    let gtid = kernelGlobalThreadId constants
    sWhen (kernelThreadActive constants) $ do
      (destmem, destspace, destidx) <- fullyIndexArray' destloc [gtid]

      emit $
        Imp.Write destmem destidx (IntType et) destspace Imp.Nonvolatile $
        Imp.ConvOpExp (SExt Int32 et) gtid * s + x

sCopy :: CopyCompiler KernelsMem HostEnv Imp.HostOp
sCopy bt
  destloc@(MemLocation destmem _ _) destslice
  srcloc@(MemLocation srcmem _ _) srcslice
  = do
  -- Note that the shape of the destination and the source are
  -- necessarily the same.
  let shape = sliceDims srcslice
      kernel_size = product shape

  (constants, set_constants) <- simpleKernelConstants kernel_size "copy"

  let name = nameFromString $ "copy_" ++
             show (baseTag $ kernelGlobalThreadIdVar constants)

  sKernelFailureTolerant True threadOperations constants name $ do
    set_constants

    let gtid = kernelGlobalThreadId constants
        dest_is = unflattenIndex shape gtid
        src_is = dest_is

    (_, destspace, destidx) <-
      fullyIndexArray' destloc $ fixSlice destslice dest_is
    (_, srcspace, srcidx) <-
      fullyIndexArray' srcloc $ fixSlice srcslice src_is

    sWhen (gtid .<. kernel_size) $ emit $
      Imp.Write destmem destidx bt destspace Imp.Nonvolatile $
      Imp.index srcmem srcidx bt srcspace Imp.Nonvolatile

compileGroupResult :: SegSpace
                   -> PatElem KernelsMem -> KernelResult
                   -> InKernelGen ()

compileGroupResult _ pe (TileReturns [(w,per_group_elems)] what) = do
  n <- toExp . arraySize 0 =<< lookupType what

  constants <- kernelConstants <$> askEnv
  let ltid = kernelLocalThreadId constants
      offset = toExp' int32 per_group_elems * kernelGroupId constants

  -- Avoid loop for the common case where each thread is statically
  -- known to write at most one element.
  if toExp' int32 per_group_elems == kernelGroupSize constants
    then sWhen (offset + ltid .<. toExp' int32 w) $
         copyDWIMFix (patElemName pe) [ltid + offset] (Var what) [ltid]
    else
    sFor "i" (n `quotRoundingUp` kernelGroupSize constants) $ \i -> do
      j <- fmap Imp.vi32 $ dPrimV "j" $
           kernelGroupSize constants * i + ltid
      sWhen (j .<. n) $ copyDWIMFix (patElemName pe) [j + offset] (Var what) [j]

compileGroupResult space pe (TileReturns dims what) = do
  let gids = map fst $ unSegSpace space
      out_tile_sizes = map (toExp' int32 . snd) dims
      group_is = zipWith (*) (map Imp.vi32 gids) out_tile_sizes
  local_is <- localThreadIDs $ map snd dims
  is_for_thread <- mapM (dPrimV "thread_out_index") $ zipWith (+) group_is local_is

  sWhen (isActive $ zip is_for_thread $ map fst dims) $
    copyDWIMFix (patElemName pe) (map Imp.vi32 is_for_thread) (Var what) local_is

compileGroupResult space pe (RegTileReturns dims_n_tiles what) = do
  constants <- kernelConstants <$> askEnv

  let gids = map fst $ unSegSpace space
      (dims, group_tiles, reg_tiles) = unzip3 dims_n_tiles
      group_tiles' = map (toExp' int32) group_tiles
      reg_tiles' = map (toExp' int32) reg_tiles

  -- Which group tile is this group responsible for?
  let group_tile_is = map Imp.vi32 gids

  -- Within the group tile, which register tile is this thread
  -- responsible for?
  reg_tile_is <-
    mapM (dPrimVE "reg_tile_i") $
    unflattenIndex group_tiles' $ kernelLocalThreadId constants
  reg_tile_is' <-
    mapM (dPrimV "reg_tile_i") $
    unflattenIndex group_tiles' $ kernelLocalThreadId constants

  -- Compute output array slice for the register tile belonging to
  -- this thread.
  let regTileSliceDim (group_tile, group_tile_i) (reg_tile, reg_tile_i) = do
        tile_dim_start <- dPrimVE "tile_dim_start" $
                          reg_tile * (group_tile*group_tile_i + reg_tile_i)
        return $ DimSlice tile_dim_start reg_tile 1
  reg_tile_slices <-
    zipWithM regTileSliceDim
    (zip group_tiles' group_tile_is) (zip reg_tiles' reg_tile_is)

  -- TODO: add missing bounds check !
  localOps threadOperations $ -- TODO: simply putting an sWhen isActive
                              --       here does not work. troels pls
    copyDWIM (patElemName pe) reg_tile_slices (Var what) (map DimFix reg_tile_is)

compileGroupResult space pe (Returns _ what) = do
  constants <- kernelConstants <$> askEnv
  in_local_memory <- arrayInLocalMemory what
  let gids = map (Imp.vi32 . fst) $ unSegSpace space

  if not in_local_memory then
    localOps threadOperations $
    sWhen (kernelLocalThreadId constants .==. 0) $
    copyDWIMFix (patElemName pe) gids what []
    else
      -- If the result of the group is an array in local memory, we
      -- store it by collective copying among all the threads of the
      -- group.  TODO: also do this if the array is in global memory
      -- (but this is a bit more tricky, synchronisation-wise).
      copyDWIMFix (patElemName pe) gids what []

compileGroupResult _ _ WriteReturns{} =
  compilerLimitationS "compileGroupResult: WriteReturns not handled yet."

compileGroupResult _ _ ConcatReturns{} =
  compilerLimitationS "compileGroupResult: ConcatReturns not handled yet."

compileThreadResult :: SegSpace
                    -> PatElem KernelsMem -> KernelResult
                    -> InKernelGen ()

compileThreadResult _ _ RegTileReturns{} =
  compilerLimitationS "compileThreadResult: RegTileReturns not yet handled."

compileThreadResult space pe (Returns _ what) = do
  let is = map (Imp.vi32 . fst) $ unSegSpace space
  copyDWIMFix (patElemName pe) is what []

compileThreadResult _ pe (ConcatReturns SplitContiguous _ per_thread_elems what) = do
  constants <- kernelConstants <$> askEnv
  let offset = toExp' int32 per_thread_elems * kernelGlobalThreadId constants
  n <- toExp' int32 . arraySize 0 <$> lookupType what
  copyDWIM (patElemName pe) [DimSlice offset n 1] (Var what) []

compileThreadResult _ pe (ConcatReturns (SplitStrided stride) _ _ what) = do
  offset <- kernelGlobalThreadId . kernelConstants <$> askEnv
  n <- toExp' int32 . arraySize 0 <$> lookupType what
  copyDWIM (patElemName pe) [DimSlice offset n $ toExp' int32 stride] (Var what) []

compileThreadResult _ pe (WriteReturns rws _arr dests) = do
  constants <- kernelConstants <$> askEnv
  rws' <- mapM toExp rws
  forM_ dests $ \(is, e) -> do
    is' <- mapM toExp is
    let condInBounds i rw = 0 .<=. i .&&. i .<. rw
        write = foldl (.&&.) (kernelThreadActive constants) $
                zipWith condInBounds is' rws'
    sWhen write $ copyDWIMFix (patElemName pe) (map (toExp' int32) is) e []

compileThreadResult _ _ TileReturns{} =
  compilerBugS "compileThreadResult: TileReturns unhandled."

arrayInLocalMemory :: SubExp -> InKernelGen Bool
arrayInLocalMemory (Var name) = do
  res <- lookupVar name
  case res of
    ArrayVar _ entry ->
      (Space "local"==) . entryMemSpace <$>
      lookupMemory (memLocationName (entryArrayLocation entry))
    _ -> return False
arrayInLocalMemory Constant{} = return False
