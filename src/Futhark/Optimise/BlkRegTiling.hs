{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}

-- | Perform a restricted form of block+register tiling corresponding to
--   the following pattern:
--     * a redomap is quasi-perfectly nested inside a kernel with at
--       least two parallel dimension (the perfectly nested restriction
--       is relaxed a bit to allow for SGEMM);
--     * all streamed arrays of redomap are one dimensional;
--     * all streamed arrays are variant to exacly one of the two
--       innermost parallel dimensions, and conversely for each of
--       the two innermost parallel dimensions, there is at least
--       one streamed array variant to it;
--     * the stream's result is a tuple of scalar values, which are
--       also the "thread-in-space" return of the kernel.
--     * We have further restrictions that in principle can be relaxed:
--          the redomap has exactly two array input
--          the redomap produces one scalar result
--          the kernel produces one scalar result
module Futhark.Optimise.BlkRegTiling (mmBlkRegTiling, doRegTiling3D) where

import Control.Monad.Reader
import Control.Monad.State
import Data.List
import qualified Data.Map.Strict as M
import Data.Maybe
import qualified Data.Sequence as Seq
import Debug.Trace
import Futhark.IR.Kernels
import Futhark.MonadFreshNames
import Futhark.Tools
import Futhark.Transform.Rename

type TileM = ReaderT (Scope Kernels) (State VNameSource)

type VarianceTable = M.Map VName Names

