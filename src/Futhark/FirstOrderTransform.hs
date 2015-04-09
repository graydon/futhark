-- | The code generator cannot handle the array combinators (@map@ and
-- friends), so this module was written to transform them into the
-- equivalent do-loops.  The transformation is currently rather naive
-- - it's certainly worth considering when we can express such
-- transformations in-place.  This module should be run very late in
-- the compilation pipeline, ideally just before the code generator.
module Futhark.FirstOrderTransform
  ( transformProg
  )
  where

import Control.Applicative
import Control.Monad.State
import Data.Maybe
import qualified Data.HashMap.Lazy as HM
import Data.List

import Prelude

import Futhark.Representation.Basic
import Futhark.Renamer
import Futhark.MonadFreshNames
import Futhark.Tools

-- | Perform the first-order transformation on an Futhark program.  The
-- resulting program is not uniquely named, so make sure to run the
-- renamer!
transformProg :: Prog -> Prog
transformProg prog =
  renameProg $ Prog $ evalState (mapM transformFunDec $ progFunctions prog) src
  where src = newNameSourceForProg prog

transformFunDec :: MonadFreshNames m => FunDec -> m FunDec
transformFunDec (FunDec fname rettype params body) = do
  body' <- runBinder $ transformBody body
  return $ FunDec fname rettype params body'

transformBody :: Body -> Binder Basic Body
transformBody = mapBodyM transform

-- | Transform a single expression.
transformExp :: Exp -> Binder Basic Exp

transformExp (LoopOp (Map cs fun arrs)) = do
  i <- newVName "i"
  out_ts <- mapType fun <$> mapM lookupType arrs
  resarr <- resultArray out_ts
  outarrs <- forM out_ts $ \t ->
             newIdent "map_outarr" $ t `setUniqueness` Unique
  let outarrs_names = map identName outarrs
  loopbody <- runBinder $ do
    x <- bodyBind =<< transformLambda fun (index cs arrs (Var i))
    dests <- letwith cs outarrs_names (pexp $ Var i) $ map (PrimOp . SubExp) x
    return $ resultBody $ map Var dests
  return $ LoopOp $
    DoLoop outarrs_names (loopMerge outarrs (map Var resarr))
    (ForLoop i (arraysSize 0 out_ts)) loopbody

