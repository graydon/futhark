{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Futhark.IR.SOACS.Simplify
  ( simplifySOACS,
    simplifyLambda,
    simplifyFun,
    simplifyStms,
    simplifyConsts,
    simpleSOACS,
    simplifySOAC,
    soacRules,
    HasSOAC (..),
    simplifyKnownIterationSOAC,
    removeReplicateMapping,
    liftIdentityMapping,
    SOACS,
  )
where

import Control.Monad
import Control.Monad.Identity
import Control.Monad.State
import Control.Monad.Writer
import Data.Either
import Data.Foldable
import Data.List (partition, transpose, unzip6, zip6)
import qualified Data.Map.Strict as M
import Data.Maybe
import qualified Data.Set as S
import Futhark.Analysis.DataDependencies
import qualified Futhark.Analysis.SymbolTable as ST
import qualified Futhark.Analysis.UsageTable as UT
import qualified Futhark.IR as AST
import Futhark.IR.Prop.Aliases
import Futhark.IR.SOACS
import Futhark.MonadFreshNames
import qualified Futhark.Optimise.Simplify as Simplify
import qualified Futhark.Optimise.Simplify.Engine as Engine
import Futhark.Optimise.Simplify.Rep
import Futhark.Optimise.Simplify.Rule
import Futhark.Optimise.Simplify.Rules
import Futhark.Optimise.Simplify.Rules.ClosedForm
import Futhark.Pass
import Futhark.Tools
import Futhark.Transform.Rename
import Futhark.Util

simpleSOACS :: Simplify.SimpleOps SOACS
simpleSOACS = Simplify.bindableSimpleOps simplifySOAC

simplifySOACS :: Prog SOACS -> PassM (Prog SOACS)
simplifySOACS =
  Simplify.simplifyProg simpleSOACS soacRules Engine.noExtraHoistBlockers

simplifyFun ::
  MonadFreshNames m =>
  ST.SymbolTable (Wise SOACS) ->
  FunDef SOACS ->
  m (FunDef SOACS)
simplifyFun =
  Simplify.simplifyFun simpleSOACS soacRules Engine.noExtraHoistBlockers

simplifyLambda ::
  (HasScope SOACS m, MonadFreshNames m) =>
  Lambda ->
  m Lambda
simplifyLambda =
  Simplify.simplifyLambda simpleSOACS soacRules Engine.noExtraHoistBlockers

simplifyStms ::
  (HasScope SOACS m, MonadFreshNames m) =>
  Stms SOACS ->
  m (ST.SymbolTable (Wise SOACS), Stms SOACS)
simplifyStms stms = do
  scope <- askScope
  Simplify.simplifyStms
    simpleSOACS
    soacRules
    Engine.noExtraHoistBlockers
    scope
    stms

simplifyConsts ::
  MonadFreshNames m =>
  Stms SOACS ->
  m (ST.SymbolTable (Wise SOACS), Stms SOACS)
simplifyConsts =
  Simplify.simplifyStms simpleSOACS soacRules Engine.noExtraHoistBlockers mempty

simplifySOAC ::
  Simplify.SimplifiableRep rep =>
  Simplify.SimplifyOp rep (SOAC rep)
simplifySOAC (VJP lam arr vec) = do
  (lam', hoisted) <- Engine.simplifyLambda lam
  arr' <- mapM Engine.simplify arr
  vec' <- mapM Engine.simplify vec
  return (VJP lam' arr' vec', hoisted)
simplifySOAC (JVP lam arr vec) = do
  (lam', hoisted) <- Engine.simplifyLambda lam
  arr' <- mapM Engine.simplify arr
  vec' <- mapM Engine.simplify vec
  return (JVP lam' arr' vec', hoisted)
simplifySOAC (Stream outerdim arr form nes lam) = do
  outerdim' <- Engine.simplify outerdim
  (form', form_hoisted) <- simplifyStreamForm form
  nes' <- mapM Engine.simplify nes
  arr' <- mapM Engine.simplify arr
  (lam', lam_hoisted) <- Engine.simplifyLambda lam
  return
    ( Stream outerdim' arr' form' nes' lam',
      form_hoisted <> lam_hoisted
    )
  where
    simplifyStreamForm (Parallel o comm lam0) = do
      (lam0', hoisted) <- Engine.simplifyLambda lam0
      return (Parallel o comm lam0', hoisted)
    simplifyStreamForm Sequential =
      return (Sequential, mempty)
simplifySOAC (Scatter len lam ivs as) = do
  len' <- Engine.simplify len
  (lam', hoisted) <- Engine.simplifyLambda lam
  ivs' <- mapM Engine.simplify ivs
  as' <- mapM Engine.simplify as
  return (Scatter len' lam' ivs' as', hoisted)
simplifySOAC (Hist w ops bfun imgs) = do
  w' <- Engine.simplify w
  (ops', hoisted) <- fmap unzip $
    forM ops $ \(HistOp dests_w rf dests nes op) -> do
      dests_w' <- Engine.simplify dests_w
      rf' <- Engine.simplify rf
      dests' <- Engine.simplify dests
      nes' <- mapM Engine.simplify nes
      (op', hoisted) <- Engine.simplifyLambda op
      return (HistOp dests_w' rf' dests' nes' op', hoisted)
  imgs' <- mapM Engine.simplify imgs
  (bfun', bfun_hoisted) <- Engine.simplifyLambda bfun
  return (Hist w' ops' bfun' imgs', mconcat hoisted <> bfun_hoisted)
simplifySOAC (Screma w arrs (ScremaForm scans reds map_lam)) = do
  (scans', scans_hoisted) <- fmap unzip $
    forM scans $ \(Scan lam nes) -> do
      (lam', hoisted) <- Engine.simplifyLambda lam
      nes' <- Engine.simplify nes
      return (Scan lam' nes', hoisted)

  (reds', reds_hoisted) <- fmap unzip $
    forM reds $ \(Reduce comm lam nes) -> do
      (lam', hoisted) <- Engine.simplifyLambda lam
      nes' <- Engine.simplify nes
      return (Reduce comm lam' nes', hoisted)

  (map_lam', map_lam_hoisted) <- Engine.simplifyLambda map_lam

  (,)
    <$> ( Screma <$> Engine.simplify w
            <*> Engine.simplify arrs
            <*> pure (ScremaForm scans' reds' map_lam')
        )
    <*> pure (mconcat scans_hoisted <> mconcat reds_hoisted <> map_lam_hoisted)

instance BuilderOps (Wise SOACS)

fixLambdaParams ::
  (MonadBuilder m, Buildable (Rep m), BuilderOps (Rep m)) =>
  AST.Lambda (Rep m) ->
  [Maybe SubExp] ->
  m (AST.Lambda (Rep m))
fixLambdaParams lam fixes = do
  body <- runBodyBuilder $
    localScope (scopeOfLParams $ lambdaParams lam) $ do
      zipWithM_ maybeFix (lambdaParams lam) fixes'
      return $ lambdaBody lam
  return
    lam
      { lambdaBody = body,
        lambdaParams =
          map fst $
            filter (isNothing . snd) $
              zip (lambdaParams lam) fixes'
      }
  where
    fixes' = fixes ++ repeat Nothing
    maybeFix p (Just x) = letBindNames [paramName p] $ BasicOp $ SubExp x
    maybeFix _ Nothing = return ()

removeLambdaResults :: [Bool] -> AST.Lambda rep -> AST.Lambda rep
removeLambdaResults keep lam =
  lam
    { lambdaBody = lam_body',
      lambdaReturnType = ret
    }
  where
    keep' :: [a] -> [a]
    keep' = map snd . filter fst . zip (keep ++ repeat True)
    lam_body = lambdaBody lam
    lam_body' = lam_body {bodyResult = keep' $ bodyResult lam_body}
    ret = keep' $ lambdaReturnType lam

soacRules :: RuleBook (Wise SOACS)
soacRules = standardRules <> ruleBook topDownRules bottomUpRules

-- | Does this rep contain 'SOAC's in its t'Op's?  A rep must be an
-- instance of this class for the simplification rules to work.
class HasSOAC rep where
  asSOAC :: Op rep -> Maybe (SOAC rep)
  soacOp :: SOAC rep -> Op rep

instance HasSOAC (Wise SOACS) where
  asSOAC = Just
  soacOp = id

topDownRules :: [TopDownRule (Wise SOACS)]
topDownRules =
  [ RuleOp hoistCertificates,
    RuleOp removeReplicateMapping,
    RuleOp removeReplicateWrite,
    RuleOp removeUnusedSOACInput,
    RuleOp simplifyClosedFormReduce,
    RuleOp simplifyKnownIterationSOAC,
    RuleOp liftIdentityMapping,
    RuleOp removeDuplicateMapOutput,
    RuleOp fuseConcatScatter,
    RuleOp simplifyMapIota,
    RuleOp moveTransformToInput
  ]

bottomUpRules :: [BottomUpRule (Wise SOACS)]
bottomUpRules =
  [ RuleOp removeDeadMapping,
    RuleOp removeDeadReduction,
    RuleOp removeDeadWrite,
    RuleBasicOp removeUnnecessaryCopy,
    RuleOp liftIdentityStreaming,
    RuleOp mapOpToOp
  ]

-- Any certificates attached to a trivial Stm in the body might as
-- well be applied to the SOAC itself.
hoistCertificates :: TopDownRuleOp (Wise SOACS)
hoistCertificates vtable pat aux soac
  | (soac', hoisted) <- runState (mapSOACM mapper soac) mempty,
    hoisted /= mempty =
    Simplify $ auxing aux $ certifying hoisted $ letBind pat $ Op soac'
  where
    mapper = identitySOACMapper {mapOnSOACLambda = onLambda}
    onLambda lam = do
      stms' <- mapM onStm $ bodyStms $ lambdaBody lam
      return
        lam
          { lambdaBody =
              mkBody stms' $ bodyResult $ lambdaBody lam
          }
    onStm (Let se_pat se_aux (BasicOp (SubExp se))) = do
      let (invariant, variant) =
            partition (`ST.elem` vtable) $
              unCertificates $ stmAuxCerts se_aux
          se_aux' = se_aux {stmAuxCerts = Certificates variant}
      modify (Certificates invariant <>)
      return $ Let se_pat se_aux' $ BasicOp $ SubExp se
    onStm stm = return stm
hoistCertificates _ _ _ _ =
  Skip

liftIdentityMapping ::
  forall rep.
  (Buildable rep, Simplify.SimplifiableRep rep, HasSOAC (Wise rep)) =>
  TopDownRuleOp (Wise rep)
liftIdentityMapping _ pat aux op
  | Just (Screma w arrs form :: SOAC (Wise rep)) <- asSOAC op,
    Just fun <- isMapSOAC form = do
    let inputMap = M.fromList $ zip (map paramName $ lambdaParams fun) arrs
        free = freeIn $ lambdaBody fun
        rettype = lambdaReturnType fun
        ses = bodyResult $ lambdaBody fun

        freeOrConst (Var v) = v `nameIn` free
        freeOrConst Constant {} = True

        checkInvariance (outId, Var v, _) (invariant, mapresult, rettype')
          | Just inp <- M.lookup v inputMap =
            ( (Pattern [] [outId], BasicOp (Copy inp)) : invariant,
              mapresult,
              rettype'
            )
        checkInvariance (outId, e, t) (invariant, mapresult, rettype')
          | freeOrConst e =
            ( (Pattern [] [outId], BasicOp $ Replicate (Shape [w]) e) : invariant,
              mapresult,
              rettype'
            )
          | otherwise =
            ( invariant,
              (outId, e) : mapresult,
              t : rettype'
            )

    case foldr checkInvariance ([], [], []) $
      zip3 (patternElements pat) ses rettype of
      ([], _, _) -> Skip
      (invariant, mapresult, rettype') -> Simplify $ do
        let (pat', ses') = unzip mapresult
            fun' =
              fun
                { lambdaBody = (lambdaBody fun) {bodyResult = ses'},
                  lambdaReturnType = rettype'
                }
        mapM_ (uncurry letBind) invariant
        auxing aux $
          letBindNames (map patElemName pat') $ Op $ soacOp $ Screma w arrs (mapSOAC fun')
liftIdentityMapping _ _ _ _ = Skip

liftIdentityStreaming :: BottomUpRuleOp (Wise SOACS)
liftIdentityStreaming _ (Pattern [] pes) aux (Stream w arrs form nes lam)
  | (variant_map, invariant_map) <-
      partitionEithers $ map isInvariantRes $ zip3 map_ts map_pes map_res,
    not $ null invariant_map = Simplify $ do
    forM_ invariant_map $ \(pe, arr) ->
      letBind (Pattern [] [pe]) $ BasicOp $ Copy arr

    let (variant_map_ts, variant_map_pes, variant_map_res) = unzip3 variant_map
        lam' =
          lam
            { lambdaBody = (lambdaBody lam) {bodyResult = fold_res ++ variant_map_res},
              lambdaReturnType = fold_ts ++ variant_map_ts
            }

    auxing aux $
      letBind (Pattern [] $ fold_pes ++ variant_map_pes) $
        Op $ Stream w arrs form nes lam'
  where
    num_folds = length nes
    (fold_pes, map_pes) = splitAt num_folds pes
    (fold_ts, map_ts) = splitAt num_folds $ lambdaReturnType lam
    lam_res = bodyResult $ lambdaBody lam
    (fold_res, map_res) = splitAt num_folds lam_res
    params_to_arrs = zip (map paramName $ drop (1 + num_folds) $ lambdaParams lam) arrs

    isInvariantRes (_, pe, Var v)
      | Just arr <- lookup v params_to_arrs =
        Right (pe, arr)
    isInvariantRes x =
      Left x
liftIdentityStreaming _ _ _ _ = Skip

-- | Remove all arguments to the map that are simply replicates.
-- These can be turned into free variables instead.
removeReplicateMapping ::
  (Buildable rep, Simplify.SimplifiableRep rep, HasSOAC (Wise rep)) =>
  TopDownRuleOp (Wise rep)
removeReplicateMapping vtable pat aux op
  | Just (Screma w arrs form) <- asSOAC op,
    Just fun <- isMapSOAC form,
    Just (bnds, fun', arrs') <- removeReplicateInput vtable fun arrs = Simplify $ do
    forM_ bnds $ \(vs, cs, e) -> certifying cs $ letBindNames vs e
    auxing aux $ letBind pat $ Op $ soacOp $ Screma w arrs' $ mapSOAC fun'
removeReplicateMapping _ _ _ _ = Skip

-- | Like 'removeReplicateMapping', but for 'Scatter'.
removeReplicateWrite :: TopDownRuleOp (Wise SOACS)
removeReplicateWrite vtable pat aux (Scatter len lam ivs as)
  | Just (bnds, lam', ivs') <- removeReplicateInput vtable lam ivs = Simplify $ do
    forM_ bnds $ \(vs, cs, e) -> certifying cs $ letBindNames vs e
    auxing aux $ letBind pat $ Op $ Scatter len lam' ivs' as
removeReplicateWrite _ _ _ _ = Skip

removeReplicateInput ::
  Aliased rep =>
  ST.SymbolTable rep ->
  AST.Lambda rep ->
  [VName] ->
  Maybe
    ( [([VName], Certificates, AST.Exp rep)],
      AST.Lambda rep,
      [VName]
    )
removeReplicateInput vtable fun arrs
  | not $ null parameterBnds = do
    let (arr_params', arrs') = unzip params_and_arrs
        fun' = fun {lambdaParams = acc_params <> arr_params'}
    return (parameterBnds, fun', arrs')
  | otherwise = Nothing
  where
    params = lambdaParams fun
    (acc_params, arr_params) =
      splitAt (length params - length arrs) params
    (params_and_arrs, parameterBnds) =
      partitionEithers $ zipWith isReplicateAndNotConsumed arr_params arrs

    isReplicateAndNotConsumed p v
      | Just (BasicOp (Replicate (Shape (_ : ds)) e), v_cs) <-
          ST.lookupExp v vtable,
        not $ paramName p `nameIn` consumedByLambda fun =
        Right
          ( [paramName p],
            v_cs,
            case ds of
              [] -> BasicOp $ SubExp e
              _ -> BasicOp $ Replicate (Shape ds) e
          )
      | otherwise =
        Left (p, v)

-- | Remove inputs that are not used inside the SOAC.
removeUnusedSOACInput :: TopDownRuleOp (Wise SOACS)
removeUnusedSOACInput _ pat aux (Screma w arrs (ScremaForm scan reduce map_lam))
  | (used, unused) <- partition usedInput params_and_arrs,
    not (null unused) = Simplify $ do
    let (used_params, used_arrs) = unzip used
        map_lam' = map_lam {lambdaParams = used_params}
    auxing aux $ letBind pat $ Op $ Screma w used_arrs (ScremaForm scan reduce map_lam')
  where
    params_and_arrs = zip (lambdaParams map_lam) arrs
    used_in_body = freeIn $ lambdaBody map_lam
    usedInput (param, _) = paramName param `nameIn` used_in_body
removeUnusedSOACInput _ _ _ _ = Skip

removeDeadMapping :: BottomUpRuleOp (Wise SOACS)
removeDeadMapping (_, used) pat aux (Screma w arrs form)
  | Just fun <- isMapSOAC form =
    let ses = bodyResult $ lambdaBody fun
        isUsed (bindee, _, _) = (`UT.used` used) $ patElemName bindee
        (pat', ses', ts') =
          unzip3 $
            filter isUsed $
              zip3 (patternElements pat) ses $ lambdaReturnType fun
        fun' =
          fun
            { lambdaBody = (lambdaBody fun) {bodyResult = ses'},
              lambdaReturnType = ts'
            }
     in if pat /= Pattern [] pat'
          then
            Simplify $
              auxing aux $
                letBind (Pattern [] pat') $ Op $ Screma w arrs $ mapSOAC fun'
          else Skip
removeDeadMapping _ _ _ _ = Skip

removeDuplicateMapOutput :: TopDownRuleOp (Wise SOACS)
removeDuplicateMapOutput _ pat aux (Screma w arrs form)
  | Just fun <- isMapSOAC form =
    let ses = bodyResult $ lambdaBody fun
        ts = lambdaReturnType fun
        pes = patternValueElements pat
        ses_ts_pes = zip3 ses ts pes
        (ses_ts_pes', copies) =
          foldl checkForDuplicates (mempty, mempty) ses_ts_pes
     in if null copies
          then Skip
          else Simplify $ do
            let (ses', ts', pes') = unzip3 ses_ts_pes'
                pat' = Pattern [] pes'
                fun' =
                  fun
                    { lambdaBody = (lambdaBody fun) {bodyResult = ses'},
                      lambdaReturnType = ts'
                    }
            auxing aux $ letBind pat' $ Op $ Screma w arrs $ mapSOAC fun'
            forM_ copies $ \(from, to) ->
              letBind (Pattern [] [to]) $ BasicOp $ Copy $ patElemName from
  where
    checkForDuplicates (ses_ts_pes', copies) (se, t, pe)
      | Just (_, _, pe') <- find (\(x, _, _) -> x == se) ses_ts_pes' =
        -- This subexp has been returned before, producing the
        -- array pe'.
        (ses_ts_pes', (pe', pe) : copies)
      | otherwise = (ses_ts_pes' ++ [(se, t, pe)], copies)
removeDuplicateMapOutput _ _ _ _ = Skip

-- Mapping some operations becomes an extension of that operation.
mapOpToOp :: BottomUpRuleOp (Wise SOACS)
mapOpToOp (_, used) pat aux1 e
  | Just (map_pe, cs, w, BasicOp (Reshape newshape reshape_arr), [p], [arr]) <-
      isMapWithOp pat e,
    paramName p == reshape_arr,
    not $ UT.isConsumed (patElemName map_pe) used = Simplify $ do
    let redim
          | isJust $ shapeCoercion newshape = DimCoercion w
          | otherwise = DimNew w
    certifying (stmAuxCerts aux1 <> cs) $
      letBind pat $
        BasicOp $ Reshape (redim : newshape) arr
  | Just
      ( _,
        cs,
        _,
        BasicOp (Concat d arr arrs dw),
        ps,
        outer_arr : outer_arrs
        ) <-
      isMapWithOp pat e,
    (arr : arrs) == map paramName ps =
    Simplify $
      certifying (stmAuxCerts aux1 <> cs) $
        letBind pat $
          BasicOp $ Concat (d + 1) outer_arr outer_arrs dw
  | Just
      ( map_pe,
        cs,
        _,
        BasicOp (Rearrange perm rearrange_arr),
        [p],
        [arr]
        ) <-
      isMapWithOp pat e,
    paramName p == rearrange_arr,
    not $ UT.isConsumed (patElemName map_pe) used =
    Simplify $
      certifying (stmAuxCerts aux1 <> cs) $
        letBind pat $
          BasicOp $ Rearrange (0 : map (1 +) perm) arr
  | Just (map_pe, cs, _, BasicOp (Rotate rots rotate_arr), [p], [arr]) <-
      isMapWithOp pat e,
    paramName p == rotate_arr,
    not $ UT.isConsumed (patElemName map_pe) used =
    Simplify $
      certifying (stmAuxCerts aux1 <> cs) $
        letBind pat $
          BasicOp $ Rotate (intConst Int64 0 : rots) arr
mapOpToOp _ _ _ _ = Skip

isMapWithOp ::
  PatternT dec ->
  SOAC (Wise SOACS) ->
  Maybe
    ( PatElemT dec,
      Certificates,
      SubExp,
      AST.Exp (Wise SOACS),
      [Param Type],
      [VName]
    )
isMapWithOp pat e
  | Pattern [] [map_pe] <- pat,
    Screma w arrs form <- e,
    Just map_lam <- isMapSOAC form,
    [Let (Pattern [] [pe]) aux2 e'] <-
      stmsToList $ bodyStms $ lambdaBody map_lam,
    [Var r] <- bodyResult $ lambdaBody map_lam,
    r == patElemName pe =
    Just (map_pe, stmAuxCerts aux2, w, e', lambdaParams map_lam, arrs)
  | otherwise = Nothing

-- | Some of the results of a reduction (or really: Redomap) may be
-- dead.  We remove them here.  The trick is that we need to look at
-- the data dependencies to see that the "dead" result is not
-- actually used for computing one of the live ones.
removeDeadReduction :: BottomUpRuleOp (Wise SOACS)
removeDeadReduction (_, used) pat aux (Screma w arrs form)
  | Just ([Reduce comm redlam nes], maplam) <- isRedomapSOAC form,
    not $ all (`UT.used` used) $ patternNames pat, -- Quick/cheap check
    let (red_pes, map_pes) = splitAt (length nes) $ patternElements pat,
    let redlam_deps = dataDependencies $ lambdaBody redlam,
    let redlam_res = bodyResult $ lambdaBody redlam,
    let redlam_params = lambdaParams redlam,
    let used_after =
          map snd $
            filter ((`UT.used` used) . patElemName . fst) $
              zip red_pes redlam_params,
    let necessary =
          findNecessaryForReturned
            (`elem` used_after)
            (zip redlam_params $ redlam_res <> redlam_res)
            redlam_deps,
    let alive_mask = map ((`nameIn` necessary) . paramName) redlam_params,
    not $ all (== True) alive_mask = Simplify $ do
    let fixDeadToNeutral lives ne = if lives then Nothing else Just ne
        dead_fix = zipWith fixDeadToNeutral alive_mask nes
        (used_red_pes, _, used_nes) =
          unzip3 $
            filter (\(_, x, _) -> paramName x `nameIn` necessary) $
              zip3 red_pes redlam_params nes

    let maplam' = removeLambdaResults (take (length nes) alive_mask) maplam
    redlam' <- removeLambdaResults (take (length nes) alive_mask) <$> fixLambdaParams redlam (dead_fix ++ dead_fix)

    auxing aux $
      letBind (Pattern [] $ used_red_pes ++ map_pes) $
        Op $ Screma w arrs $ redomapSOAC [Reduce comm redlam' used_nes] maplam'
removeDeadReduction _ _ _ _ = Skip

-- | If we are writing to an array that is never used, get rid of it.
removeDeadWrite :: BottomUpRuleOp (Wise SOACS)
removeDeadWrite (_, used) pat aux (Scatter w fun arrs dests) =
  let (i_ses, v_ses) = unzip $ groupScatterResults' dests $ bodyResult $ lambdaBody fun
      (i_ts, v_ts) = unzip $ groupScatterResults' dests $ lambdaReturnType fun
      isUsed (bindee, _, _, _, _, _) = (`UT.used` used) $ patElemName bindee
      (pat', i_ses', v_ses', i_ts', v_ts', dests') =
        unzip6 $
          filter isUsed $
            zip6 (patternElements pat) i_ses v_ses i_ts v_ts dests
      fun' =
        fun
          { lambdaBody = (lambdaBody fun) {bodyResult = concat i_ses' ++ v_ses'},
            lambdaReturnType = concat i_ts' ++ v_ts'
          }
   in if pat /= Pattern [] pat'
        then
          Simplify $
            auxing aux $
              letBind (Pattern [] pat') $ Op $ Scatter w fun' arrs dests'
        else Skip
removeDeadWrite _ _ _ _ = Skip

-- handles now concatenation of more than two arrays
fuseConcatScatter :: TopDownRuleOp (Wise SOACS)
fuseConcatScatter vtable pat _ (Scatter _ fun arrs dests)
  | Just (ws@(w' : _), xss, css) <- unzip3 <$> mapM isConcat arrs,
    xivs <- transpose xss,
    all (w' ==) ws = Simplify $ do
    let r = length xivs
    fun2s <- mapM (\_ -> renameLambda fun) [1 .. r -1]
    let (fun_is, fun_vs) =
          unzip $
            map
              ( splitScatterResults dests
                  . bodyResult
                  . lambdaBody
              )
              (fun : fun2s)
        (its, vts) =
          unzip $
            replicate r $
              splitScatterResults dests $ lambdaReturnType fun
        new_stmts = mconcat $ map (bodyStms . lambdaBody) (fun : fun2s)
    let fun' =
          Lambda
            { lambdaParams = mconcat $ map lambdaParams (fun : fun2s),
              lambdaBody =
                mkBody new_stmts $
                  mix fun_is <> mix fun_vs,
              lambdaReturnType = mix its <> mix vts
            }
    certifying (mconcat css) $
      letBind pat $ Op $ Scatter w' fun' (concat xivs) $ map (incWrites r) dests
  where
    sizeOf :: VName -> Maybe SubExp
    sizeOf x = arraySize 0 . typeOf <$> ST.lookup x vtable
    mix = concat . transpose
    incWrites r (w, n, a) = (w, n * r, a) -- ToDO: is it (n*r) or (n+r-1)??
    isConcat v = case ST.lookupExp v vtable of
      Just (BasicOp (Concat 0 x ys _), cs) -> do
        x_w <- sizeOf x
        y_ws <- mapM sizeOf ys
        guard $ all (x_w ==) y_ws
        return (x_w, x : ys, cs)
      Just (BasicOp (Reshape reshape arr), cs) -> do
        guard $ isJust $ shapeCoercion reshape
        (a, b, cs') <- isConcat arr
        return (a, b, cs <> cs')
      _ -> Nothing
fuseConcatScatter _ _ _ _ = Skip

simplifyClosedFormReduce :: TopDownRuleOp (Wise SOACS)
simplifyClosedFormReduce _ pat _ (Screma (Constant w) _ form)
  | Just nes <- concatMap redNeutral . fst <$> isRedomapSOAC form,
    zeroIsh w =
    Simplify $
      forM_ (zip (patternNames pat) nes) $ \(v, ne) ->
        letBindNames [v] $ BasicOp $ SubExp ne
simplifyClosedFormReduce vtable pat _ (Screma _ arrs form)
  | Just [Reduce _ red_fun nes] <- isReduceSOAC form =
    Simplify $ foldClosedForm (`ST.lookupExp` vtable) pat red_fun nes arrs
simplifyClosedFormReduce _ _ _ _ = Skip

-- For now we just remove singleton SOACs.
simplifyKnownIterationSOAC ::
  (Buildable rep, Simplify.SimplifiableRep rep, HasSOAC (Wise rep)) =>
  TopDownRuleOp (Wise rep)
simplifyKnownIterationSOAC _ pat _ op
  | Just (Screma (Constant k) arrs (ScremaForm scans reds map_lam)) <- asSOAC op,
    oneIsh k = Simplify $ do
    let (Reduce _ red_lam red_nes) = singleReduce reds
        (Scan scan_lam scan_nes) = singleScan scans
        (scan_pes, red_pes, map_pes) =
          splitAt3 (length scan_nes) (length red_nes) $
            patternElements pat
        bindMapParam p a = do
          a_t <- lookupType a
          letBindNames [paramName p] $
            BasicOp $ Index a $ fullSlice a_t [DimFix $ constant (0 :: Int64)]
        bindArrayResult pe se =
          letBindNames [patElemName pe] $
            BasicOp $ ArrayLit [se] $ rowType $ patElemType pe
        bindResult pe se =
          letBindNames [patElemName pe] $ BasicOp $ SubExp se

    zipWithM_ bindMapParam (lambdaParams map_lam) arrs
    (to_scan, to_red, map_res) <-
      splitAt3 (length scan_nes) (length red_nes)
        <$> bodyBind (lambdaBody map_lam)
    scan_res <- eLambda scan_lam $ map eSubExp $ scan_nes ++ to_scan
    red_res <- eLambda red_lam $ map eSubExp $ red_nes ++ to_red

    zipWithM_ bindArrayResult scan_pes scan_res
    zipWithM_ bindResult red_pes red_res
    zipWithM_ bindArrayResult map_pes map_res
simplifyKnownIterationSOAC _ pat _ op
  | Just (Stream (Constant k) arrs _ nes fold_lam) <- asSOAC op,
    oneIsh k = Simplify $ do
    let (chunk_param, acc_params, slice_params) =
          partitionChunkedFoldParameters (length nes) (lambdaParams fold_lam)

    letBindNames [paramName chunk_param] $
      BasicOp $ SubExp $ intConst Int64 1

    forM_ (zip acc_params nes) $ \(p, ne) ->
      letBindNames [paramName p] $ BasicOp $ SubExp ne

    forM_ (zip slice_params arrs) $ \(p, arr) ->
      letBindNames [paramName p] $ BasicOp $ SubExp $ Var arr

    res <- bodyBind $ lambdaBody fold_lam

    forM_ (zip (patternNames pat) res) $ \(v, se) ->
      letBindNames [v] $ BasicOp $ SubExp se
simplifyKnownIterationSOAC _ _ _ _ = Skip

data ArrayOp
  = ArrayIndexing Certificates VName (Slice SubExp)
  | ArrayRearrange Certificates VName [Int]
  | ArrayRotate Certificates VName [SubExp]
  | ArrayCopy Certificates VName
  | -- | Never constructed.
    ArrayVar Certificates VName
  deriving (Eq, Ord, Show)

arrayOpArr :: ArrayOp -> VName
arrayOpArr (ArrayIndexing _ arr _) = arr
arrayOpArr (ArrayRearrange _ arr _) = arr
arrayOpArr (ArrayRotate _ arr _) = arr
arrayOpArr (ArrayCopy _ arr) = arr
arrayOpArr (ArrayVar _ arr) = arr

arrayOpCerts :: ArrayOp -> Certificates
arrayOpCerts (ArrayIndexing cs _ _) = cs
arrayOpCerts (ArrayRearrange cs _ _) = cs
arrayOpCerts (ArrayRotate cs _ _) = cs
arrayOpCerts (ArrayCopy cs _) = cs
arrayOpCerts (ArrayVar cs _) = cs

isArrayOp :: Certificates -> AST.Exp (Wise SOACS) -> Maybe ArrayOp
isArrayOp cs (BasicOp (Index arr slice)) =
  Just $ ArrayIndexing cs arr slice
isArrayOp cs (BasicOp (Rearrange perm arr)) =
  Just $ ArrayRearrange cs arr perm
isArrayOp cs (BasicOp (Rotate rots arr)) =
  Just $ ArrayRotate cs arr rots
isArrayOp cs (BasicOp (Copy arr)) =
  Just $ ArrayCopy cs arr
isArrayOp _ _ =
  Nothing

fromArrayOp :: ArrayOp -> (Certificates, AST.Exp (Wise SOACS))
fromArrayOp (ArrayIndexing cs arr slice) = (cs, BasicOp $ Index arr slice)
fromArrayOp (ArrayRearrange cs arr perm) = (cs, BasicOp $ Rearrange perm arr)
fromArrayOp (ArrayRotate cs arr rots) = (cs, BasicOp $ Rotate rots arr)
fromArrayOp (ArrayCopy cs arr) = (cs, BasicOp $ Copy arr)
fromArrayOp (ArrayVar cs arr) = (cs, BasicOp $ SubExp $ Var arr)

arrayOps :: AST.Body (Wise SOACS) -> S.Set (AST.Pattern (Wise SOACS), ArrayOp)
arrayOps = mconcat . map onStm . stmsToList . bodyStms
  where
    onStm (Let pat aux e) =
      case isArrayOp (stmAuxCerts aux) e of
        Just op -> S.singleton (pat, op)
        Nothing -> execState (walkExpM walker e) mempty
    onOp = execWriter . mapSOACM identitySOACMapper {mapOnSOACLambda = onLambda}
    onLambda lam = do
      tell $ arrayOps $ lambdaBody lam
      return lam
    walker =
      identityWalker
        { walkOnBody = const $ modify . (<>) . arrayOps,
          walkOnOp = modify . (<>) . onOp
        }

replaceArrayOps ::
  M.Map ArrayOp ArrayOp ->
  AST.Body (Wise SOACS) ->
  AST.Body (Wise SOACS)
replaceArrayOps substs (Body _ stms res) =
  mkBody (fmap onStm stms) res
  where
    onStm (Let pat aux e) =
      let (cs', e') = onExp (stmAuxCerts aux) e
       in certify cs' $
            mkLet' (patternContextIdents pat) (patternValueIdents pat) aux e'
    onExp cs e
      | Just op <- isArrayOp cs e,
        Just op' <- M.lookup op substs =
        fromArrayOp op'
    onExp cs e = (cs, mapExp mapper e)
    mapper =
      identityMapper
        { mapOnBody = const $ return . replaceArrayOps substs,
          mapOnOp = return . onOp
        }
    onOp = runIdentity . mapSOACM identitySOACMapper {mapOnSOACLambda = return . onLambda}
    onLambda lam = lam {lambdaBody = replaceArrayOps substs $ lambdaBody lam}

-- Turn
--
--    map (\i -> ... xs[i] ...) (iota n)
--
-- into
--
--    map (\i x -> ... x ...) (iota n) xs
--
-- This is not because we want to encourage the map-iota pattern, but
-- it may be present in generated code.  This is an unfortunately
-- expensive simplification rule, since it requires multiple passes
-- over the entire lambda body.  It only handles the very simplest
-- case - if you find yourself planning to extend it to handle more
-- complex situations (rotate or whatnot), consider turning it into a
-- separate compiler pass instead.
simplifyMapIota :: TopDownRuleOp (Wise SOACS)
simplifyMapIota vtable pat aux (Screma w arrs (ScremaForm scan reduce map_lam))
  | Just (p, _) <- find isIota (zip (lambdaParams map_lam) arrs),
    indexings <-
      filter (indexesWith (paramName p)) $
        map snd $
          S.toList $
            arrayOps $ lambdaBody map_lam,
    not $ null indexings = Simplify $ do
    -- For each indexing with iota, add the corresponding array to
    -- the Screma, and construct a new lambda parameter.
    (more_arrs, more_params, replacements) <-
      unzip3 . catMaybes <$> mapM mapOverArr indexings
    let substs = M.fromList $ zip indexings replacements
        map_lam' =
          map_lam
            { lambdaParams = lambdaParams map_lam <> more_params,
              lambdaBody =
                replaceArrayOps substs $
                  lambdaBody map_lam
            }

    auxing aux $
      letBind pat $ Op $ Screma w (arrs <> more_arrs) (ScremaForm scan reduce map_lam')
  where
    isIota (_, arr) = case ST.lookupBasicOp arr vtable of
      Just (Iota _ (Constant o) (Constant s) _, _) ->
        zeroIsh o && oneIsh s
      _ -> False

    indexesWith v (ArrayIndexing cs arr (DimFix (Var i) : _))
      | arr `ST.elem` vtable,
        all (`ST.elem` vtable) $ unCertificates cs =
        i == v
    indexesWith _ _ = False

    mapOverArr (ArrayIndexing cs arr slice) = do
      arr_elem <- newVName $ baseString arr ++ "_elem"
      arr_t <- lookupType arr
      arr' <-
        if arraySize 0 arr_t == w
          then return arr
          else
            certifying cs $
              letExp (baseString arr ++ "_prefix") $
                BasicOp $
                  Index arr $
                    fullSlice arr_t [DimSlice (intConst Int64 0) w (intConst Int64 1)]
      return $
        Just
          ( arr',
            Param arr_elem (rowType arr_t),
            ArrayIndexing cs arr_elem (drop 1 slice)
          )
    mapOverArr _ = return Nothing
simplifyMapIota _ _ _ _ = Skip

-- If a Screma's map function contains a transformation
-- (e.g. transpose) on a parameter, create a new parameter
-- corresponding to that transformation performed on the rows of the
-- full array.
moveTransformToInput :: TopDownRuleOp (Wise SOACS)
moveTransformToInput vtable pat aux (Screma w arrs (ScremaForm scan reduce map_lam))
  | ops <- map snd $ filter arrayIsMapParam $ S.toList $ arrayOps $ lambdaBody map_lam,
    not $ null ops = Simplify $ do
    (more_arrs, more_params, replacements) <-
      unzip3 . catMaybes <$> mapM mapOverArr ops

    when (null more_arrs) cannotSimplify

    let substs = M.fromList $ zip ops replacements
        map_lam' =
          map_lam
            { lambdaParams = lambdaParams map_lam <> more_params,
              lambdaBody =
                replaceArrayOps substs $
                  lambdaBody map_lam
            }

    auxing aux $
      letBind pat $ Op $ Screma w (arrs <> more_arrs) (ScremaForm scan reduce map_lam')
  where
    map_param_names = map paramName (lambdaParams map_lam)
    topLevelPattern = (`elem` fmap stmPattern (bodyStms (lambdaBody map_lam)))
    onlyUsedOnce arr =
      case filter ((arr `nameIn`) . freeIn) $ stmsToList $ bodyStms $ lambdaBody map_lam of
        _ : _ : _ -> False
        _ -> True

    -- It's not just about whether the array is a parameter;
    -- everything else must be map-invariant.
    arrayIsMapParam (pat', ArrayIndexing cs arr slice) =
      arr `elem` map_param_names
        && all (`ST.elem` vtable) (namesToList $ freeIn cs <> freeIn slice)
        && not (null slice)
        && (not (null $ sliceDims slice) || (topLevelPattern pat' && onlyUsedOnce arr))
    arrayIsMapParam (_, ArrayRearrange cs arr perm) =
      arr `elem` map_param_names
        && all (`ST.elem` vtable) (namesToList $ freeIn cs)
        && not (null perm)
    arrayIsMapParam (_, ArrayRotate cs arr rots) =
      arr `elem` map_param_names
        && all (`ST.elem` vtable) (namesToList $ freeIn cs <> freeIn rots)
    arrayIsMapParam (_, ArrayCopy cs arr) =
      arr `elem` map_param_names
        && all (`ST.elem` vtable) (namesToList $ freeIn cs)
    arrayIsMapParam (_, ArrayVar {}) =
      False

    mapOverArr op
      | Just (_, arr) <- find ((== arrayOpArr op) . fst) (zip map_param_names arrs) = do
        arr_t <- lookupType arr
        let whole_dim = DimSlice (intConst Int64 0) (arraySize 0 arr_t) (intConst Int64 1)
        arr_transformed <- certifying (arrayOpCerts op) $
          letExp (baseString arr ++ "_transformed") $
            case op of
              ArrayIndexing _ _ slice ->
                BasicOp $ Index arr $ whole_dim : slice
              ArrayRearrange _ _ perm ->
                BasicOp $ Rearrange (0 : map (+ 1) perm) arr
              ArrayRotate _ _ rots ->
                BasicOp $ Rotate (intConst Int64 0 : rots) arr
              ArrayCopy {} ->
                BasicOp $ Copy arr
              ArrayVar {} ->
                BasicOp $ SubExp $ Var arr
        arr_transformed_t <- lookupType arr_transformed
        arr_transformed_row <- newVName $ baseString arr ++ "_transformed_row"
        return $
          Just
            ( arr_transformed,
              Param arr_transformed_row (rowType arr_transformed_t),
              ArrayVar mempty arr_transformed_row
            )
    mapOverArr _ = return Nothing
moveTransformToInput _ _ _ _ =
  Skip
