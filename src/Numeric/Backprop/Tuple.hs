{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeInType            #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE ViewPatterns          #-}

-- |
-- Module      : Numeric.Backprop.Tuple
-- Copyright   : (c) Justin Le 2018
-- License     : BSD3
--
-- Maintainer  : justin@jle.im
-- Stability   : experimental
-- Portability : non-portable
--
-- Canonical strict tuples (and unit) with 'Num' instances for usage with
-- /backprop/. This is here to solve the problem of orphan instances in
-- libraries and potential mismatched tuple types.
--
-- If you are writing a library that needs to export 'BVar's of tuples,
-- consider using the tuples in this module so that your library can have
-- easy interoperability with other libraries using /backprop/.
--
-- Because of API decisions, 'backprop' and 'gradBP' only work with things
-- with 'Num' instances.  However, this disallows default 'Prelude' tuples
-- (without orphan instances from packages like
-- <https://hackage.haskell.org/package/NumInstances NumInstances>).
--
-- Until tuples have 'Num' instances in /base/, this module is intended to
-- be a workaround for situations where:
--
-- This comes up often in cases where:
--
--     (1) A function wants to return more than one value (@'BVar' s ('T2'
--     a b)@
--     (2) You want to uncurry a 'BVar' function to use with 'backprop' and
--     'gradBP'.
--     (3) You want to use the useful 'Prism's automatically generated by
--     the lens library, which use tuples for multiple-constructor fields.
--
-- Only 2-tuples and 3-tuples are provided.  Any more and you should
-- probably be using your own custom product types, with instances
-- automatically generated from something like
-- <https://hackage.haskell.org/package/one-liner-instances one-liner-instances>.
--
-- Lenses into the fields are provided, but they also work with '_1', '_2',
-- and '_3' from "Lens.Micro".  However, note that these are incompatible
-- with '_1', '_2', and '_3' from "Control.Lens".
--
-- You can "construct" a @'BVar' s ('T2' a b)@ with functions like
-- 'isoVar'.
--
-- @since 0.1.1.0
--


module Numeric.Backprop.Tuple (
  -- * Zero-tuples (unit)
    T0(..)
  -- * Two-tuples
  , T2(..)
  -- ** Conversions
  -- $t2iso
  , t2Tup, tupT2
  -- ** Consumption
  , uncurryT2, curryT2
  -- ** Lenses
  , t2_1, t2_2
  -- * Three-tuples
  , T3(..)
  -- ** Conversions
  -- $t3iso
  , t3Tup, tupT3
  -- ** Lenses
  , t3_1, t3_2, t3_3
  -- ** Consumption
  , uncurryT3, curryT3
  -- * N-Tuples
  , T(..)
  -- ** Conversions
  -- $tiso
  , tTup, tupT, tOnly, onlyT, tSplit, tAppend
  -- ** Lenses
  , tIx, tHead, tTail, tTake, tDrop
  -- ** Utility
  , constT, mapT, zipT
  ) where

import           Control.DeepSeq
import           Data.Bifunctor
import           Data.Data
import           Data.Kind
import           Data.Type.Index
import           Data.Type.Length
import           GHC.Generics               (Generic)
import           Lens.Micro
import           Lens.Micro.Internal hiding (Index)
import           Type.Class.Known
import           Type.Family.List

#if !MIN_VERSION_base(4,11,0)
import           Data.Semigroup
#endif

-- | Unit ('()') with 'Num', 'Fractional', and 'Floating' instances.
--
-- Be aware that the methods in its numerical instances are all non-strict:
--
-- @@
-- _ + _ = 'T0'
-- 'negate' _ = 'T0'
-- 'fromIntegral' _ = 'T0'
-- @@
--
-- @since 0.1.4.0
data T0 = T0
  deriving (Show, Read, Eq, Ord, Generic, Data)

instance NFData T0

-- | Strict 2-tuple with 'Num', 'Fractional', and 'Floating' instances.
--
-- @since 0.1.1.0
data T2 a b   = T2 !a !b
  deriving (Show, Read, Eq, Ord, Generic, Functor, Data)

-- | Strict 3-tuple with a 'Num', 'Fractional', and 'Floating' instances.
--
-- @since 0.1.1.0
data T3 a b c = T3 !a !b !c
  deriving (Show, Read, Eq, Ord, Generic, Functor, Data)

-- | Strict N-tuple with a 'Num', 'Fractional', and 'Floating' instances.
--
-- It is basically "yet another HList", like the one found in
-- "Data.Type.Product" and many other locations on the haskell ecosystem.
--
-- It is provided because of its 'Num' instance, making it useful for
-- /backproup/.  Will be obsolete when 'Data.Type.Product.Product' gets
-- numerical instances.
--
-- @since 0.1.5.0
data T :: [Type] -> Type where
    TNil :: T '[]
    (:&) :: !a -> !(T as) -> T (a ': as)

instance (NFData a, NFData b) => NFData (T2 a b)
instance (NFData a, NFData b, NFData c) => NFData (T3 a b c)
instance ListC (NFData <$> as) => NFData (T as) where
    rnf = \case
      TNil       -> ()
      (!_) :& xs -> rnf xs

instance Bifunctor T2 where
    bimap f g (T2 x y) = T2 (f x) (g y)

instance Bifunctor (T3 a) where
    bimap f g (T3 x y z) = T3 x (f y) (g z)

-- | Convert to a Haskell tuple.
--
-- Forms an isomorphism with 'tupT2'.
t2Tup :: T2 a b -> (a, b)
t2Tup (T2 x y) = (x, y)

-- | Convert from Haskell tuple.
--
-- Forms an isomorphism with 't2Tup'.
tupT2 :: (a, b) -> T2 a b
tupT2 (x, y) = T2 x y

-- | Convert to a Haskell tuple.
--
-- Forms an isomorphism with 'tupT3'.
t3Tup :: T3 a b c -> (a, b, c)
t3Tup (T3 x y z) = (x, y, z)

-- | Convert from Haskell tuple.
--
-- Forms an isomorphism with 't3Tup'.
tupT3 :: (a, b, c) -> T3 a b c
tupT3 (x, y, z) = T3 x y z

-- | Uncons a 'T'
--
-- Forms an isomorphism with 'tupT'
--
-- @since 0.1.5.0
tTup :: T (a ': as) -> (a, T as)
tTup (x :& xs) = (x, xs)

-- | Cons a 'T'
--
-- Forms an isomorphism with 'tTup'
--
-- @since 0.1.5.0
tupT :: (a, T as) -> T (a ': as)
tupT = uncurry (:&)

-- | A singleton 'T'
--
-- Forms an isomorphism with 'tOnly'
--
-- @since 0.1.5.0
onlyT :: a -> T '[a]
onlyT = (:& TNil)

-- | Extract a singleton 'T'
--
-- Forms an isomorphism with 'onlyT'
--
-- @since 0.1.5.0
tOnly :: T '[a] -> a
tOnly (x :& _) = x

-- | Uncurry a function to take in a 'T2' of its arguments
--
-- @since 0.1.2.0
uncurryT2 :: (a -> b -> c) -> T2 a b -> c
uncurryT2 f (T2 x y) = f x y

-- | Curry a function taking a 'T2' of its arguments
--
-- @since 0.1.2.0
curryT2 :: (T2 a b -> c) -> a -> b -> c
curryT2 f x y = f (T2 x y)

-- | Uncurry a function to take in a 'T3' of its arguments
--
-- @since 0.1.2.0
uncurryT3 :: (a -> b -> c -> d) -> T3 a b c -> d
uncurryT3 f (T3 x y z) = f x y z

-- | Curry a function taking a 'T3' of its arguments
--
-- @since 0.1.2.0
curryT3 :: (T3 a b c -> d) -> a -> b -> c -> d
curryT3 f x y z = f (T3 x y z)

instance Field1 (T2 a b) (T2 a' b) a a' where
    _1 = t2_1

instance Field2 (T2 a b) (T2 a b') b b' where
    _2 = t2_2

instance Field1 (T3 a b c) (T3 a' b c) a a' where
    _1 = t3_1

instance Field2 (T3 a b c) (T3 a b' c) b b' where
    _2 = t3_2

instance Field3 (T3 a b c) (T3 a b c') c c' where
    _3 = t3_3

-- | Lens into the first field of a 'T2'.  Also exported as '_1' from
-- "Lens.Micro".
t2_1 :: Lens (T2 a b) (T2 a' b) a a'
t2_1 f (T2 x y) = (`T2` y) <$> f x

-- | Lens into the second field of a 'T2'.  Also exported as '_2' from
-- "Lens.Micro".
t2_2 :: Lens (T2 a b) (T2 a b') b b'
t2_2 f (T2 x y) = T2 x <$> f y

-- | Lens into the first field of a 'T3'.  Also exported as '_1' from
-- "Lens.Micro".
t3_1 :: Lens (T3 a b c) (T3 a' b c) a a'
t3_1 f (T3 x y z) = (\x' -> T3 x' y z) <$> f x

-- | Lens into the second field of a 'T3'.  Also exported as '_2' from
-- "Lens.Micro".
t3_2 :: Lens (T3 a b c) (T3 a b' c) b b'
t3_2 f (T3 x y z) = (\y' -> T3 x y' z) <$> f y

-- | Lens into the third field of a 'T3'.  Also exported as '_3' from
-- "Lens.Micro".
t3_3 :: Lens (T3 a b c) (T3 a b c') c c'
t3_3 f (T3 x y z) = T3 x y <$> f z

-- | Lens into a given index of a 'T'.
--
-- @since 0.1.5.0
tIx :: forall as a. Index as a -> Lens' (T as) a
tIx IZ     f (x :& xs) = (:& xs) <$> f x
tIx (IS i) f (x :& xs) = (x :&)  <$> tIx i f xs

-- | Lens into the head of a 'T'
--
-- @since 0.1.5.0
tHead :: Lens (T (a ': as)) (T (b ': as)) a b
tHead f (x :& xs) = (:& xs) <$> f x

-- | Lens into the tail of a 'T'
--
-- @since 0.1.5.0
tTail :: Lens (T (a ': as)) (T (a ': bs)) (T as) (T bs)
tTail f (x :& xs) = (x :&) <$> f xs

-- | Append two 'T's.
--
-- Forms an isomorphism with 'tSplit'.
--
-- @since 0.1.5.0
tAppend :: T as -> T bs -> T (as ++ bs)
tAppend TNil      ys = ys
tAppend (x :& xs) ys = x :& tAppend xs ys
infixr 5 `tAppend`

-- | Split a 'T'.  For splits known at compile-time, you can use 'known' to
-- derive the 'Length' automatically.
--
-- Forms an isomorphism with 'tAppend'.
--
-- @since 0.1.5.0
tSplit :: Length as -> T (as ++ bs) -> (T as, T bs)
tSplit LZ     xs        = (TNil, xs)
tSplit (LS l) (x :& xs) = first (x :&) . tSplit l $ xs

-- | Lens into the initial portion of a 'T'.  For splits known at
-- compile-time, you can use 'known' to derive the 'Length' automatically.
tTake :: forall as bs cs. Length as -> Lens (T (as ++ bs)) (T (cs ++ bs)) (T as) (T cs)
tTake l f (tSplit l->(xs,ys)) = flip (tAppend @cs @bs) ys <$> f xs

-- | Lens into the ending portion of a 'T'.  For splits known at
-- compile-time, you can use 'known' to derive the 'Length' automatically.
tDrop :: forall as bs cs. Length as -> Lens (T (as ++ bs)) (T (as ++ cs)) (T bs) (T cs)
tDrop l f (tSplit l->(xs,ys)) = tAppend xs <$> f ys

instance Num T0 where
    _ + _         = T0
    _ - _         = T0
    _ * _         = T0
    negate _      = T0
    abs    _      = T0
    signum _      = T0
    fromInteger _ = T0

instance Fractional T0 where
    _ / _          = T0
    recip _        = T0
    fromRational _ = T0

instance Floating T0 where
    pi          = T0
    _ ** _      = T0
    logBase _ _ = T0
    exp   _     = T0
    log   _     = T0
    sqrt  _     = T0
    sin   _     = T0
    cos   _     = T0
    asin  _     = T0
    acos  _     = T0
    atan  _     = T0
    sinh  _     = T0
    cosh  _     = T0
    asinh _     = T0
    acosh _     = T0
    atanh _     = T0

instance Semigroup T0 where
    _ <> _ = T0

instance Monoid T0 where
    mempty = T0
    mappend = (<>)

instance (Num a, Num b) => Num (T2 a b) where
    T2 x1 y1 + T2 x2 y2 = T2 (x1 + x2) (y1 + y2)
    T2 x1 y1 - T2 x2 y2 = T2 (x1 - x2) (y1 - y2)
    T2 x1 y1 * T2 x2 y2 = T2 (x1 * x2) (y1 * y2)
    negate (T2 x y)     = T2 (negate x) (negate y)
    abs    (T2 x y)     = T2 (abs    x) (abs    y)
    signum (T2 x y)     = T2 (signum x) (signum y)
    fromInteger x       = T2 (fromInteger x) (fromInteger x)

instance (Fractional a, Fractional b) => Fractional (T2 a b) where
    T2 x1 y1 / T2 x2 y2 = T2 (x1 / x2) (y1 / y2)
    recip (T2 x y)      = T2 (recip x) (recip y)
    fromRational x      = T2 (fromRational x) (fromRational x)

instance (Floating a, Floating b) => Floating (T2 a b) where
    pi                            = T2 pi pi
    T2 x1 y1 ** T2 x2 y2          = T2 (x1 ** x2) (y1 ** y2)
    logBase (T2 x1 y1) (T2 x2 y2) = T2 (logBase x1 x2) (logBase y1 y2)
    exp   (T2 x y)                = T2 (exp   x) (exp   y)
    log   (T2 x y)                = T2 (log   x) (log   y)
    sqrt  (T2 x y)                = T2 (sqrt  x) (sqrt  y)
    sin   (T2 x y)                = T2 (sin   x) (sin   y)
    cos   (T2 x y)                = T2 (cos   x) (cos   y)
    asin  (T2 x y)                = T2 (asin  x) (asin  y)
    acos  (T2 x y)                = T2 (acos  x) (acos  y)
    atan  (T2 x y)                = T2 (atan  x) (atan  y)
    sinh  (T2 x y)                = T2 (sinh  x) (sinh  y)
    cosh  (T2 x y)                = T2 (cosh  x) (cosh  y)
    asinh (T2 x y)                = T2 (asinh x) (asinh y)
    acosh (T2 x y)                = T2 (acosh x) (acosh y)
    atanh (T2 x y)                = T2 (atanh x) (atanh y)

instance (Semigroup a, Semigroup b) => Semigroup (T2 a b) where
    T2 x1 y1 <> T2 x2 y2 = T2 (x1 <> x2) (y1 <> y2)

#if MIN_VERSION_base(4,11,0)
instance (Monoid a, Monoid b) => Monoid (T2 a b) where
#else
instance (Semigroup a, Semigroup b, Monoid a, Monoid b) => Monoid (T2 a b) where
#endif
    mappend = (<>)
    mempty  = T2 mempty mempty

instance (Num a, Num b, Num c) => Num (T3 a b c) where
    T3 x1 y1 z1 + T3 x2 y2 z2 = T3 (x1 + x2) (y1 + y2) (z1 + z2)
    T3 x1 y1 z1 - T3 x2 y2 z2 = T3 (x1 - x2) (y1 - y2) (z1 + z2)
    T3 x1 y1 z1 * T3 x2 y2 z2 = T3 (x1 * x2) (y1 * y2) (z1 + z2)
    negate (T3 x y z)         = T3 (negate x) (negate y) (negate z)
    abs    (T3 x y z)         = T3 (abs    x) (abs    y) (abs    z)
    signum (T3 x y z)         = T3 (signum x) (signum y) (signum z)
    fromInteger x             = T3 (fromInteger x) (fromInteger x) (fromInteger x)

instance (Fractional a, Fractional b, Fractional c) => Fractional (T3 a b c) where
    T3 x1 y1 z1 / T3 x2 y2 z2 = T3 (x1 / x2) (y1 / y2) (z1 / z2)
    recip (T3 x y z)          = T3 (recip x) (recip y) (recip z)
    fromRational x            = T3 (fromRational x) (fromRational x) (fromRational x)

instance (Floating a, Floating b, Floating c) => Floating (T3 a b c) where
    pi                                  = T3 pi pi pi
    T3 x1 y1 z1 ** T3 x2 y2 z2          = T3 (x1 ** x2) (y1 ** y2) (z1 ** z2)
    logBase (T3 x1 y1 z1) (T3 x2 y2 z2) = T3 (logBase x1 x2) (logBase y1 y2) (logBase z1 z2)
    exp   (T3 x y z)                    = T3 (exp   x) (exp   y) (exp   z)
    log   (T3 x y z)                    = T3 (log   x) (log   y) (log   z)
    sqrt  (T3 x y z)                    = T3 (sqrt  x) (sqrt  y) (sqrt  z)
    sin   (T3 x y z)                    = T3 (sin   x) (sin   y) (sin   z)
    cos   (T3 x y z)                    = T3 (cos   x) (cos   y) (cos   z)
    asin  (T3 x y z)                    = T3 (asin  x) (asin  y) (asin  z)
    acos  (T3 x y z)                    = T3 (acos  x) (acos  y) (acos  z)
    atan  (T3 x y z)                    = T3 (atan  x) (atan  y) (atan  z)
    sinh  (T3 x y z)                    = T3 (sinh  x) (sinh  y) (sinh  z)
    cosh  (T3 x y z)                    = T3 (cosh  x) (cosh  y) (cosh  z)
    asinh (T3 x y z)                    = T3 (asinh x) (asinh y) (asinh z)
    acosh (T3 x y z)                    = T3 (acosh x) (acosh y) (acosh z)
    atanh (T3 x y z)                    = T3 (atanh x) (atanh y) (atanh z)

instance (Semigroup a, Semigroup b, Semigroup c) => Semigroup (T3 a b c) where
    T3 x1 y1 z1 <> T3 x2 y2 z2 = T3 (x1 <> x2) (y1 <> y2) (z1 <> z2)

#if MIN_VERSION_base(4,11,0)
instance (Monoid a, Monoid b, Monoid c) => Monoid (T3 a b c) where
#else
instance (Semigroup a, Semigroup b, Semigroup c, Monoid a, Monoid b, Monoid c) => Monoid (T3 a b c) where
#endif
    mappend = (<>)
    mempty  = T3 mempty mempty mempty

-- | Initialize a 'T' with a Rank-N value.  Mostly used internally, but
-- provided in case useful.
--
-- Must be used with /TypeApplications/ to provide the Rank-N constraint.
--
-- @since 0.1.5.0
constT
    :: forall c as. ListC (c <$> as)
    => (forall a. c a => a)
    -> Length as
    -> T as
constT x = go
  where
    go :: forall bs. ListC (c <$> bs) => Length bs -> T bs
    go LZ     = TNil
    go (LS l) = x :& go l

-- | Map over a 'T' with a Rank-N function.  Mostly used internally, but
-- provided in case useful.
--
-- Must be used with /TypeApplications/ to provide the Rank-N constraint.
--
-- @since 0.1.5.0
mapT
    :: forall c as. ListC (c <$> as)
    => (forall a. c a => a -> a)
    -> T as
    -> T as
mapT f = go
  where
    go :: forall bs. ListC (c <$> bs) => T bs -> T bs
    go TNil      = TNil
    go (x :& xs) = f x :& go xs

-- | Map over a 'T' with a Rank-N function.  Mostly used internally, but
-- provided in case useful.
--
-- Must be used with /TypeApplications/ to provide the Rank-N constraint.
--
-- @since 0.1.5.0
zipT
    :: forall c as. ListC (c <$> as)
    => (forall a. c a => a -> a -> a)
    -> T as
    -> T as
    -> T as
zipT f = go
  where
    go :: forall bs. ListC (c <$> bs) => T bs -> T bs -> T bs
    go TNil      TNil      = TNil
    go (x :& xs) (y :& ys) = f x y :& go xs ys

instance (Known Length as, ListC (Num <$> as)) => Num (T as) where
    (+)           = zipT @Num (+)
    (-)           = zipT @Num (-)
    (*)           = zipT @Num (*)
    negate        = mapT @Num negate
    abs           = mapT @Num abs
    signum        = mapT @Num signum
    fromInteger x = constT @Num (fromInteger x) known

instance (Known Length as, ListC (Num <$> as), ListC (Fractional <$> as)) => Fractional (T as) where
    (/)            = zipT @Fractional (/)
    recip          = mapT @Fractional recip
    fromRational x = constT @Fractional (fromRational x) known

instance (Known Length as, ListC (Num <$> as), ListC (Fractional <$> as), ListC (Floating <$> as))
        => Floating (T as) where
    pi      = constT @Floating pi known
    (**)    = zipT @Floating (**)
    logBase = zipT @Floating logBase
    exp     = mapT @Floating exp
    log     = mapT @Floating log
    sqrt    = mapT @Floating sqrt
    sin     = mapT @Floating sin
    cos     = mapT @Floating cos
    asin    = mapT @Floating asin
    acos    = mapT @Floating acos
    atan    = mapT @Floating atan
    sinh    = mapT @Floating sinh
    cosh    = mapT @Floating cosh
    asinh   = mapT @Floating asinh
    acosh   = mapT @Floating acosh
    atanh   = mapT @Floating atanh

instance ListC (Semigroup <$> as) => Semigroup (T as) where
    (<>) = zipT @Semigroup (<>)

instance (Known Length as, ListC (Semigroup <$> as), ListC (Monoid <$> as)) => Monoid (T as) where
    mempty  = constT @Monoid mempty known
    mappend = (<>)

-- $t2iso
--
-- If using /lens/, the two conversion functions can be chained with prisms
-- and traversals and other optics using:
--
-- @
-- 'iso' 'tupT2' 't2Tup' :: 'Iso'' (a, b) ('T2' a b)
-- @

-- $t3iso
--
-- If using /lens/, the two conversion functions can be chained with prisms
-- and traversals and other optics using:
--
-- @
-- 'iso' 'tupT3' 't2Tup' :: 'Iso'' (a, b, c) ('T3' a b c)
-- @

-- $tiso
--
-- If using /lens/, the two conversion functions can be chained with prisms
-- and traversals and other optics using:
--
-- @
-- 'iso' 'tupT' 'tTup' :: 'Iso'' (a, T as) (T (a ': as))
-- @
--
-- @
-- 'iso' 'onlyT' 'tOnly' :: 'Iso'' a (T '[a])
-- @