transformExp (LoopOp op@(ConcatMap cs fun inputs)) = do
  arrs <- forM inputs $ \input -> do
    fun' <- renameLambda fun
    let funparams = lambdaParams fun'
        (ctxparams, valparams) =
          splitAt (length funparams-length input) funparams
        fun'' = fun' { lambdaParams = valparams }
    shapemap <- shapeMapping (map identType valparams) <$>
                mapM lookupType input
    forM_ (HM.toList shapemap) $ \(size,se) ->
      when (size `elem` map identName ctxparams) $
        letBindNames'_ [size] $ PrimOp $ SubExp se
    input' <- forM (zip valparams input) $ \(p,v) ->
      letExp "concatMap_reshaped_input" $
      PrimOp $ Reshape [] (arrayDims $ identType p) v
    vs <- bodyBind =<< transformLambda fun'' (map (PrimOp . SubExp . Var) input')
    mapM (letExp "concatMap_fun_res" . PrimOp . SubExp) vs
  emptyarrs <- mapM (letExp "empty")
               [ PrimOp $ ArrayLit [] t | t <- lambdaReturnType fun ]
  let hackbody = Body () [] $ Result $ map Var emptyarrs

      concatArrays (arr, arrs') = do
        let plus x y = eBinOp Plus x y Int
        n <- arraySize 0 <$> lookupType arr
        ms <- mapM (liftM (arraySize 0) . lookupType) arrs'
        ressize <- letSubExp "concatMap_result_size" =<<
                   foldl plus
                   (pure $ PrimOp $ SubExp $ n)
                   (map (pure . PrimOp . SubExp) ms)
        res <- letSubExp "concatMap_result" $ PrimOp $ Concat cs arr arrs' ressize
        return $ PrimOp $ Copy res

      nonempty :: [VName] -> Maybe (VName, [VName])
      nonempty []     = Nothing
      nonempty (x:xs) = Just (x, xs)

  realbody <- runBinder $
    case mapM nonempty $ transpose arrs of
      Nothing ->
        return hackbody
      Just arrs' ->
        resultBody <$> mapM (letSubExp "concatMap_result" <=< concatArrays) arrs'
  opt <- loopOpExtType op
  return $ If (Constant $ LogVal False) hackbody realbody opt

transformExp (LoopOp (Reduce cs fun args)) = do
  ((acc, initacc), i) <- newFold accexps
  arrts <- mapM lookupType arrexps
  let arrus = map (uniqueness . identType) $
              snd $ splitAt (length args) $ lambdaParams fun
  inarrs <- forM (zip arrts arrus) $ \(t,u) ->
            newIdent "reduce_inarr" (setUniqueness t u)
  loopbody <- runBinder $ do
    acc' <- bodyBind =<< transformLambda fun
            (map (PrimOp . SubExp . Var . identName) acc ++
             index cs (map identName inarrs) (Var i))
    return $ resultBody (map (Var . identName) inarrs ++ acc')
  return $ LoopOp $
    DoLoop (map identName acc) (loopMerge (inarrs++acc) (map Var arrexps++initacc))
    (ForLoop i (isize inarrs)) loopbody
  where (accexps, arrexps) = unzip args

transformExp (LoopOp (Scan cs fun args)) = do
  ((acc, initacc), i) <- newFold accexps
  arrts <- mapM lookupType arrexps
  initarr <- resultArray arrts
  arr <- forM arrts $ \t ->
    newIdent "scan_arr" $ t `setUniqueness` Unique
  let arr_names = map identName arr
  loopbody <- insertBindingsM $ do
    x <- bodyBind =<<
         transformLambda fun (map (PrimOp . SubExp . Var . identName) acc ++
                              index cs arrexps (Var i))
    dests <- letwith cs arr_names (pexp (Var i)) $ map (PrimOp . SubExp) x
    irows <- letSubExps "row" $ index cs dests $ Var i
    rowcopies <- letExps "copy" $ map (PrimOp . Copy) irows
    return $ resultBody $ map Var $ rowcopies ++ dests
  return $ LoopOp $
    DoLoop (map identName arr) (loopMerge (acc ++ arr) (initacc ++ map Var initarr))
    (ForLoop i (isize arr)) loopbody
  where (accexps, arrexps) = unzip args

transformExp (LoopOp (Redomap cs _ innerfun accexps arrexps)) = do
  arrts <- mapM lookupType arrexps
  let outersize = arraysSize 0 arrts
  -- for the MAP    part
  let acc_num     = length accexps
  let res_tps     = lambdaReturnType innerfun
  let map_arr_tps = drop acc_num res_tps
  let res_ts = [ arrayOf t (Shape [outersize]) (uniqueness t)
               | t <- map_arr_tps ]
  let arrus = map (uniqueness . identType) $
              snd $ splitAt acc_num $ lambdaParams innerfun
  maparrs <- resultArray res_ts
  outarrs <- forM res_ts $ \t ->
             newIdent "redomap_outarr" $ t `setUniqueness` Unique
  -- for the REDUCE part
  ((acc, initacc), i) <- newFold accexps
  inarrs <- forM (zip arrts arrus) $ \(t,u) ->
            newIdent "redomap_inarr" (setUniqueness t u)
  loopbody <- runBinder $ do
    accxis<- bodyBind =<< transformLambda innerfun
             (map (PrimOp . SubExp . Var . identName) acc ++
              index cs (map identName inarrs) (Var i))
    let (acc', xis) = splitAt acc_num accxis
    dests <- letwith cs (map identName outarrs) (pexp (Var i)) $
             map (PrimOp . SubExp) xis
    return $ resultBody (map (Var . identName) inarrs ++ acc' ++ map Var dests)
  return $ LoopOp $
    DoLoop (map identName $ acc++outarrs)
    (loopMerge (inarrs++acc++outarrs)
     (map Var arrexps++initacc++map Var maparrs))
    (ForLoop i (isize inarrs)) loopbody

transformExp (LoopOp Stream{}) =
    fail "transformExp (Stream): Unreachable case reached!"

transformExp e = mapExpM transform e

transformBinding :: Binding -> Binder Basic Binding
transformBinding (Let pat annot e@(LoopOp Stream{})) =
  Let pat annot <$> transformStreamExp pat e
transformBinding (Let pat annot e) =
  Let pat annot <$> transformExp e

transform :: Mapper Basic Basic (Binder Basic)
transform = identityMapper {
              mapOnBinding = transformBinding
            , mapOnBody = insertBindingsM . transformBody
            }

newFold :: [SubExp]
        -> Binder Basic (([Ident], [SubExp]), VName)
newFold accexps = do
  i <- newVName "i"
  initacc <- letSubExps "acc" $ map (PrimOp . Copy) accexps
  acc <- forM accexps $ \e -> newIdent "acc" =<< subExpType e
  return ((acc, initacc), i)

index :: Certificates -> [VName] -> SubExp -> [Exp]
index cs arrs i = flip map arrs $ \arr ->
  PrimOp $ Index cs arr [i]

resultArray :: [TypeBase Shape] -> Binder Basic [VName]
resultArray = mapM arrayOfShape
  where arrayOfShape t = letExp "result" $ PrimOp $ Scratch (elemType t) (arrayDims t)

letwith :: Certificates -> [VName] -> Binder Basic Exp -> [Exp] -> Binder Basic [VName]
letwith cs ks i vs = do
  vs' <- letSubExps "values" vs
  i' <- letSubExp "i" =<< i
  let update k v =
        letInPlace "lw_dest" cs k [i'] $ PrimOp $ SubExp v
  zipWithM update ks vs'

isize :: [Ident] -> SubExp
isize = arraysSize 0 . map identType

pexp :: Applicative f => SubExp -> f Exp
pexp = pure . PrimOp . SubExp

transformLambda :: Lambda -> [Exp] -> Binder Basic Body
transformLambda (Lambda params body _) args = do
  forM_ (zip params args) $ \(param, arg) ->
    if unique (identType param) then
      letBindNames' [identName param] =<< eCopy (pure arg)
    else
      letBindNames' [identName param] arg
  transformBody body

loopMerge :: [Ident] -> [SubExp] -> [(FParam, SubExp)]
loopMerge vars vals = [ (FParam var (), val) | (var,val) <- zip vars vals ]


-- | Translation of STREAM is non-trivial and quite incomplete for the moment!
-- Assumming size of @A@ is @m@, @?0@ has a known upper bound @U@, and @?1@
-- is purely existential, the intent is to translate a stream exp such as:
-- @stream (fn {int,[int,m],[int,?0],[real,?1]@
-- @           (int chunkloc, int i, int acc, [int] a) =>@
-- @               body in {acc', x, y, z}@
-- @       , acc0, A)@
-- into a loop in which the input array is streamed by splitting each time
-- chunk elements from it, and using the rest as a loop-merge variable.
-- 1. For an array of exact upper bound @x@, we insert a prologue loop that
--    in-place updates the local-chunk elements to a global array, which
--    is statically allocated outside the loop. The global array needs of
--    course to become a loop-merge variable.
-- 2. For an array of known outermost size upper bound U, we also introduce
--    an induction variable that is incremented at the end of the loop with
--    the current size of the local array, and obviously the copy-back-loop
--    counter is the size of the local array @y@.
-- 3. Finally for a purely-existential outer size, e.g., @z@ we initialize
--    the global array outer dimension with the outermost size of the stream,
--    and maintain two induction variables as merge variables of the loop:
--    one that keeps the allocated size of the outermost dimension and
--    one that keeps the current outermost size of the array
--    (pushback vectors)
-- A Loop pseudocode is:
-- @let chunkglb = 16 in@
-- @let (Xglb0,Yglb0,Zglb0)=(scratch(N,..),scratch(U,..),scratch(N,..)) in@
-- loop( {Aloop, A_iv, z_al, y_iv, z_iv, acc, Xglb, Yglb, Zglb} =   @
-- @      {A,     N,    0,    0,    0,    acc0,Xglb0,Yglb0,Zglb0} )=@
-- @  for i_chk < (N+chunkglb-1)/chunkglb do                        @
-- @    let i        = chunkglb * i_chk          in                 @
-- @    let A_cur_sz = N - i*chunkglb            in                 @
-- @    let chunkloc = min(chunkglb, A_iv)       in                 @
-- @    let A_nxt_sz = A_cur_sz - chunkloc       in                 @
-- @    let (elms,Anxt) = split(chunkloc, Aloop) in                 @
-- @    ... body ...                                                @
-- @    ............                                                @
-- @    let z_iv' = z_iv + size(0,z)             in                 @
-- @    let {z_al',Zglb'} =                                         @
-- @      if z_iv' <= z_al then {z_al, Zglb}                        @
-- @      else let Znew = scratch(2*z_iv') in                       @
-- @           loop(Znew) = for j < z_iv do                         @
-- @               let Znew[j] = Zglb[j]                            @
-- @               in  Znew                                         @
-- @           in {2*z_iv', Znew}                                   @
-- @    loop (Zglb') = for j < size(0,z) do                         @
-- @        let Zglb'[j+z_iv] = z[j]                                @
-- @        in  Zglb'                                               @
-- @    in {Anxt,A_nxt_sz,z_al',y_iv',z_iv',acc',Xglb',Yglb',Zglb'} @
-- @in                                                              @
-- @let {X, Y, Z} = {Xglb, split(y_iv,Yglb), split(z_iv,Zglb)} ...  @
--
-- Hope you got the idea at least because the code is terrible :-)
transformStreamExp :: Pattern -> Exp -> Binder Basic Exp
transformStreamExp pattern (LoopOp (Stream cs accexps arrexps lam)) = do
  -- 1.) trivial step: find and build some of the basic things you need
  let lampars = extLambdaParams     lam
      lamrtps = extLambdaReturnType lam
      lambody = extLambdaBody       lam
  -- a) ilam becomes the loop_index*chunkglb,
  -- b) chunkloc is the chunk used inside the loop body
  -- c) chunkglb is the global chunk (set to 1 or a convenient number)
  -- d) inarrVsz is the variant size of the streamed input array in the loop.
  (chunkloc,ilam) <- case lampars of
                    chnk:iorig:_ -> return (chnk,iorig)
                    _ -> fail "FirstOrderTransform Stream: chunk or i error!"
  chunkglb <- newIdent (textual (identName chunkloc) ++"_glb") $ Basic Int
  outersz <- arraysSize 0 <$> mapM lookupType arrexps
  let acc_num = length accexps
      arrrtps = drop acc_num lamrtps
      sub_chko= HM.fromList [(identName chunkloc, outersz)]
      arruniq = map (uniqueness . identType)
                    (snd $ splitAt (acc_num+2) lampars)
  -- 2.) Make the existential induction variables, allocated-size variables,
  --       and all possible instantiations of the existential types, i.e.,
  --       inside and outside the loop body!
  assocs   <- mkExistAssocs outersz arrrtps pattern
  initrtps <- forM (zip arrrtps assocs) $ \ (tp,(_,mub)) -> do
                let deflt0= case mub of
                              UnknownBd -> outersz
                              UpperBd s -> s
                              ExactBd s -> s
                    deflt = if deflt0 == Var (identName chunkloc)
                            then outersz else deflt0
                    dims  = extShapeDims $ arrayShape tp
                    dims' = map (exToNormShapeDim deflt sub_chko) dims
                    restp :: Type
                    restp = Array (elemType tp) (Shape dims') (uniqueness tp)
                return restp
  (mexistszs,mexistinds,botharrtps) <-
    unzip3 <$> forM (zip assocs initrtps) (mkAllExistIdAndTypes outersz)
  let (exszvar,    exszarres,  exszses  ) = unzip3 $ catMaybes mexistszs
      (exindvars,  indvarres,  exindses ) = unzip3 $ catMaybes mexistinds
      (lftedrtps1, lftedrtps2, exactrtps) = unzip3   botharrtps
      patarrnms = map (textual . identName) (fst $ unzip assocs)
  -- various result array identifiers
  outarrinit <- forM (zip initrtps  patarrnms) $ \(t,nm) ->
                    newIdent (nm++"_init") $ t `setUniqueness` Unique
  outarrloop <- forM (zip lftedrtps1 patarrnms) $ \(t,nm) ->
                    newIdent (nm++"_loop") $ t `setUniqueness` Unique
  strmresarrl<- forM (zip lftedrtps2 patarrnms) $ \(t,nm) ->
                    newIdent (nm++"_resL") $ t `setUniqueness` Unique
  strmresarr <- forM (zip exactrtps patarrnms) $ \(t,nm) ->
                    newIdent (nm++"_resE") $ t `setUniqueness` Unique
  strmresacc <- forM accexps $ \a ->
                    newIdent "stream_accres" =<< subExpType a
  -- various stream array identifiers and outer sizes
  inarrVsz <- newIdent "stream_cursize" $ Basic Int
  inarrNsz <- newIdent "stream_nxtsize" $ Basic Int
  bothinarrsloop <- forM (zip arrexps arruniq) $ \(aid,u) -> do
          atp <- lookupType aid
          let anm = textual aid
          (t1,t2) <- case atp of
              Array bt (Shape (_:dims)) _ ->
                  return ( Array bt (Shape $ Var (identName inarrVsz):dims) u
                         , Array bt (Shape $ Var (identName inarrNsz):dims) u)
              _ -> fail "FirstOrderTransform(Stream): array of not array type"
          id1 <- newIdent (anm++"_inloop1") t1
          id2 <- newIdent (anm++"_inloop2") t2
          return (id1, id2)
  let (inarrsloop1, inarrsloop2) = unzip bothinarrsloop
  acc0     <- forM accexps $ \e -> newIdent "acc" =<< subExpType e
  loopind  <- newVName "stream_i"
  loopcnt  <- newIdent "stream_N" $ Basic Int
  -- 3.) Transform the stream's lambda to a loop body
  loopbody <- runBinder $ do
      let argsacc = map (PrimOp . SubExp . Var . identName) acc0
          accpars = take acc_num $ drop 2 lampars
          arrpars = drop (2 + acc_num) lampars
      accxis <- bodyBind =<< do
          -- for accumulators:
          forM_ (zip accpars argsacc) $ \(param, arg) ->
            if unique (identType param) then
              letBindNames' [identName param] =<< eCopy (pure arg)
            else
              letBindNames' [identName param] arg
          -- ilam := i*chunk_glb, the local chunk
          -- inside the loop, together with the size of the
          -- remaining stream in `inarrNsz'
          ilamexp <- eBinOp Times
                            (pure $ PrimOp $ SubExp $ Var loopind)
                            (pure $ PrimOp $ SubExp $ Var $ identName chunkglb)
                            Int
          addBinding $ myMkLet ilamexp ilam
          -- inarrtmpsz := total_stream_size - ilam
          inarrtmpsz <- newIdent "stream_curszind" $ Basic Int
          subexp <- eBinOp Minus
                           ( pure $ PrimOp $ SubExp outersz )
                           ( pure $ PrimOp $ SubExp $ Var $ identName ilam )
                           Int
          addBinding $ myMkLet subexp inarrtmpsz
          -- chunk_loc = min chunk_glb inarrtmpsz
          ifexp <- eIf (eBinOp Leq (pure $ PrimOp $ SubExp $ Var $ identName chunkglb)
                                   (pure $ PrimOp $ SubExp $ Var $ identName inarrtmpsz)
                               Bool)
                       (pure $ resultBody [Var $ identName chunkglb])
                       (pure $ resultBody [Var $ identName inarrtmpsz])
          addBinding $ myMkLet ifexp chunkloc
          -- inarrNsz := inarrtmpsz - chunk_loc, i.e., the size of
          -- the remaining stream after consuming the current chunk.
          remstrmszexp <-
            eBinOp Minus (pure $ PrimOp $ SubExp $ Var $ identName inarrtmpsz)
                         (pure $ PrimOp $ SubExp $ Var $ identName chunkloc)
                         Int
          addBinding $ myMkLet remstrmszexp inarrNsz
          -- split input streams into current chunk and rest of stream
          forM_ (zip3 arrpars inarrsloop1 inarrsloop2) $
            \(param, inarr1, inarr2) -> do
                let myarg = PrimOp $ Split [] [Var $ identName chunkloc,
                                               Var $ identName inarrNsz] $
                                     identName inarr1
                tmpid <- newIdent "tmpelem" $ identType param
                _ <- letBindNames' [identName tmpid, identName inarr2] myarg
                -- UGLY: I NEED TO COPY THE UNIQUE ARGUMENT TO MAKE IT
                --       WORK IN SOME CASES WHERE THE ARRAY IS MODIFIED IN PLACE.
                letBindNames' [identName param] =<<
                  eCopy (pure (PrimOp $ SubExp $ Var $ identName tmpid))
          let fakebody = Body (bodyLore lambody) (bodyBindings lambody) (bodyResult lambody)
          transformBody fakebody
      -- make copy-out epilogue for result arrays
      let (acc', xis) = splitAt acc_num accxis
          indszids = zip mexistszs mexistinds
      epilogue <- forM (zip3 indszids outarrloop xis) $
                       mkOutArrEpilogue cs (Var $ identName ilam)
      let (mszvars,mindvars,dests) = unzip3 epilogue
          (indvars,szvars) = (catMaybes mindvars, catMaybes mszvars)
      return $
        resultBody (map (Var . identName) (inarrNsz : inarrsloop2 ++ szvars ++ indvars) ++
                    acc' ++
                    map (Var . identName) dests)
  -- 4.) Build the loop
  initacc0 <- letSubExps "acc" $ map (PrimOp . Copy) accexps --WHY COPY???
  let accres  = exindvars ++ acc0
      accall  = exszvar ++ accres
      initacc = exszses ++ exindses  ++ initacc0
      loopres = LoopOp $
                DoLoop (map identName $ accres++outarrloop)
                       (loopMerge (inarrVsz:inarrsloop1++accall++outarrloop)
                                  (outersz:map Var arrexps++initacc++
                                   map (Var . identName) outarrinit))
                       (ForLoop loopind (Var $ identName loopcnt)) loopbody
      loopbnd = mkLet ( map (\x->(x,BindVar)) $
                        exszarres++indvarres++strmresacc++strmresarrl ) loopres
  -- 5.) A stream needs prologue-loop-epilogue bindings, so we make a dummy
  --     IF exp to return one expression
  outarrrshpbnds <-
    forM (zip5 strmresarr strmresarrl exactrtps mexistszs mexistinds) $
    \(arr,arrl,_,malocsz,msz) ->
    case (malocsz,msz) of
      (Nothing, Nothing)    ->
        -- regular array case!
        return $ myMkLet (PrimOp $ SubExp $ Var $ identName arrl) arr
      (_, Just (_,indvar,_)) ->
        -- array with known upper bound case!
        return $ myMkLet (PrimOp $ Split [] [Var $ identName indvar] $ identName arrl) arr
      _ -> fail "Stream UNREACHABLE in outarrrshpbnds computation!"
  let allbnds = loopbnd : outarrrshpbnds
  thenbody <- runBinder $ do
      addBinding $ myMkLet (PrimOp $ SubExp $ intconst 1) chunkglb
      lUBexp <- eBinOp Divide
                       (eBinOp Plus (pure $ PrimOp $ SubExp outersz)
                                    (eBinOp Minus (pure $ PrimOp $ SubExp $ Var $ identName chunkglb)
                                                  (pure $ PrimOp $ SubExp $ intconst 1) Int)
                                    Int)
                       (pure $ PrimOp $ SubExp $ Var $ identName chunkglb)
                       Int
      addBinding $ myMkLet lUBexp loopcnt
      let outinibds= zipWith (\ idd tp ->
                                 myMkLet (PrimOp $ Scratch (elemType tp) (arrayDims tp)) idd
                             ) outarrinit initrtps
      mapM_ addBinding (outinibds++allbnds)
      return $ resultBody (map (Var . identName) strmresacc ++
                           map (Var . identName) strmresarr)
  elsebody <- runBinder $ do
      fakeoutarrs <- resultArray  initrtps
      return $ resultBody (accexps ++ map Var fakeoutarrs)
  eIf (pure $ PrimOp $ SubExp $ Constant $ LogVal True)
      (pure thenbody)
      (pure elsebody)
  where myMkLet :: Exp -> Ident -> Binding
        myMkLet e idd = mkLet [(idd,BindVar)] e
        exToNormShapeDim :: SubExp -> HM.HashMap VName SubExp -> ExtDimSize -> SubExp
        exToNormShapeDim d _ (Ext   _) = d
        exToNormShapeDim _ _ (Free c@(Constant _)) = c
        exToNormShapeDim _ subs (Free (Var idd)) =
          fromMaybe (Var idd) $ HM.lookup idd subs
        existUpperBound :: SubExp -> Bool -> MEQType
        existUpperBound outerSize b =
            if not b then UnknownBd
            else UpperBd outerSize
        -- | Assumes rtps are the array result types and pat is the
        -- pattern result of stream in let bound.  Result is a list of
        -- tuples: (1st) the ident of the array in pattern, (2rd) the
        -- exact/upper bound/unknown shape of the outer dim.
        mkExistAssocs :: SubExp -> [ExtType] -> Pattern -> Binder Basic [(Ident, MEQType)]
        mkExistAssocs outerSize rtps pat = do
          let patels    = patternElements pat
              -- keep only the patterns corresponding to the array types
              arrpatels = drop (length patels - length rtps) patels
              processAssoc (rtp,patel) = do
                  let patid = patElemIdent patel
                      rtpdim= extShapeDims $ arrayShape rtp
                  case rtpdim of
                    Ext  _:_ -> return (patid, existUpperBound outerSize withUpperBound )
                    Free s:_ -> return (patid, ExactBd s            )
                    _        ->
                        fail "FirstOrderTrabsform(Stream), mkExistAssocs: Empty Array Shape!"
          forM (zip rtps arrpatels) processAssoc
        mkAllExistIdAndTypes :: SubExp
                             -> ( (Ident, MEQType), Type )
                             -> Binder Basic ( Maybe (Ident,Ident,SubExp), Maybe (Ident,Ident,SubExp), (Type,Type,Type) )
        mkAllExistIdAndTypes _ ((_, ExactBd _), initrtp) =
            return ( Nothing, Nothing, (initrtp,initrtp,initrtp) )
        mkAllExistIdAndTypes _ ((p,UpperBd _), Array bt (Shape (d:dims)) u) = do
            idd1<- newIdent (textual (identName p)++"_outiv1") $ Basic Int
            idd2<- newIdent (textual (identName p)++"_outiv2") $ Basic Int
            let initrtp   = Array bt (Shape $ d:dims) u
                exacttype = Array bt (Shape $ Var (identName idd2):dims) u
            return ( Nothing
                   , Just (idd1,idd2,intconst 0)
                   , (initrtp,initrtp,exacttype) )
        mkAllExistIdAndTypes strmsz ((p,UnknownBd), Array bt (Shape (_:dims)) u) = do
            idd1 <- newIdent (textual (identName p)++"_outiv1") $ Basic Int
            idd2 <- newIdent (textual (identName p)++"_outiv2") $ Basic Int
            idal1<- newIdent (textual (identName p)++"_outsz1") $ Basic Int
            idal2<- newIdent (textual (identName p)++"_outsz2") $ Basic Int
            let lftedtype1= Array bt (Shape $ Var (identName idal1): dims) u
                lftedtype2= Array bt (Shape $ Var (identName idal2): dims) u
                exacttype = Array bt (Shape $ Var (identName idd2) : dims) u
            return ( Just (idal1,idal2,    strmsz)
                   , Just (idd1, idd2, intconst 0)
                   , (lftedtype1,lftedtype2,exacttype) )
        mkAllExistIdAndTypes _ _ =
            fail "FirstOrderTransform(Stream): failed in mkAllExistIdAndTypes"
        mkOutArrEpilogue :: Certificates -> SubExp
                         -> ( ( Maybe (Ident,Ident,SubExp)
                              , Maybe (Ident,Ident,SubExp) )
                            , Ident
                            , SubExp )
                         -> Binder Basic (Maybe Ident, Maybe Ident, Ident)
        mkOutArrEpilogue css iv ((allocvars,indvars),glboutid,locoutarr) = do
            locoutid <- case locoutarr of
                          Var idd -> return idd
                          _ -> fail ("FirstOrderTransform(Stream), mkOutArrEpilogue:"++
                                     " array result MUST be a Var!")
            locoutid_size <- arraySize 0 <$> lookupType locoutid
            (ivv, glboutid', mind', malloc') <-
                case indvars of
                  Nothing ->               -- exact-size case
                    return (iv, glboutid, Nothing, Nothing)
                  Just (k,_,_) -> do
                    newszid <- newIdent (textual (identName k)++"_new") $ Basic Int
                    plexp <- eBinOp Plus (pure $ PrimOp $ SubExp $ Var $ identName k)
                                         (pure $ PrimOp $ SubExp locoutid_size) Int
                    addBinding $ myMkLet plexp newszid
                    let oldbtp = identType glboutid
                    newallocid <- newIdent "newallocsz" $ Basic Int
                    resallocid <- newIdent "resallocsz" $ Basic Int
                    olddims <- case arrayDims oldbtp of
                                 (_:dims) -> return dims
                                 _ -> fail ("FirstOrderTransform(Stream), mkOutArrEpilogue:"++
                                            " empty array dimensions!")
                    case allocvars of
                      Nothing     ->       -- known-upper-bound case
                        return (Var $ identName k, glboutid, Just newszid, Nothing)
                      Just (alsz,_,_)-> do -- fully existential case, reallocate
                        alloclid <- newVName "allcloopiv"
                        let isempty = eBinOp Leq (pure $ PrimOp $ SubExp $ Var $ identName newszid)
                                             (pure $ PrimOp $ SubExp $ Var $ identName alsz) Bool
                            emptybranch = pure $ resultBody [Var $ identName glboutid]
                            otherbranch = runBinder $ do
                                alszt2exp<- eBinOp Times (pure $ PrimOp $ SubExp $ Var $ identName newszid)
                                                         (pure $ PrimOp $ SubExp $ intconst 2 ) Int
                                addBinding $ myMkLet alszt2exp newallocid
                                bnew0<- letExp (textual (identName glboutid)++"_loop0") $
                                               PrimOp $ Scratch (elemType oldbtp) (Var (identName newallocid):olddims)
                                bnew <- newIdent (textual (identName glboutid)++"_loop") =<<
                                        lookupType bnew0
                                allocloopbody <- runBinder $ do
                                    (aldest:_) <- letwith css [identName bnew] (pexp $ Var alloclid)
                                                  [PrimOp $ Index css (identName glboutid) [Var alloclid]]
                                    return $ resultBody [Var aldest]
                                let alloopres = LoopOp $ DoLoop [identName bnew]
                                                  (loopMerge [bnew] [Var bnew0])
                                                  (ForLoop alloclid (Var $ identName k)) allocloopbody
                                bnew' <- newIdent (textual (identName glboutid)++"_new0") =<<
                                         lookupType bnew0
                                addBinding $ myMkLet alloopres bnew'
                                return $ resultBody [Var $ identName bnew']
                        allocifexp <- eIf isempty emptybranch otherbranch
                        bnew'' <- newIdent (textual (identName glboutid)++"_res") $
                                           Array (elemType oldbtp)
                                           (Shape $ Var (identName resallocid):olddims) Unique
                        let patresbnd = mkLet ( map (\x->(x,BindVar)) [resallocid,bnew''] ) allocifexp
                        addBinding patresbnd
                        return (Var $ identName k, bnew'', Just newszid, Just resallocid)
            glboutLid <- newIdent (textual (identName glboutid)++"_loop") $ identType glboutid'
            glboutBdId<- newIdent (textual (identName glboutid)++"_loopbd") $ identType glboutid'
            loopid <- newVName "j"
            -- make copy-out what was written in the current iteration
            loopbody <- runBinder $ do
                ivvplid <- newIdent "jj" $ Basic Int
                ivvplidexp <- eBinOp Plus (pure $ PrimOp $ SubExp ivv)
                                          (pure $ PrimOp $ SubExp $ Var loopid) Int
                addBinding $ myMkLet ivvplidexp ivvplid
                (dest:_) <- letwith css [identName glboutLid] (pexp (Var $ identName ivvplid))--[indexp]
                                        [PrimOp $ Index css locoutid [Var loopid]]
                return $ resultBody [Var dest]
            -- make loop
            let loopres = LoopOp $ DoLoop [identName glboutLid]
                                    (loopMerge [glboutLid] [Var $ identName glboutid'])
                                    (ForLoop loopid (locoutid_size)) loopbody
            addBinding $ myMkLet loopres glboutBdId
            return (malloc', mind', glboutBdId)
transformStreamExp _ _ =
    fail "In transformStreamExp, UNREACHABLE: this function only supports stream!"

withUpperBound :: Bool
withUpperBound = False
data MEQType = ExactBd SubExp
             | UpperBd SubExp
             | UnknownBd