mmBlkRegTiling :: Stm Kernels -> TileM (Maybe (Stms Kernels, Stm Kernels))
mmBlkRegTiling (Let pat aux (Op (SegOp (SegMap SegThread {} seg_space ts old_kbody))))
  | KernelBody () kstms [Returns ResultMaySimplify (Var res_nm)] <- old_kbody,
    -- check kernel has one result of primitive type
    [res_tp] <- ts,
    primType res_tp,
    -- build the variance table, that records, for
    -- each variable name, the variables it depends on
    initial_variance <- M.map mempty $ scopeOfSegSpace seg_space,
    variance <- varianceInStms initial_variance kstms,
    -- check that the code fits the pattern having:
    -- some `code1`, followed by one Screma SOAC, followed by some `code2`
    (code1, Just screma_stmt, code2) <- matchCodeStreamCode kstms,
    Let pat_redomap _ (Op _) <- screma_stmt,
    -- checks that the Screma SOAC is actually a redomap and normalizes it
    Just (common_dim, arrs, (_, red_lam, red_nes, map_lam)) <- isTileableRedomap screma_stmt,
    -- check that exactly two 1D arrays are streamed thorugh redomap,
    -- and the result of redomap is one scalar
    -- !!!I need to rearrange this whole thing!!! including inp_A and inp_B
    length arrs == 2 && length red_nes == 1,
    [map_t1t, map_t2t] <- map paramDec $ lambdaParams map_lam,
    [red_t1, _] <- map paramDec $ lambdaParams red_lam,
    primType map_t1t && primType map_t2t && primType red_t1,
    map_t1 <- elemType map_t1t,
    map_t2 <- elemType map_t2t,
    --    map_t1 : map_t2 : [] <- map (elemType . paramDec) (lambdaParams map_lam),

    -- checks that the input arrays to redomap are variant to
    -- exactly one of the two innermost dimensions of the kernel
    Just var_dims <- isInvarTo1of2InnerDims mempty seg_space variance arrs,
    -- trace ("!!!! var_dims: "++pretty var_dims) $ var_dims == [0,1] || var_dims == [1,0],
    var_dims == [0,1],
    -- get the variables on which the first result of redomap depends on
    [redomap_orig_res] <- patternValueElements pat_redomap,
    Just res_red_var <- M.lookup (patElemName redomap_orig_res) variance, -- variance of the reduce result

    -- we furthermore check that code1 is only formed by
    -- 1. statements that slice some globally-declared arrays
    --    to produce the input for the redomap, and
    -- 2. potentially some statements on which the redomap
    --    is independent; these are recorded in `code2''`
    Just (code2'', tab_inv_stm) <-
      foldl
        (processIndirections (namesFromList arrs) res_red_var)
        (Just (Seq.empty, M.empty))
        code1,
    -- identify load_A, load_B
    tmp_stms <- mapMaybe (`M.lookup` tab_inv_stm) arrs,
    length tmp_stms == length arrs,
    -- [inp_A, inp_B] <- arrs,
    zip_AB <- zip tmp_stms arrs,
    [(load_A, inp_A), (load_B, inp_B)] <- if var_dims == [0,1] then zip_AB else reverse zip_AB,
    code1' <- stmsFromList $ stmsToList code1 \\ stmsToList code2'',
    code2' <- code2'' <> code2,
    trace
      ( "Cosmin debug: code1':\n" ++ pretty code1' ++ "\ncode 2:\n" ++ pretty code2
          ++ "\ncode2': \n"
          ++ pretty code2'
          ++ "\n Orig SegSpace: "
          ++ pretty seg_space
          ++ "\n load_A: "
          ++ pretty load_A
          ++ "\n load_B: "
          ++ pretty load_B
          ++ "\n redomap orig result"
          ++ pretty redomap_orig_res
          ++ "\n Cosmin Kernel return: "
          ++ pretty res_nm
          ++ " type: "
          ++ pretty ts
          ++ "\n Old Kernel Body: \n"
          ++ pretty old_kbody
          ++ "\n END MAT-MAT Kernel!"
      )
      True,
    -- TODO: remove the need for these assumptions !

    -- we get the global-thread id for the two inner dimensions,
    --   as we are probably going to use it in code generation
    (gtid_x, width_B) : (gtid_y, height_A) : rem_outer_dims_rev <- reverse $ unSegSpace seg_space,
    rem_outer_dims <- reverse rem_outer_dims_rev,
    -- null rem_outer_dims, -- TODO: remove the need for this assumption !

    -- sanity check that the reduce part is not missing
    not $ null red_nes = do
    let red_ne : _ = red_nes
    red_t <- subExpType red_ne

    ---- in this binder: host code and outer seggroup (ie. the new kernel) ----
    (new_kernel, host_stms) <- runBinder $ do
      -- host code

      tk_name <- nameFromString . pretty <$> newVName "Tk"
      tx_name <- nameFromString . pretty <$> newVName "Tx"
      ty_name <- nameFromString . pretty <$> newVName "Ty"
      rx_name <- nameFromString . pretty <$> newVName "Rx"
      ry_name <- nameFromString . pretty <$> newVName "Ry"

      --        tk         <- letSubExp "Tk" $ Op $ SizeOp $ GetSize tk_name SizeTile
      --        tx         <- letSubExp "Tx" $ Op $ SizeOp $ GetSize tx_name SizeTile
      --        ty         <- letSubExp "Ty" $ Op $ SizeOp $ GetSize ty_name SizeTile
      --        rx         <- letSubExp "Rx" $ Op $ SizeOp $ GetSize rx_name SizeRegTile
      --        ry         <- letSubExp "Ry" $ Op $ SizeOp $ GetSize ry_name SizeRegTile
      (ty, ry) <- getParTiles ("Ty", "Ry") (ty_name, ry_name) height_A
      (tx, rx) <- getParTiles ("Tx", "Rx") (tx_name, rx_name) width_B
      tk <- getSeqTile "Tk" tk_name common_dim ty tx

      tk_div_tx <- letSubExp "tk_div_tx" =<< ceilDiv tk tx
      tk_div_ty <- letSubExp "tk_div_ty" =<< ceilDiv tk ty

      tx_rx <- letSubExp "TxRx" =<< toExp (pe64 tx * pe64 rx)
      ty_ry <- letSubExp "TyRy" =<< toExp (pe64 ty * pe64 ry)

      a_loc_sz <-
        letSubExp "a_loc_sz"
          =<< toExp (pe64 ty * pe64 ry * pe64 tk)

      b_loc_sz <-
        letSubExp "b_loc_sz"
          =<< toExp (pe64 tk * pe64 tx * pe64 rx)

      gridDim_x <- letSubExp "gridDim_x" =<< ceilDiv width_B tx_rx
      gridDim_y <- letSubExp "gridDim_y" =<< ceilDiv height_A ty_ry
      let gridxy_pexp = pe64 gridDim_y * pe64 gridDim_x
      let grid_pexp =
            foldl (\x d -> pe64 d * x) gridxy_pexp $
              map snd rem_outer_dims_rev
      grid_size <- letSubExp "grid_size" =<< toExp grid_pexp
      group_size <- letSubExp "group_size" =<< toExp (pe64 ty * pe64 tx)
      let segthd_lvl = SegThread (Count grid_size) (Count group_size) SegNoVirtFull

      gid_x <- newVName "gid_x"
      gid_y <- newVName "gid_y"
      gid_flat <- newVName "gid_flat"

      ---- in this binder: outer seggroup ----
      (ret_seggroup, stms_seggroup) <- runBinder $ do
        iii <- letExp "iii" =<< toExp (le64 gid_y * pe64 ty_ry)
        jjj <- letExp "jjj" =<< toExp (le64 gid_x * pe64 tx_rx)

        -- initialize register mem with neutral elements.
        cssss_list <- segMap2D "cssss" segthd_lvl ResultPrivate (ty, tx) $ \_ -> do
          css_init <- scratch "css_init" (elemType red_t) [ry, rx]
          css <- forLoop ry [css_init] $ \i [css_merge] -> do
            css' <- forLoop rx [css_merge] $ \j [css_merge'] -> do
              css'' <- update' "css" css_merge' [i, j] red_ne
              resultBodyM [Var css'']
            resultBodyM [Var css']
          return [Var css]
        let [cssss] = cssss_list

        a_loc_init <- scratch "A_loc" map_t1 [a_loc_sz]
        b_loc_init <- scratch "B_loc" map_t2 [b_loc_sz]

        let kkLoopBody kk0 (thd_res_merge, a_loc_init', b_loc_init') epilogue = do
              kk <- letExp "kk" =<< toExp (le64 kk0 * pe64 tk)
              a_loc <- forLoop ry [a_loc_init'] $ \i0 [a_loc_merge] -> do
                loop_a_loc <- forLoop tk_div_tx [a_loc_merge] $ \k0 [a_loc_merge'] -> do
                  scatter_a_loc <- segScatter2D
                    "A_glb2loc"
                    a_loc_sz
                    a_loc_merge'
                    segthd_lvl
                    (ty, tx)
                    $ \(thd_y, thd_x) -> do
                      k <- letExp "k" =<< toExp (le64 thd_x + le64 k0 * pe64 tx)
                      i <- letExp "i" =<< toExp (le64 thd_y + le64 i0 * pe64 ty)

                      letBindNames [gtid_y] =<< toExp (le64 iii + le64 i)
                      a_col_idx <- letExp "A_col_idx" =<< toExp (le64 kk + le64 k)

                      a_elem <-
                        letSubExp "A_elem"
                          =<< eIf
                            ( toExp $
                                le64 gtid_y .<. pe64 height_A
                                  .&&. if epilogue
                                    then le64 a_col_idx .<. pe64 common_dim
                                    else true
                            )
                            ( do
                                addStm load_A
                                res <- index "A_elem" inp_A [a_col_idx]
                                resultBodyM [Var res]
                            )
                            (eBody [eBlank $ Prim map_t1])
                      a_loc_ind <-
                        letSubExp "a_loc_ind"
                          =<< eIf
                            (toExp $ le64 k .<. pe64 tk)
                            ( toExp (le64 k + le64 i * pe64 tk)
                                >>= letTupExp' "loc_fi"
                                >>= resultBodyM
                            )
                            (eBody [pure $ BasicOp $ SubExp $ intConst Int64 (-1)])
                      return (a_elem, a_loc_ind)
                  resultBodyM $ map Var scatter_a_loc
                resultBodyM [Var loop_a_loc]

              -- copy B from global to shared memory
              b_loc <- forLoop tk_div_ty [b_loc_init'] $ \k0 [b_loc_merge] -> do
                loop_b_loc <- forLoop rx [b_loc_merge] $ \j0 [b_loc_merge'] -> do
                  scatter_b_loc <- segScatter2D
                    "B_glb2loc"
                    b_loc_sz
                    b_loc_merge'
                    segthd_lvl
                    (ty, tx)
                    $ \(thd_y, thd_x) -> do
                      k <- letExp "k" =<< toExp (le64 thd_y + le64 k0 * pe64 ty)
                      j <- letExp "j" =<< toExp (le64 thd_x + le64 j0 * pe64 tx)

                      letBindNames [gtid_x] =<< toExp (le64 jjj + le64 j)
                      b_row_idx <- letExp "B_row_idx" =<< toExp (le64 kk + le64 k)

                      b_elem <-
                        letSubExp "B_elem"
                          =<< eIf
                            ( toExp $
                                le64 gtid_x .<. pe64 width_B
                                  .&&. if epilogue
                                    then le64 b_row_idx .<. pe64 common_dim
                                    else true
                            )
                            ( do
                                addStm load_B
                                res <- index "B_elem" inp_B [b_row_idx]
                                resultBodyM [Var res]
                            )
                            (eBody [eBlank $ Prim map_t2])

                      b_loc_ind <-
                        letSubExp "b_loc_ind"
                          =<< eIf
                            (toExp $ le64 k .<. pe64 tk)
                            ( toExp (le64 j + le64 k * pe64 tx_rx)
                                >>= letTupExp' "loc_fi"
                                >>= resultBodyM
                            )
                            (eBody [pure $ BasicOp $ SubExp $ intConst Int64 (-1)])
                      return (b_elem, b_loc_ind)
                  resultBodyM $ map Var scatter_b_loc
                resultBodyM [Var loop_b_loc]

              -- inner loop updating this thread's accumulator (loop k in mmm_kernels).
              thd_acc <- forLoop tk [thd_res_merge] $ \k [acc_merge] ->
                resultBodyM =<< letTupExp' "foo"
                  =<< eIf
                    ( toExp $
                        if epilogue
                          then
                            le64 kk + le64 k
                              .<. pe64 common_dim
                          else true -- if in prologue, always compute redomap.
                    )
                    ( do
                        reg_mem <- segMap2D
                          "reg_mem"
                          segthd_lvl
                          ResultPrivate
                          (ty, tx)
                          $ \(ltid_y, ltid_x) -> do
                            asss_init <- scratch "asss_init" map_t1 [ry]
                            bsss_init <- scratch "bsss_init" map_t2 [rx]

                            asss <- forLoop ry [asss_init] $ \i [asss_merge] -> do
                              a_loc_ind <-
                                letExp "a_loc_ind"
                                  =<< toExp
                                    ( le64 k
                                        + (le64 ltid_y * pe64 ry + le64 i) * pe64 tk
                                    )

                              asss <-
                                index "A_loc_elem" a_loc [a_loc_ind]
                                  >>= update "asss" asss_merge [i]
                              resultBodyM [Var asss]

                            bsss <- forLoop rx [bsss_init] $ \j [bsss_merge] -> do
                              b_loc_ind <-
                                letExp "b_loc_ind"
                                  =<< toExp
                                    ( le64 j
                                        + le64 k * pe64 tx_rx
                                        + le64 ltid_x * pe64 rx
                                    )

                              bsss <-
                                index "B_loc_elem" b_loc [b_loc_ind]
                                  >>= update "bsss" bsss_merge [j]
                              resultBodyM [Var bsss]
                            return $ map Var [asss, bsss]

                        let [asss, bsss] = reg_mem

                        -- the actual redomap.
                        redomap_res <- segMap2D
                          "redomap_res"
                          segthd_lvl
                          ResultPrivate
                          (ty, tx)
                          $ \(ltid_y, ltid_x) -> do
                            as <- index "as" asss [ltid_y, ltid_x]
                            bs <- index "bs" bsss [ltid_y, ltid_x]
                            css_init <- index "css_init" acc_merge [ltid_y, ltid_x]

                            css <- forLoop ry [css_init] $ \i [css_merge] -> do
                              css <- forLoop rx [css_merge] $ \j [css_merge'] ->
                                resultBodyM =<< letTupExp' "foo"
                                  =<< eIf
                                    ( toExp $
                                        le64 iii + le64 i + pe64 ry * le64 ltid_y
                                          .<. pe64 height_A
                                            .&&. le64 jjj + le64 j + pe64 rx * le64 ltid_x
                                          .<. pe64 width_B
                                    )
                                    ( do
                                        a <- index "a" as [i]
                                        b <- index "b" bs [j]
                                        c <- index "c" css_merge' [i, j]

                                        map_res <- newVName "map_res"
                                        map_lam' <- renameLambda map_lam
                                        red_lam' <- renameLambda red_lam

                                        addStms $
                                          rebindLambda map_lam' [a, b] [map_res]
                                            <> rebindLambda red_lam' [c, map_res] [c]

                                        css <- update "css" css_merge' [i, j] c

                                        resultBodyM [Var css]
                                    )
                                    (resultBodyM [Var css_merge'])
                              resultBodyM [Var css]
                            return [Var css]

                        resultBodyM $ map Var redomap_res
                    )
                    (resultBodyM [Var acc_merge])
              return [thd_acc, a_loc, b_loc]

        -- build prologue.
        full_tiles <-
          letExp "full_tiles" $
            BasicOp $ BinOp (SQuot Int64 Unsafe) common_dim tk
        prologue_res_list <-
          forLoop' (Var full_tiles) [cssss, a_loc_init, b_loc_init] $
            \kk0 [thd_res_merge, a_loc_merge, b_loc_merge] -> do
              process_full_tiles <-
                kkLoopBody kk0 (thd_res_merge, a_loc_merge, b_loc_merge) False

              resultBodyM $ map Var process_full_tiles

        let prologue_res : a_loc_reuse : b_loc_reuse : _ = prologue_res_list

        -- build epilogue.
        epilogue_res_list <- kkLoopBody full_tiles (prologue_res, a_loc_reuse, b_loc_reuse) True

        let redomap_res : _ = epilogue_res_list

        -- support for non-empty code2'
        --  segmap (ltid_y < ty, ltid_x < tx) {
        --    for i < ry do
        --      for j < rx do
        --        res = if (iii+ltid_y*ry+i < height_A && jjj+ltid_x*rx+j < width_B)
        --              then code2' else dummy
        --        final_res[i,j] = res
        epilogue_res <-
          if patElemName redomap_orig_res == res_nm
            then return redomap_res -- epilogue_res_list
            else do
              rssss_list <- segMap2D "rssss" segthd_lvl ResultPrivate (ty, tx) $ \(ltid_y, ltid_x) -> do
                rss_init <- scratch "rss_init" (elemType res_tp) [ry, rx]
                css <- index "redomap_thd" redomap_res [ltid_y, ltid_x]
                ii <- letExp "ii" =<< toExp (le64 iii + le64 ltid_y * pe64 ry)
                jj <- letExp "jj" =<< toExp (le64 jjj + le64 ltid_x * pe64 rx)
                rss <- forLoop ry [rss_init] $ \i [rss_merge] -> do
                  rss' <- forLoop rx [rss_merge] $ \j [rss_merge'] -> do
                    c <- index "redomap_elm" css [i, j]
                    cpy_stm <- mkLetNamesM [patElemName redomap_orig_res] $ BasicOp $ SubExp $ Var c
                    addStm cpy_stm
                    letBindNames [gtid_y] =<< toExp (le64 ii + le64 i)
                    letBindNames [gtid_x] =<< toExp (le64 jj + le64 j)

                    res_el <-
                      letSubExp "res_elem"
                        =<< eIf
                          ( toExp $
                              le64 gtid_y .<. pe64 height_A
                                .&&. le64 gtid_x .<. pe64 width_B
                          )
                          ( do
                              addStms code2'
                              resultBodyM [Var res_nm]
                          )
                          (eBody [eBlank res_tp])
                    rss'' <- update' "rss" rss_merge' [i, j] res_el
                    resultBodyM [Var rss'']
                  resultBodyM [Var rss']
                return [Var rss]
              let rssss : _ = rssss_list
              return rssss

        let regtile_ret_dims =
              map (\(_, sz) -> (sz, se1, se1)) rem_outer_dims
                ++ [(height_A, ty, ry), (width_B, tx, rx)]

        -- Add dummy dimensions to tile to reflect the outer dimensions.
        epilogue_res' <-
          if null rem_outer_dims
            then return epilogue_res
            else do
              epilogue_t <- lookupType epilogue_res
              let (block_dims, rest_dims) = splitAt 2 $ arrayDims epilogue_t
                  ones = map (const $ intConst Int64 1) rem_outer_dims
                  new_shape = concat [ones, block_dims, ones, rest_dims]
              letExp "res_reshaped" $ BasicOp $ Reshape (map DimNew new_shape) epilogue_res

        -- TODO: RegTileReturns is still missing boundary checks.
        return [RegTileReturns regtile_ret_dims epilogue_res']

      let level' = SegGroup (Count grid_size) (Count group_size) SegNoVirt
          space' = SegSpace gid_flat (rem_outer_dims ++ [(gid_y, gridDim_y), (gid_x, gridDim_x)])
          kbody' = KernelBody () stms_seggroup ret_seggroup
      return $ Let pat aux $ Op $ SegOp $ SegMap level' space' ts kbody'

    trace ("COSMIN kernel: "++pretty new_kernel) $
      return $ Just (host_stms, new_kernel)
mmBlkRegTiling _ = return Nothing

ceilDiv :: MonadBinder m => SubExp -> SubExp -> m (Exp (Lore m))
ceilDiv x y = pure $ BasicOp $ BinOp (SDivUp Int64 Unsafe) x y

scratch :: MonadBinder m => String -> PrimType -> [SubExp] -> m VName
scratch se_name t shape = letExp se_name $ BasicOp $ Scratch t shape

-- index an array with indices given in outer_indices; any inner
-- dims of arr not indexed by outer_indices are sliced entirely
index :: MonadBinder m => String -> VName -> [VName] -> m VName
index se_desc arr outer_indices = do
  arr_t <- lookupType arr
  let shape = arrayShape arr_t

  let inner_dims = shapeDims $ stripDims (length outer_indices) shape
  let inner_slices =
        map
          ( \inner_dim ->
              DimSlice
                (intConst Int64 0)
                inner_dim
                (intConst Int64 1)
          )
          inner_dims

  let indices = map (DimFix . Var) outer_indices ++ inner_slices
  letExp se_desc $ BasicOp $ Index arr indices

update :: MonadBinder m => String -> VName -> [VName] -> VName -> m VName
update se_desc arr indices new_elem = update' se_desc arr indices (Var new_elem)

update' :: MonadBinder m => String -> VName -> [VName] -> SubExp -> m VName
update' se_desc arr indices new_elem =
  letExp se_desc $ BasicOp $ Update arr (map (DimFix . Var) indices) new_elem

forLoop' ::
  SubExp -> -- loop var
  [VName] -> -- loop inits
  ( VName ->
    [VName] -> -- (loop var -> loop inits -> loop body)
    Binder Kernels (Body Kernels)
  ) ->
  Binder Kernels [VName]
forLoop' i_bound merge body = do
  i <- newVName "i" -- could give this as arg to the function
  let loop_form = ForLoop i Int64 i_bound []

  merge_ts <- mapM lookupType merge
  loop_inits <- mapM (\merge_t -> newParam "merge" $ toDecl merge_t Unique) merge_ts

  loop_body <-
    runBodyBinder $
      inScopeOf loop_form $
        localScope (scopeOfFParams loop_inits) $ body i $ map paramName loop_inits

  letTupExp "loop" $
    DoLoop
      []
      (zip loop_inits $ map Var merge)
      loop_form
      loop_body

forLoop ::
  SubExp ->
  [VName] ->
  (VName -> [VName] -> Binder Kernels (Body Kernels)) ->
  Binder Kernels VName
forLoop i_bound merge body = do
  res_list <- forLoop' i_bound merge body
  return $ head res_list

-- given a lambda "lam", a list "new_params" of new
-- parameters which should be applied to the lambda,
-- and a VName "res_name" which the lambda result should
-- be bound to:
--   creates Stms corresponding to binding of new_params,
--   lambda body, and binding of lambda result to res_name.
rebindLambda ::
  Lambda Kernels ->
  [VName] ->
  [VName] ->
  Stms Kernels
rebindLambda lam new_params res_names =
  stmsFromList
    ( zipWith
        ( \ident new_param ->
            mkLet [] [ident] $ BasicOp $ SubExp $ Var new_param
        )
        idents
        new_params
    )
    <> bodyStms lam_body
    <> stmsFromList res_cpy_stms
  where
    (lam_params, lam_body, lam_ret_type : _) =
      (lambdaParams lam, lambdaBody lam, lambdaReturnType lam)
    idents =
      map
        (\param -> Ident (paramName param) (paramDec param))
        lam_params
    res_cpy_stms =
      zipWith
        ( \res_name lam_res ->
            mkLet [] [Ident res_name lam_ret_type] $ BasicOp $ SubExp lam_res
        )
        res_names
        lam_ress
    lam_ress = bodyResult lam_body

-- | Tries to identify the following pattern:
--   code followed by some Screma followed by more code.
matchCodeStreamCode ::
  Stms Kernels ->
  (Stms Kernels, Maybe (Stm Kernels), Stms Kernels)
matchCodeStreamCode kstms =
  let (code1, screma, code2) =
        foldl
          ( \acc stmt ->
              case (acc, stmt) of
                ((cd1, Nothing, cd2), Let _ _ (Op (OtherOp Screma {}))) ->
                  (cd1, Just stmt, cd2)
                ((cd1, Nothing, cd2), _) ->
                  (cd1 ++ [stmt], Nothing, cd2)
                ((cd1, Just strm, cd2), _) ->
                  (cd1, Just strm, cd2 ++ [stmt])
          )
          ([], Nothing, [])
          (stmsToList kstms)
   in (stmsFromList code1, screma, stmsFromList code2)

isTileableRedomap ::
  Stm Kernels ->
  Maybe
    ( SubExp,
      [VName],
      (Commutativity, Lambda Kernels, [SubExp], Lambda Kernels)
    )
isTileableRedomap stm
  | Op (OtherOp (Screma w form arrs)) <- stmExp stm,
    Just (reds, map_lam) <- isRedomapSOAC form,
    Reduce red_comm red_lam red_nes <- singleReduce reds,
    all (primType . rowType . paramType) $ lambdaParams red_lam,
    all (primType . rowType . paramType) $ lambdaParams map_lam,
    lambdaReturnType map_lam == lambdaReturnType red_lam, -- No mapout arrays.
    not (null arrs),
    all primType $ lambdaReturnType map_lam,
    all (primType . paramType) $ lambdaParams map_lam =
    Just (w, arrs, (red_comm, red_lam, red_nes, map_lam))
  | otherwise =
    Nothing

-- | Checks that all streamed arrays are variant to exacly one of
--   the two innermost parallel dimensions, and conversely, for
--   each of the two innermost parallel dimensions, there is at
--   least one streamed array variant to it. The result is the
--   number of the only variant parallel dimension for each array.
isInvarTo1of2InnerDims ::
  Names ->
  SegSpace ->
  VarianceTable ->
  [VName] ->
  Maybe [Int]
isInvarTo1of2InnerDims branch_variant kspace variance arrs =
  let inner_perm0 = map varToOnly1of2InnerDims arrs
      inner_perm = catMaybes inner_perm0
      ok1 = elem 0 inner_perm && elem 1 inner_perm
      ok2 = length inner_perm0 == length inner_perm
   in if ok1 && ok2 then Just inner_perm else Nothing
  where
    varToOnly1of2InnerDims :: VName -> Maybe Int
    varToOnly1of2InnerDims arr = do
      (j, _) : (i, _) : _ <- Just $ reverse $ unSegSpace kspace
      let variant_to = M.findWithDefault mempty arr variance
          branch_invariant =
            not $
              nameIn j branch_variant
                || nameIn i branch_variant
      if not branch_invariant
        then Nothing -- if i or j in branch_variant; return nothing
        else
          if nameIn i variant_to && not (nameIn j variant_to)
            then Just 0
            else
              if nameIn j variant_to && not (nameIn i variant_to)
                then Just 1
                else Nothing

varianceInStms :: VarianceTable -> Stms Kernels -> VarianceTable
varianceInStms = foldl varianceInStm

-- just in case you need the Screma being treated differently than
-- by default; previously Cosmin had to enhance it when dealing with stream.
varianceInStm :: VarianceTable -> Stm Kernels -> VarianceTable
varianceInStm v0 bnd@(Let _ _ (Op (OtherOp Screma {})))
  | Just (_, arrs, (_, red_lam, red_nes, map_lam)) <- isTileableRedomap bnd =
    let v = defVarianceInStm v0 bnd
        red_args = lambdaParams red_lam
        map_args = lambdaParams map_lam
        card_red = length red_nes
        acc_lam_f = take (card_red `quot` 2) red_args
        arr_lam_f = drop (card_red `quot` 2) red_args
        stm_lam = bodyStms (lambdaBody map_lam) <> bodyStms (lambdaBody red_lam)

        v' =
          foldl'
            ( \vacc (v_a, v_fm, v_fr_acc, v_fr_var) ->
                let vrc = oneName v_a <> M.findWithDefault mempty v_a vacc
                    vacc' = M.insert v_fm vrc vacc
                    vrc' = oneName v_fm <> vrc
                 in M.insert v_fr_acc (oneName v_fr_var <> vrc') $ M.insert v_fr_var vrc' vacc'
            )
            v
            $ zip4 arrs (map paramName map_args) (map paramName acc_lam_f) (map paramName arr_lam_f)
     in varianceInStms v' stm_lam
  | otherwise = defVarianceInStm v0 bnd
varianceInStm v0 bnd = defVarianceInStm v0 bnd

defVarianceInStm :: VarianceTable -> Stm Kernels -> VarianceTable
defVarianceInStm variance bnd =
  foldl' add variance $ patternNames $ stmPattern bnd
  where
    add variance' v = M.insert v binding_variance variance'
    look variance' v = oneName v <> M.findWithDefault mempty v variance'
    binding_variance = mconcat $ map (look variance) $ namesToList (freeIn bnd)

-- alternatively, import TileLoops?
segMap2D ::
  String -> -- desc
  SegLevel -> -- lvl
  ResultManifest -> -- manifest
  (SubExp, SubExp) -> -- (dim_x, dim_y)
  ( (VName, VName) -> -- f
    Binder Kernels [SubExp]
  ) ->
  Binder Kernels [VName]
segMap2D desc lvl manifest (dim_y, dim_x) f = do
  ltid_x <- newVName "ltid_x"
  ltid_flat <- newVName "ltid_flat"
  ltid_y <- newVName "ltid_y"
  let segspace = SegSpace ltid_flat [(ltid_y, dim_y), (ltid_x, dim_x)]

  ((ts, res), stms) <- runBinder $ do
    res <- f (ltid_y, ltid_x)
    ts <- mapM subExpType res
    return (ts, res)
  Body _ stms' res' <- renameBody $ mkBody stms res

  letTupExp desc $
    Op $
      SegOp $
        SegMap lvl segspace ts $ KernelBody () stms' $ map (Returns manifest) res'

segScatter2D ::
  String -> -- desc
  SubExp -> -- arr_size
  VName ->
  SegLevel -> -- lvl
  (SubExp, SubExp) -> -- (dim_y, dim_x)
  ((VName, VName) -> Binder Kernels (SubExp, SubExp)) -> -- f
  Binder Kernels [VName]
segScatter2D desc arr_size updt_arr lvl (dim_x, dim_y) f = do
  ltid_x <- newVName "ltid_x"
  ltid_y <- newVName "ltid_y"
  ltid_flat <- newVName "ltid_flat"
  let segspace = SegSpace ltid_flat [(ltid_x, dim_x), (ltid_y, dim_y)]

  ((t_v, res_v, res_i), stms) <- runBinder $ do
    (res_v, res_i) <- f (ltid_x, ltid_y)
    t_v <- subExpType res_v
    return (t_v, res_v, res_i)

  Body _ stms' res' <- renameBody $ mkBody stms [res_i, res_v]
  let [res_i', res_v'] = res'
  let ret = WriteReturns [arr_size] updt_arr [([DimFix res_i'], res_v')]
  let body = KernelBody () stms' [ret]

  letTupExp desc $ Op $ SegOp $ SegMap lvl segspace [t_v] body

{--
processIndirections :: Names   -- input arrays to redomap
                    -> Names   -- variables on which the result of redomap depends on.
                    -> Maybe (Stms Kernels, M.Map VName (VName, Slice SubExp, Type))
                    -> Stm Kernels
                    -> Maybe (Stms Kernels, M.Map VName (VName, Slice SubExp, Type))
processIndirections arrs _ acc (Let patt _ (BasicOp (Index arr_nm slc)))
  | Just (ss, tab) <- acc,
    [p] <- patternValueElements patt,
    (p_nm, p_tp) <- (patElemName p, patElemType p),
    nameIn p_nm arrs,
    Array _ (Shape [_]) _ <- p_tp =
      Just (ss, M.insert p_nm (arr_nm, slc, p_tp) tab)

processIndirections _ res_red_var acc stm'@(Let patt _ _)
  | Just (ss, tab) <- acc,
    ps <- patternValueElements patt,
    all (\p -> not (nameIn (patElemName p) res_red_var)) ps =
      Just (ss Seq.|> stm', tab)
  | otherwise = Nothing
--}

processIndirections ::
  Names -> -- input arrays to redomap
  Names -> -- variables on which the result of redomap depends on.
  Maybe (Stms Kernels, M.Map VName (Stm Kernels)) ->
  Stm Kernels ->
  Maybe (Stms Kernels, M.Map VName (Stm Kernels))
processIndirections arrs _ acc stm@(Let patt _ (BasicOp (Index _ _)))
  | Just (ss, tab) <- acc,
    [p] <- patternValueElements patt,
    p_nm <- patElemName p,
    nameIn p_nm arrs =
    Just (ss, M.insert p_nm stm tab)
processIndirections _ res_red_var acc stm'@(Let patt _ _)
  | Just (ss, tab) <- acc,
    ps <- patternValueElements patt,
    all (\p -> not (nameIn (patElemName p) res_red_var)) ps =
    Just (ss Seq.|> stm', tab)
  | otherwise = Nothing

se1 :: SubExp
se1 = Constant $ IntValue $ Int64Value 1

se2 :: SubExp
se2 = Constant $ IntValue $ Int64Value 2

se4 :: SubExp
se4 = Constant $ IntValue $ Int64Value 4

se8 :: SubExp
se8 = Constant $ IntValue $ Int64Value 8

getParTiles :: (String, String) -> (Name, Name) -> SubExp -> Binder Kernels (SubExp, SubExp)
getParTiles (t_str, r_str) (t_name, r_name) len_dim =
  case len_dim of
    Constant (IntValue (Int64Value 8)) -> do
      t <- letSubExp t_str $ BasicOp $ SubExp se8
      r <- letSubExp r_str $ BasicOp $ SubExp se1
      return (t, r)
    Constant (IntValue (Int64Value 16)) -> do
      t <- letSubExp t_str $ BasicOp $ SubExp se8
      r <- letSubExp r_str $ BasicOp $ SubExp se2
      return (t, r)
    Constant (IntValue (Int64Value 32)) -> do
      t <- letSubExp t_str $ BasicOp $ SubExp se8
      r <- letSubExp r_str $ BasicOp $ SubExp se4
      return (t, r)
    _ -> do
      t <- letSubExp t_str $ Op $ SizeOp $ GetSize t_name SizeTile
      r <- letSubExp r_str $ Op $ SizeOp $ GetSize r_name SizeRegTile
      return (t, r)

getSeqTile :: String -> Name -> SubExp -> SubExp -> SubExp -> Binder Kernels SubExp
getSeqTile tk_str tk_name len_dim ty tx =
  case (tx, ty) of
    (Constant (IntValue (Int64Value v_x)), Constant (IntValue (Int64Value v_y))) -> do
      let min_val = case len_dim of
            Constant (IntValue (Int64Value v_d)) -> min v_d $ min v_x v_y
            _ -> min v_x v_y
      tk <- letSubExp tk_str $ BasicOp $ SubExp $ Constant $ IntValue $ Int64Value min_val
      return tk
    _ -> do
      tk <- letSubExp tk_str $ Op $ SizeOp $ GetSize tk_name SizeTile
      return tk

----------------------------------------------------------------------------------------------
--- 3D Tiling (RegTiling for the outermost dimension & Block tiling for the innermost two) ---
----------------------------------------------------------------------------------------------

maxRegTile :: Int64
maxRegTile = 30

mkRegTileSe :: Int64 -> SubExp
mkRegTileSe = constant

variantToDim :: VarianceTable -> VName -> VName -> Bool
variantToDim variance gid_outer nm =
  gid_outer == nm || (nameIn gid_outer $ M.findWithDefault mempty nm variance)

-- | Checks that all streamed arrays are variant to exacly one of
--   the two innermost parallel dimensions, and conversely, for
--   each of the two innermost parallel dimensions, there is at
--   least one streamed array variant to it. The result is the
--   number of the only variant parallel dimension for each array.
isInvarTo2of3InnerDims ::
  Names ->
  SegSpace ->
  VarianceTable ->
  [VName] ->
  Maybe [Int]
isInvarTo2of3InnerDims branch_variant kspace variance arrs =
  let inner_perm0 = map varToOnly1of3InnerDims arrs
      inner_perm = catMaybes inner_perm0
      ok1 = elem 0 inner_perm && elem 1 inner_perm && elem 2 inner_perm
      ok2 = length inner_perm0 == length inner_perm
   in if ok1 && ok2 then Just inner_perm else Nothing
  where
    varToOnly1of3InnerDims :: VName -> Maybe Int
    varToOnly1of3InnerDims arr = do
      (k, _) : (j, _) : (i, _) : _ <- Just $ reverse $ unSegSpace kspace
      let variant_to = M.findWithDefault mempty arr variance
          branch_invariant =
            not $
              nameIn k branch_variant
                || nameIn j branch_variant
                || nameIn i branch_variant
      if not branch_invariant
        then Nothing -- if i or j or k in branch_variant; return nothing
        else
          if nameIn i variant_to && not (nameIn j variant_to || nameIn k variant_to)
            then Just 0
            else
              if nameIn j variant_to && not (nameIn i variant_to || nameIn k variant_to)
                then Just 1
                else
                  if nameIn k variant_to && not (nameIn i variant_to || nameIn j variant_to)
                    then Just 2
                    else Nothing

-- | Expects a kernel statement as argument.
--   CONDITIONS for 3D tiling optimization to fire are:
--     1. a) The kernel body can be broken into
--              scalar-code-1 ++ [Redomap stmt] ++ scalar-code-2.
--        b) The kernels has a per-thread result, and obviously
--              the result is variant to the 3rd dimension
--              (counted from innermost to outermost)
--     2. For the Redomap:
--          a) the streamed arrays are one dimensional
--          b) each of the array arguments of Redomap are variant
--              to exactly one of the three innermost-parallel dimension
--              of the kernel. This condition can be relaxed by interchanging
--              kernel dimensions whenever possible.
--     3. For scalar-code-1:
--          a) each of the statements is a slice that produces one of the
--             streamed arrays
--
-- mmBlkRegTiling :: Stm Kernels -> TileM (Maybe (Stms Kernels, Stm Kernels))
-- mmBlkRegTiling (Let pat aux (Op (SegOp (SegMap SegThread{} seg_space ts old_kbody))))
doRegTiling3D :: Stm Kernels -> TileM (Maybe (Stms Kernels, Stm Kernels))
doRegTiling3D (Let pat aux (Op (SegOp old_kernel)))
  | SegMap (SegThread {}) space kertp (KernelBody () kstms kres) <- old_kernel,
    -- build the variance table, that records, for
    -- each variable name, the variables it depends on
    initial_variance <- M.map mempty $ scopeOfSegSpace space,
    variance <- varianceInStms initial_variance kstms,
    -- we get the global-thread id for the two inner dimensions,
    --   as we are probably going to use it in code generation
    (gtid_x, d_Kx) : (gtid_y, d_Ky) : (gtid_z, d_M) : rem_outer_dims_rev <- reverse $ unSegSpace space,
    rem_outer_dims <- reverse rem_outer_dims_rev,
    -- check that the code fits the pattern having:
    -- some `code1`, followed by one Screma SOAC, followed by some `code2`
    (code1, Just screma_stmt, code2) <- matchCodeStreamCode kstms,
    Let pat_redomap _ (Op _) <- screma_stmt,
    -- checks that the Screma SOAC is actually a redomap and normalize it
    Just (common_dim, inp_soac_arrs, (_, red_lam, red_nes, map_lam)) <- isTileableRedomap screma_stmt,
    not (null red_nes),
    -- assuming we have a budget of maxRegTile registers, we distribute
    -- that budget across the result of redomap
    reg_tile <- maxRegTile `quot` fromIntegral (length red_nes),
    reg_tile_se <- mkRegTileSe reg_tile,
    -- check that the element-type of the map and reduce are scalars:
    foldl (&&) True $ map primType $ map paramDec $ lambdaParams map_lam,
    red_res_tps <- map paramDec $ take (length red_nes) $ lambdaParams red_lam,
    foldl (&&) True $ map primType red_res_tps,
    -- checks that the input arrays to redomap are variant to
    -- exactly one of the two innermost dimensions of the kernel
    Just _ <- isInvarTo2of3InnerDims mempty space variance inp_soac_arrs,
    -- get the free variables on which the result of redomap depends on
    redomap_orig_res <- patternValueElements pat_redomap,
    res_red_var <- -- variance of the reduce result
      foldl
        ( \acc nm -> case M.lookup nm variance of
            Nothing -> acc
            Just nms -> acc <> nms
        )
        mempty
        $ map patElemName redomap_orig_res,
    not $ mempty == res_red_var,
    -- we furthermore check that code1 is only formed by
    -- 1. statements that slice some globally-declared arrays
    --    to produce the input for the redomap, and
    -- 2. potentially some statements on which the redomap
    --    is independent; these are recorded in `code2''`
    Just (code2'', arr_tab0) <-
      foldl
        (processIndirections (namesFromList inp_soac_arrs) res_red_var)
        (Just (Seq.empty, M.empty))
        code1,
    -- check that code1 contains exacly one slice for each of the input array to redomap
    tmp_stms <- mapMaybe (`M.lookup` arr_tab0) inp_soac_arrs,
    length tmp_stms == length inp_soac_arrs,
    code1' <- stmsFromList $ stmsToList code1 \\ stmsToList code2'',
    code2' <- code2'' <> code2,
    -- we assume the kernel results are variant to the thrid-outer parallel dimension
    -- (for sanity sake, they should be)
    ker_res_nms <- mapMaybe getResNm kres,
    length ker_res_nms == length kres,
    Pattern [] _ <- pat,
    all primType kertp,
    all (variantToDim variance gtid_z) ker_res_nms,
    trace
      ( "Cosmin3D debug: old_kernel: " ++ pretty old_kernel ++ "\ncode1':\n" ++ pretty code1'
          ++ "\ncode 2:\n"
          ++ pretty code2
          ++ "\ncode2': \n"
          ++ pretty code2'
          ++ "\n redomap orig result"
          ++ pretty redomap_orig_res
          ++ "\n Kernel return: "
          ++ pretty ker_res_nms
          ++ " type: "
          ++ pretty kertp
      )
      $ True = do
    -- HERE STARTS THE IMPLEMENTATION:
    (new_kernel, host_stms) <- runBinder $ do
      -- host code
      -- process the z-variant arrays that need transposition;
      -- these "manifest" statements should come before the kernel
      (tab_inn, tab_out) <-
        foldM
          (insertTranspose variance (gtid_z, d_M))
          (M.empty, M.empty)
          $ M.toList arr_tab0

      tx_name <- nameFromString . pretty <$> newVName "Tx"
      ty_name <- nameFromString . pretty <$> newVName "Ty"

      tx0 <- letSubExp "Tx" $ Op $ SizeOp $ GetSize tx_name SizeTile
      ty0 <- letSubExp "Ty" $ Op $ SizeOp $ GetSize ty_name SizeTile
      ty <- limitTile "Ty" ty0 d_Ky
      tx <- limitTile "Tx" tx0 d_Kx
      let rz = reg_tile_se

      gridDim_x <- letSubExp "gridDim_x" =<< ceilDiv d_Kx tx
      gridDim_y <- letSubExp "gridDim_y" =<< ceilDiv d_Ky ty
      gridDim_z <- letSubExp "gridDim_z" =<< ceilDiv d_M rz
      let gridxyz_pexp = pe64 gridDim_z * pe64 gridDim_y * pe64 gridDim_x
      let grid_pexp =
            foldl (\x d -> pe64 d * x) gridxyz_pexp $
              map snd rem_outer_dims_rev
      grid_size <- letSubExp "grid_size" =<< toExp grid_pexp
      group_size <- letSubExp "group_size" =<< toExp (pe64 ty * pe64 tx)
      let segthd_lvl = SegThread (Count grid_size) (Count group_size) SegNoVirtFull

      count_shmem <- letSubExp "count_shmem" =<< ceilDiv rz group_size

      gid_x <- newVName "gid_x"
      gid_y <- newVName "gid_y"
      gid_z <- newVName "gid_z"
      gid_flat <- newVName "gid_flat"

      ---- in this binder: outer seggroup ----
      (ret_seggroup, stms_seggroup) <- runBinder $ do
        ii <- letExp "ii" =<< toExp (le64 gid_z * pe64 rz)
        jj1 <- letExp "jj1" =<< toExp (le64 gid_y * pe64 ty)
        jj2 <- letExp "jj2" =<< toExp (le64 gid_x * pe64 tx)

        -- initialize the register arrays corresponding to the result of redomap;
        reg_arr_nms <- segMap2D "res" segthd_lvl ResultPrivate (ty, tx) $ \_ -> do
          forM (zip red_nes red_res_tps) $ \(red_ne, red_t) -> do
            css_init <- scratch "res_init" (elemType red_t) [rz]
            css <- forLoop rz [css_init] $ \i [css_merge] -> do
              css' <- update' "css" css_merge [i] red_ne
              resultBodyM [Var css']
            return $ Var css

        -- scratch the shared-memory arrays corresponding to the arrays that are
        --   input to the redomap and are invariant to the outermost parallel dimension.
        loc_arr_nms <- forM (M.toList tab_out) $ \(nm, (ptp, _)) ->
          scratch (baseString nm ++ "_loc") ptp [rz]

        prologue_res_list <-
          forLoop' common_dim (reg_arr_nms ++ loc_arr_nms) $
            \q var_nms -> do
              let reg_arr_merge_nms = take (length red_nes) var_nms
              let loc_arr_merge_nms = drop (length red_nes) var_nms

              -- collective copy from global to shared memory
              loc_arr_nms' <-
                forLoop' count_shmem loc_arr_merge_nms $ \tt loc_arr_merge2_nms -> do
                  loc_arr_merge2_nms' <-
                    forM (zip loc_arr_merge2_nms (M.toList tab_out)) $ \(loc_Y_nm, (glb_Y_nm, (ptp_Y, load_Y))) -> do
                      ltid_flat <- newVName "ltid_flat"
                      ltid <- newVName "ltid"
                      let segspace = SegSpace ltid_flat [(ltid, group_size)]
                      ((res_v, res_i), stms) <- runBinder $ do
                        offs <- letExp "offs" =<< toExp (pe64 group_size * le64 tt)
                        loc_ind <- letExp "loc_ind" =<< toExp (le64 ltid + le64 offs)
                        letBindNames [gtid_z] =<< toExp (le64 ii + le64 loc_ind)
                        let glb_ind = gtid_z
                        y_elm <-
                          letSubExp "y_elem"
                            =<< eIf
                              (toExp $ le64 glb_ind .<. pe64 d_M)
                              ( do
                                  addStm load_Y
                                  res <- index "Y_elem" glb_Y_nm [q]
                                  resultBodyM [Var res]
                              )
                              (eBody [eBlank $ Prim ptp_Y])
                        y_ind <-
                          letSubExp "y_loc_ind"
                            =<< eIf
                              (toExp $ le64 loc_ind .<. pe64 rz)
                              (toExp loc_ind >>= letTupExp' "loc_fi" >>= resultBodyM)
                              (eBody [pure $ BasicOp $ SubExp $ intConst Int64 (-1)])
                        --y_tp  <- subExpType y_elm
                        return (y_elm, y_ind)

                      Body _ stms' res' <- renameBody $ mkBody stms [res_i, res_v]
                      let [res_i', res_v'] = res'
                      let ret = WriteReturns [rz] loc_Y_nm [([DimFix res_i'], res_v')]
                      let body = KernelBody () stms' [ret]

                      res_nms <- letTupExp "Y_glb2loc" $ Op $ SegOp $ SegMap segthd_lvl segspace [Prim ptp_Y] body
                      let res_nm : _ = res_nms
                      return res_nm
                  resultBodyM $ map Var loc_arr_merge2_nms'

              redomap_res <-
                segMap2D "redomap_res" segthd_lvl ResultPrivate (ty, tx) $
                  \(ltid_y, ltid_x) -> do
                    letBindNames [gtid_y] =<< toExp (le64 jj1 + le64 ltid_y)
                    letBindNames [gtid_x] =<< toExp (le64 jj2 + le64 ltid_x)
                    reg_arr_merge_nms_slc <- forM reg_arr_merge_nms $ \reg_arr_nm ->
                      index "res_reg_slc" reg_arr_nm [ltid_y, ltid_x]
                    letTupExp' "redomap_guarded"
                      =<< eIf
                        (toExp $ le64 gtid_y .<. pe64 d_Ky .&&. le64 gtid_x .<. pe64 d_Kx)
                        ( do
                            inp_scals_invar_outer <-
                              forM (M.toList tab_inn) $ \(inp_arr_nm, load_stm) -> do
                                addStm load_stm
                                index (baseString inp_arr_nm) inp_arr_nm [q]
                            -- build the loop of count R whose body is semantically the redomap code
                            reg_arr_merge_nms' <-
                              forLoop' rz reg_arr_merge_nms_slc $ \i reg_arr_mm_nms -> do
                                letBindNames [gtid_z] =<< toExp (le64 ii + le64 i)
                                resultBodyM =<< letTupExp' "redomap_lam"
                                  =<< eIf
                                    (toExp $ le64 gtid_z .<. pe64 d_M)
                                    ( do
                                        -- read from shared memory
                                        ys <- forM loc_arr_nms' $ \loc_arr_nm -> do
                                          index "inp_reg_var2z" loc_arr_nm [i]
                                        cs <- forM reg_arr_mm_nms $ \reg_arr_nm -> do
                                          index "res_reg_var2z" reg_arr_nm [i]
                                        -- here we need to put in order the scalar inputs to map:
                                        let tab_scals =
                                              M.fromList $
                                                zip (map fst $ M.toList tab_out) ys
                                                  ++ zip (map fst $ M.toList tab_inn) inp_scals_invar_outer
                                        map_inp_scals <- forM inp_soac_arrs $ \arr_nm ->
                                          case M.lookup arr_nm tab_scals of
                                            Nothing -> error "Impossible case reached in tiling3D\n"
                                            Just nm -> return nm
                                        map_res_scals <- forM (lambdaReturnType map_lam) $ \_ -> newVName "map_res"
                                        map_lam' <- renameLambda map_lam
                                        red_lam' <- renameLambda red_lam
                                        addStms $
                                          rebindLambda map_lam' map_inp_scals map_res_scals
                                            <> rebindLambda red_lam' (cs ++ map_res_scals) cs
                                        css <- forM (zip reg_arr_mm_nms cs) $ \(reg_arr_nm, c) -> do
                                          update (baseString reg_arr_nm) reg_arr_nm [i] c
                                        resultBodyM $ map Var css
                                    )
                                    (resultBodyM $ map Var reg_arr_mm_nms)
                            resultBodyM $ map Var reg_arr_merge_nms'
                        )
                        (resultBodyM $ map Var reg_arr_merge_nms_slc)
              resultBodyM $ map Var $ redomap_res ++ loc_arr_nms'

        -- support for non-empty code2'
        --  segmap (ltid_y < ty, ltid_x < tx) {
        --    for i < rz do
        --        res = if (ii+i < d_M && jj1+ltid_y < d_Ky && jj2 + ltid_x < d_Kx)
        --              then code2' else dummy
        --        final_res[i] = res
        let redomap_res = take (length red_nes) prologue_res_list
        epilogue_res <-
          if length redomap_orig_res == length ker_res_nms
            && ker_res_nms == (map patElemName redomap_orig_res)
            then -- all (\ (a,b) -> patElemName a == b ) $ zip redomap_orig_res ker_res_nms
              return redomap_res
            else segMap2D "rssss" segthd_lvl ResultPrivate (ty, tx) $ \(ltid_y, ltid_x) -> do
              letBindNames [gtid_y] =<< toExp (le64 jj1 + le64 ltid_y)
              letBindNames [gtid_x] =<< toExp (le64 jj2 + le64 ltid_x)
              rss_init <- forM kertp $ \res_tp ->
                scratch "rss_init" (elemType res_tp) [rz]
              css <- forM redomap_res $ \n_res ->
                index "redomap_thd" n_res [ltid_y, ltid_x]
              rss <- forLoop' rz rss_init $ \i rss_merge -> do
                letBindNames [gtid_z] =<< toExp (le64 ii + le64 i)
                forM_ (zip redomap_orig_res css) $ \(o_res, cs) -> do
                  c <- index "redomap_elm" cs [i]
                  letBindNames [patElemName o_res] =<< toExp (le64 c)
                  return c
                res_els <-
                  letTupExp' "res_elem"
                    =<< eIf
                      ( toExp $
                          le64 gtid_y .<. pe64 d_Ky
                            .&&. le64 gtid_x .<. pe64 d_Kx
                            .&&. le64 gtid_z .<. pe64 d_M
                      )
                      ( do
                          addStms code2'
                          resultBodyM $ map Var ker_res_nms
                      )
                      (eBody $ map eBlank kertp)
                rss' <- forM (zip res_els rss_merge) $ \(res_el, rs_merge) ->
                  update' "rss" rs_merge [i] res_el
                resultBodyM $ map Var rss'
              return $ map Var rss

        ----------------------------------------------------------------
        -- Finally, reshape the result arrays for the RegTileReturn  ---
        ----------------------------------------------------------------
        let regtile_ret_dims =
              map (\(_, sz) -> (sz, se1, se1)) rem_outer_dims
                ++ [(d_M, se1, rz), (d_Ky, ty, se1), (d_Kx, tx, se1)]

        epilogue_res' <- forM epilogue_res $ \res -> do
          res_tp <- lookupType res
          let shape_res = map DimNew $ [se1] ++ arrayDims res_tp ++ [se1, se1]
          res_rshp <- letExp "res_reshaped" $ BasicOp $ Reshape shape_res res
          if null rem_outer_dims
            then return res_rshp
            else do
              -- Add dummy dimensions to tile to reflect the outer dimensions
              res_tp' <- lookupType res_rshp
              let (block_dims, rest_dims) = splitAt 2 $ arrayDims res_tp'
                  ones = map (const se1) rem_outer_dims
                  new_shape = concat [ones, block_dims, ones, rest_dims]
              letExp "res_reshaped" $ BasicOp $ Reshape (map DimNew new_shape) res_rshp

        -- TODO: RegTileReturns is still incorrect, please Fix It
        return $ map (\x -> RegTileReturns regtile_ret_dims x) epilogue_res'
      -- END (ret_seggroup, stms_seggroup) <- runBinder $ do
      let level' = SegGroup (Count grid_size) (Count group_size) SegNoVirt
          space' = SegSpace gid_flat (rem_outer_dims ++ [(gid_z, gridDim_z), (gid_y, gridDim_y), (gid_x, gridDim_x)])
          kbody' = KernelBody () stms_seggroup ret_seggroup

      return $ Let pat aux $ Op $ SegOp $ SegMap level' space' kertp kbody'
    -- END (new_kernel, host_stms) <- runBinder $ do
    --trace ("Cosmin3D end\nhost_stms: " ++ pretty host_stms ++ "\nnew kernel: " ++ pretty new_kernel ++ "\n") $
    return $ Just (host_stms, new_kernel)
  where
    getResNm (Returns ResultMaySimplify (Var res_nm)) = Just res_nm
    getResNm _ = Nothing

    limitTile :: String -> SubExp -> SubExp -> Binder Kernels SubExp
    limitTile t_str t d_K = letSubExp t_str $ BasicOp $ BinOp (SMin Int64) t d_K
    insertTranspose ::
      VarianceTable ->
      (VName, SubExp) ->
      (M.Map VName (Stm Kernels), M.Map VName (PrimType, Stm Kernels)) ->
      (VName, Stm Kernels) ->
      Binder Kernels (M.Map VName (Stm Kernels), M.Map VName (PrimType, Stm Kernels))
    insertTranspose variance (gidz, _) (tab_inn, tab_out) (p_nm, stm@(Let patt yy (BasicOp (Index arr_nm slc))))
      | [p] <- patternValueElements patt,
        ptp <- elemType $ patElemType p,
        p_nm == patElemName p = do
        case findIndices (variantSliceDim variance gidz) slc of
          [] -> return $ (M.insert p_nm stm tab_inn, tab_out)
          i : _ -> do
            arr_tp <- lookupType arr_nm
            let perm = [i + 1 .. arrayRank arr_tp -1] ++ [0 .. i]
            let arr_tr_str = baseString arr_nm ++ "_transp"
            arr_tr_nm <- letExp arr_tr_str $ BasicOp $ Manifest perm arr_nm
            --let p' = p {patElemName = arr_tr_nm}
            --let patt' = patt { patternValueElements = [p']}
            let e_ind' = BasicOp $ Index arr_tr_nm slc
            let stm' = Let patt yy e_ind'
            return (tab_inn, M.insert p_nm (ptp, stm') tab_out)
    insertTranspose _ _ _ _ = error "\nUnreachable case reached in insertTranspose case, doRegTiling3D\n"

    variantSliceDim :: VarianceTable -> VName -> DimIndex SubExp -> Bool
    variantSliceDim variance gidz (DimFix (Var vnm)) = variantToDim variance gidz vnm
    variantSliceDim _ _ _ = False
--processDimSlice (DimFix d) = DimFix d
--processDimSlice (DimSlice beg n strd) = DimSlice se0 n se1

doRegTiling3D _ = return Nothing
