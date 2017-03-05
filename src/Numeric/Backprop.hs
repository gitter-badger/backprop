{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeInType          #-}
{-# LANGUAGE TypeOperators       #-}

module Numeric.Backprop (
  -- * Types
    BP, BPOp, BPRef
  , Op(..)
  , Summer(..)
  , Unity(..)
  -- * BP
  -- ** Backprop
  , backprop, evalBPOp, gradBPOp
  , backprop', evalBPOp', gradBPOp'
  -- ** Inputs
  , withInps
  , plugBP, (~$), ($~)
  , withInps'
  , plugBP'
  -- * Refs
  , constRef
  , inpRef, inpRefs
  , bindRef
  , inpRefs'
  , bindRef'
  -- ** From Ops
  , opRef, (-$)
  , opRef1, opRef2, opRef3
  , opRef'
  , opRef1', opRef2', opRef3'
  -- ** Ref manipulation
  -- *** As parts
  , partsRef, (#<~), withParts
  , splitRefs, gSplit
  , partsRef', withParts'
  , splitRefs', gSplit'
  -- *** As sums
  , choicesRef
  , choicesRef'
  -- *** As sums of products
  , sopRef, gSplits
  , sopRef', gSplits'
  -- ** Transforming BP
  , internally
  , generically
  , internally'
  , generically'
  -- ** Combining
  , liftR, liftR1, liftR2, liftR3
  -- * Op
  , op1, op2, op3, opN
  , op1', op2', op3', opN'
  -- * Utility
  , summers, unities
  , Prod(..), pattern (:>), only
  , Tuple, pattern (::<), only_
  ) where

import           Control.Monad.Base
import           Control.Monad.Reader
import           Control.Monad.ST
import           Control.Monad.State
import           Data.Maybe
import           Data.Monoid               ((<>))
import           Data.STRef
import           Data.Type.Combinator
import           Data.Type.Conjunction
import           Data.Type.Index
import           Data.Type.Length
import           Data.Type.Product
import           Data.Type.Sum hiding      (index)
import           Data.Type.Util
import           Lens.Micro hiding         (ix)
import           Lens.Micro.Mtl
import           Numeric.Backprop.Internal
import           Numeric.Backprop.Iso
import           Numeric.Backprop.Op
import           Type.Class.Higher
import           Type.Class.Known
import           Type.Class.Witness
import qualified Generics.SOP              as SOP

type BPOp s rs a = BP s rs (BPRef s rs a)

opRef'
    :: forall s rs as a. ()
    => Summer a
    -> Prod (BPRef s rs) as
    -> Op as a
    -> BP s rs (BPRef s rs a)
opRef' s i o = do
    xs <- traverse1 (fmap I . BP . resolveRef) i
    let (res, gf) = runOp' o xs
        bp = BPN { _bpnOut       = only $ FRInternal []
                 , _bpnRes       = only_ res
                 , _bpnGradFunc  = return . gf . head'
                 , _bpnGradCache = Nothing
                 , _bpnSummer    = only s
                 }
    r <- BP . liftBase $ newSTRef bp
    itraverse1_ (registerRef . flip IRNode r) i
    return (BPRNode IZ r)

splitRefs'
    :: forall s rs as. ()
    => Prod Summer as
    -> Prod Unity as
    -> BPRef s rs (Tuple as)
    -> BP s rs (Prod (BPRef s rs) as)
splitRefs' ss us = partsRef' ss us id

splitRefs
    :: forall s rs as. (Every Num as, Known Length as)
    => BPRef s rs (Tuple as)
    -> BP s rs (Prod (BPRef s rs) as)
splitRefs = partsRef id

partsRef'
    :: forall s rs bs b. ()
    => Prod Summer bs
    -> Prod Unity bs
    -> Iso' b (Tuple bs)
    -> BPRef s rs b
    -> BP s rs (Prod (BPRef s rs) bs)
partsRef' ss us i =
    fmap (view sum1) . sopRef' (only ss) (only us) (i . resum1)

partsRef
    :: forall s rs bs b. (Every Num bs, Known Length bs)
    => Iso' b (Tuple bs)
    -> BPRef s rs b
    -> BP s rs (Prod (BPRef s rs) bs)
partsRef = partsRef' summers unities

infixr 1 #<~
(#<~)
    :: (Every Num bs, Known Length bs)
    => Iso' b (Tuple bs)
    -> BPRef s rs b
    -> BP s rs (Prod (BPRef s rs) bs)
(#<~) = partsRef

withParts'
    :: Prod Summer bs
    -> Prod Unity bs
    -> Iso' b (Tuple bs)
    -> BPRef s rs b
    -> (Prod (BPRef s rs) bs -> BP s rs a)
    -> BP s rs a
withParts' ss us i r f = do
    p <- partsRef' ss us i r
    f p

withParts
    :: (Every Num bs, Known Length bs)
    => Iso' b (Tuple bs)
    -> BPRef s rs b
    -> (Prod (BPRef s rs) bs -> BP s rs a)
    -> BP s rs a
withParts i r f = do
    p <- partsRef i r
    f p

gSplit'
    :: (SOP.Generic b, SOP.Code b ~ '[bs])
    => Prod Summer bs
    -> Prod Unity bs
    -> BPRef s rs b
    -> BP s rs (Prod (BPRef s rs) bs)
gSplit' ss us = partsRef' ss us gTuple

gSplit
    :: (Every Num bs, Known Length bs, SOP.Generic b, SOP.Code b ~ '[bs])
    => BPRef s rs b
    -> BP s rs (Prod (BPRef s rs) bs)
gSplit = gSplit' summers unities

internally'
    :: forall s rs bs b a. ()
    => Prod Summer bs
    -> Prod Unity bs
    -> Summer a
    -> Iso' b (Tuple bs)
    -> BPRef s rs b
    -> BP s bs (BPRef s bs a)
    -> BP s rs (BPRef s rs a)
internally' ss us sa l r bp = do
    xs <- view l <$> BP (resolveRef r)
    (res, gFunc) <- BP . liftBase $ backpropWith ss us bp xs
    let bpn :: BPNode s rs '[ b ] '[ a ]
        bpn = BPN { _bpnOut       = only $ FRInternal []
                  , _bpnRes       = only_ res
                  , _bpnGradFunc  = fmap (only_ . review l) . gFunc . head'
                  , _bpnGradCache = Nothing
                  , _bpnSummer    = only sa
                  }
    r' <- BP . liftBase $ newSTRef bpn
    registerRef (IRNode IZ r') r
    return (BPRNode IZ r')

internally
    :: forall s rs bs b a. (Every Num bs, Known Length bs, Num a)
    => Iso' b (Tuple bs)
    -> BPRef s rs b
    -> BP s bs (BPRef s bs a)
    -> BP s rs (BPRef s rs a)
internally = internally' summers unities known

generically'
    :: forall s rs bs b a. (SOP.Generic b, SOP.Code b ~ '[bs])
    => Prod Summer bs
    -> Prod Unity bs
    -> Summer a
    -> BPRef s rs b
    -> BP s bs (BPRef s bs a)
    -> BP s rs (BPRef s rs a)
generically' ss us sa = internally' ss us sa gTuple

generically
    :: forall s rs bs b a. (Num a, Every Num bs, Known Length bs, SOP.Generic b, SOP.Code b ~ '[bs])
    => BPRef s rs b
    -> BP s bs (BPRef s bs a)
    -> BP s rs (BPRef s rs a)
generically = internally gTuple

choicesRef'
    :: forall s rs bs b. ()
    => Prod Summer bs
    -> Prod Unity bs
    -> Iso' b (Sum I bs)
    -> BPRef s rs b
    -> BP s rs (Sum (BPRef s rs) bs)
choicesRef' ss us i r = do
    x <- BP $ resolveRef r
    let xs :: Sum I bs
        xs = view i x
    ifor1 ((ss `zipP` us) `tagSum` xs) $ \ix ((s :&: u) :&: I (y :: c)) -> do
      let bp :: BPNode s rs '[b] '[c]
          bp = BPN { _bpnOut       = only $ FRInternal []
                   , _bpnRes       = only_ y
                   , _bpnGradFunc  = return . only_ . review i
                                   . injectSum ix
                                   . maybe (I (getUnity u)) I
                                   . head'
                   , _bpnGradCache = Nothing
                   , _bpnSummer    = only s
                   }
      r' <- BP . liftBase $ newSTRef bp
      registerRef (IRNode IZ r') r
      return $ BPRNode IZ r'
-- TODO: cannot implement via sopRef?  oh well.

choicesRef
    :: forall s rs bs b. (Every Num bs, Known Length bs)
    => Iso' b (Sum I bs)
    -> BPRef s rs b
    -> BP s rs (Sum (BPRef s rs) bs)
choicesRef = choicesRef' summers unities

sopRef'
    :: forall s rs bss b. ()
    => Prod (Prod Summer) bss
    -> Prod (Prod Unity) bss
    -> Iso' b (Sum Tuple bss)
    -> BPRef s rs b
    -> BP s rs (Sum (Prod (BPRef s rs)) bss)
sopRef' sss uss i r = do
    x <- BP $ resolveRef r
    let xs :: Sum Tuple bss
        xs = view i x
    ifor1 ((sss `zipP` uss) `tagSum` xs) $ \ix ((ss :&: us) :&: (ys :: Tuple bs)) -> do
      let bp :: BPNode s rs '[b] bs
          bp = BPN { _bpnOut       = map1 (const (FRInternal [])) ys
                   , _bpnRes       = ys
                   , _bpnGradFunc  = return . only_
                                   . review i . injectSum ix
                                   . map1 (uncurryFan $ \u ->
                                             maybe (I (getUnity u)) I
                                          )
                                   . zipP us
                   , _bpnGradCache = Nothing
                   , _bpnSummer    = ss
                   }
      r' <- BP . liftBase $ newSTRef bp
      registerRef (IRNode IZ r') r
      return $ imap1 (\ix' _ -> BPRNode ix' r') ys

sopRef
    :: forall s rs bss b. (Known Length bss, Every (Every Num ∧ Known Length) bss)
    => Iso' b (Sum Tuple bss)
    -> BPRef s rs b
    -> BP s rs (Sum (Prod (BPRef s rs)) bss)
sopRef = sopRef' (withEvery @(Every Num ∧ Known Length) summers)
                 (withEvery @(Every Num ∧ Known Length) unities)

gSplits'
    :: forall s rs b. SOP.Generic b
    => Prod (Prod Summer) (SOP.Code b)
    -> Prod (Prod Unity) (SOP.Code b)
    -> BPRef s rs b
    -> BP s rs (Sum (Prod (BPRef s rs)) (SOP.Code b))
gSplits' sss uss = sopRef' sss uss gSOP

gSplits
    :: forall s rs b.
      ( SOP.Generic b
      , Known Length (SOP.Code b)
      , Every (Every Num ∧ Known Length) (SOP.Code b)
      )
    => BPRef s rs b
    -> BP s rs (Sum (Prod (BPRef s rs)) (SOP.Code b))
gSplits = sopRef gSOP


-- TODO: pull summers too
resolveRef
    :: (MonadReader (Tuple rs) m, MonadBase (ST s) m)
    => BPRef s rs a
    -> m a
resolveRef = \case
    BPRNode  ix r -> getI . index ix . _bpnRes <$> liftBase (readSTRef r)
    BPRInp   ix   -> getI . index ix <$> ask
    BPRConst    x -> return x
    BPROp    rs o -> do
      xs <- traverse1 (fmap I . resolveRef) rs
      return $ runOp o xs

registerRef
    :: forall s rs a. ()
    => BPInpRef s rs a
    -> BPRef s rs a
    -> BP s rs ()
registerRef bpir = \case
    BPRNode  ix' r' -> BP . liftBase . modifySTRef r' $
                         over (bpnOut . indexP ix' . _FRInternal) (bpir :)
    BPRInp   ix'    -> BP $ modifying (bpsSources . indexP ix' . _FRInternal) (bpir :)
    BPRConst _      -> return ()
    -- This independently makes a new BPPipe for every usage site of the
    -- BPROp, so it's a bit inefficient.
    BPROp    (rs :: Prod (BPRef s rs) ds) (o :: Op ds a) -> do
      xs :: Tuple ds <- traverse1 (fmap I . BP . resolveRef) rs
      let res :: a
          gF :: Maybe a -> Tuple ds
          (res, gF) = runOp' o xs
          bpp :: BPPipe s rs ds '[a]
          bpp = BPP { _bppOut       = only bpir
                    , _bppRes       = only_ res
                    , _bppGradFunc  = gF . Just . getI . head'
                    , _bppGradCache = Nothing
                    }
      r' <- BP . liftBase $ newSTRef bpp
      ifor1_ rs $ \ix' (bpr :: BPRef s rs d) ->
        registerRef (IRPipe ix' r') bpr

opRef
    :: Num a
    => Prod (BPRef s rs) as
    -> Op as a
    -> BP s rs (BPRef s rs a)
opRef = opRef' known

infixr 1 -$
(-$)
    :: Num a
    => Op as a
    -> Prod (BPRef s rs) as
    -> BP s rs (BPRef s rs a)
(-$) = flip opRef

constRef :: a -> BPRef s rs a
constRef = BPRConst

opRef1'
    :: Summer b
    -> BPRef s rs a
    -> Op '[a] b
    -> BP s rs (BPRef s rs b)
opRef1' s r = opRef' s (r :< Ø)

opRef1
    :: Num b
    => BPRef s rs a
    -> Op '[a] b
    -> BP s rs (BPRef s rs b)
opRef1 = opRef1' known

opRef2'
    :: Summer c
    -> BPRef s rs a
    -> BPRef s rs b
    -> Op '[a,b] c
    -> BP s rs (BPRef s rs c)
opRef2' s rx ry = opRef' s (rx :< ry :< Ø)

opRef2
    :: Num c
    => BPRef s rs a
    -> BPRef s rs b
    -> Op '[a,b] c
    -> BP s rs (BPRef s rs c)
opRef2 = opRef2' known

opRef3'
    :: Summer d
    -> BPRef s rs a
    -> BPRef s rs b
    -> BPRef s rs c
    -> Op '[a,b,c] d
    -> BP s rs (BPRef s rs d)
opRef3' s rx ry rz = opRef' s (rx :< ry :< rz :< Ø)

opRef3
    :: Num d
    => BPRef s rs a
    -> BPRef s rs b
    -> BPRef s rs c
    -> Op '[a,b,c] d
    -> BP s rs (BPRef s rs d)
opRef3 = opRef3' known

-- can be recursive too?  would have to have resolveRef also pull summers
bindRef'
    :: Summer a
    -> BPRef s rs a
    -> BP s rs (BPRef s rs a)
bindRef' s r = case r of
    BPRNode  _  _ -> return r
    BPRInp   _    -> return r
    BPRConst _    -> return r
    BPROp    rs o -> opRef' s rs o

bindRef
    :: Num a
    => BPRef s rs a
    -> BP s rs (BPRef s rs a)
bindRef = bindRef' known



backwardPass
    :: forall s rs a. ()
    => BPInpRef s rs a
    -> ST s a
backwardPass = \case
    IRNode  ix r' -> getI . index ix <$> pullNode r'
    IRPipe  ix r' -> getI . index ix <$> pullPipe r'
    IRConst g     -> return g
  where
    pullNode
        :: forall as bs. ()
        => STRef s (BPNode s rs as bs)
        -> ST s (Tuple as)
    pullNode r = caching bpnGradCache r $ \BPN{..} -> do
        totdervs <- for1 (_bpnSummer `zipP` _bpnOut) $ \case
          s :&: FRInternal rs -> Just . runSummer s
              <$> traverse backwardPass rs
          _ :&: FRTerminal g   -> return g
        g <- _bpnGradFunc totdervs
        return g
    pullPipe
        :: forall as bs. ()
        => STRef s (BPPipe s rs as bs)
        -> ST s (Tuple as)
    pullPipe r = caching bppGradCache r $ \BPP{..} ->
        _bppGradFunc <$> traverse1 (fmap I . backwardPass) _bppOut

backprop'
    :: Prod Summer rs
    -> Prod Unity rs
    -> (forall s. BPOp s rs a)
    -> Tuple rs
    -> (a, Tuple rs)
backprop' ss us bp env = runST $ do
    (res, gFunc) <- backpropWith ss us bp env
    grad <- gFunc Nothing
    return (res, grad)

backprop
    :: forall rs a. Every Num rs
    => (forall s. BPOp s rs a)
    -> Tuple rs
    -> (a, Tuple rs)
backprop bp xs = backprop' (summers' l) (unities' l) bp xs
  where
    l :: Length rs
    l = prodLength xs

evalBPOp'
    :: Prod Summer rs
    -> Prod Unity rs
    -> (forall s. BPOp s rs a)
    -> Tuple rs
    -> a
evalBPOp' ss us bp = fst . backprop' ss us bp

evalBPOp
    :: Every Num rs
    => (forall s. BPOp s rs a)
    -> Tuple rs
    -> a
evalBPOp bp = fst . backprop bp

gradBPOp'
    :: Prod Summer rs
    -> Prod Unity rs
    -> (forall s. BPOp s rs a)
    -> Tuple rs
    -> Tuple rs
gradBPOp' ss us bp = snd . backprop' ss us bp

gradBPOp
    :: Every Num rs
    => (forall s. BPOp s rs a)
    -> Tuple rs
    -> Tuple rs
gradBPOp bp = snd . backprop bp


closeOff
    :: (MonadReader (Tuple rs) m, MonadState (BPState s rs) m, MonadBase (ST s) m)
    => Bool
    -> Maybe a
    -> BPRef s rs a
    -> m ()
closeOff isTerminal gOut = \case
    BPRNode  ix sr -> liftBase $ modifySTRef sr (over (bpnOut . indexP ix) (<> fr))
    BPRInp   ix'   -> modifying (bpsSources . indexP ix') (<> fr)
    BPRConst _     -> return ()
    BPROp    rs o  -> do
      xs <- traverse1 (fmap I . resolveRef) rs
      let gs = gradOpWith' o xs gOut
      for1_ (gs `zipP` rs) $ \(I g :&: r) ->
        closeOff False (Just g) r
  where
    fr | isTerminal = FRTerminal gOut
       | otherwise  = FRInternal (IRConst <$> maybeToList gOut)

backpropWith
    :: Prod Summer rs
    -> Prod Unity rs
    -> BPOp s rs a
    -> Tuple rs
    -> ST s (a, Maybe a -> ST s (Tuple rs))
backpropWith ss us bp env = do
    (r, bps0) <- runStateT (runReaderT (bpST bp) env)
                           (BPS (map1 (\_ -> FRInternal []) env))
    res <- runReaderT (resolveRef r) env
    let gradFunc gradOut = do
          BPS{..} <- execStateT (runReaderT (closeOff True gradOut r) env) bps0
          for1 (ss `zipP` us `zipP` _bpsSources) $ \((s :&: u) :&: rs) -> do
            I <$> case rs of
              FRInternal rs' -> runSummer s <$> traverse backwardPass rs'
              FRTerminal g   -> return $ fromMaybe (getUnity u) g
    return (res, gradFunc)

plugBP'
    :: Prod (BPRef s rs) as
    -> Prod Summer as
    -> Prod Unity as
    -> Summer a
    -> BPOp s as a
    -> BPOp s rs a
plugBP' i ss us sa bp = do
    env <- traverse1 (fmap I . BP . resolveRef) i
    (res, gFunc) <- BP . liftBase $ backpropWith ss us bp env
    let bpn = BPN { _bpnOut       = FRInternal [] :< Ø
                  , _bpnRes       = only_ res
                  , _bpnGradFunc  = gFunc . head'
                  , _bpnGradCache = Nothing
                  , _bpnSummer    = sa :< Ø
                  }
    r <- BP . liftBase $ newSTRef bpn
    itraverse1_ (registerRef . flip IRNode r) i
    return (BPRNode IZ r)

plugBP
    :: forall s rs as a. (Every Num as, Num a)
    => Prod (BPRef s rs) as
    -> BPOp s as a
    -> BPOp s rs a
plugBP i = plugBP' i (imap1 (\j _ -> known \\ every @_ @Num j) i)
                     (imap1 (\j _ -> known \\ every @_ @Num j) i)
                     known

infixr 1 ~$
(~$)
    :: (Every Num as, Num a)
    => BPOp s as a
    -> Prod (BPRef s rs) as
    -> BPOp s rs a
(~$) = flip plugBP

infixr 1 $~
($~)
    :: (Every Num as, Num a)
    => Prod (BPRef s rs) as
    -> (Prod (BPRef s as) as -> BPOp s as a)
    -> BPOp s rs a
x $~ f = plugBP x (withInps' (prodLength x) f)


inpRef
    :: Index rs a
    -> BPRef s rs a
inpRef = BPRInp

inpRefs
    :: Known Length rs
    => Prod (BPRef s rs) rs
inpRefs = inpRefs' known

inpRefs'
    :: Length rs
    -> Prod (BPRef s rs) rs
inpRefs' = map1 inpRef . indices'

withInps'
    :: Length rs
    -> (Prod (BPRef s rs) rs -> BP s rs a)
    -> BP s rs a
withInps' l f = f (inpRefs' l)

withInps
    :: Known Length rs
    => (Prod (BPRef s rs) rs -> BP s rs a)
    -> BP s rs a
withInps = withInps' known

liftR
    :: Op as a
    -> Prod (BPRef s rs) as
    -> BPRef s rs a
liftR = flip BPROp

liftR1
    :: Op '[a] b
    -> BPRef s rs a
    -> BPRef s rs b
liftR1 o = liftR o . only

liftR2
    :: Op '[a,b] c
    -> BPRef s rs a
    -> BPRef s rs b
    -> BPRef s rs c
liftR2 o x y = liftR o (x :< y :< Ø)

liftR3
    :: Op '[a,b,c] d
    -> BPRef s rs a
    -> BPRef s rs b
    -> BPRef s rs c
    -> BPRef s rs d
liftR3 o x y z = liftR o (x :< y :< z :< Ø)











-- | Apply a function to the contents of an STRef, and cache the results
-- using the given lens.  If already calculated, simply returned the cached
-- result.
caching
    :: Lens' a (Maybe b)
    -> STRef s a
    -> (a -> ST s b)
    -> ST s b
caching l r f = do
    x <- readSTRef r
    let y = view l x
    case y of
      Just z ->
        return z
      Nothing -> do
        z <- f x
        modifySTRef r (set l (Just z))
        return z
