-- (c) 2011 Toni Dietze <Toni.Dietze@tu-dresden.de>
--
-- Technische Universität Dresden / Faculty of Computer Science / Institute
-- of Theoretical Computer Science / Chair of Foundations of Programming
--
-- Redistribution and use in source and binary forms, with or without
-- modification, is ONLY permitted for teaching purposes at Technische
-- Universität Dresden AND IN COORDINATION with the Chair of Foundations
-- of Programming.
-- ---------------------------------------------------------------------------

-- | Computation of inside and outside weights for 'Hypergraph's.
--
-- The weights are computed by a fixpoint approximation.
-- Alternative approaches for future implementations could be Newton's method
-- or hill climbing.
module Vanda.Algorithms.InsideOutsideWeights (
-- * Inside and outside weights
  insideOutside, insideOutside'
, inside, inside'
, outside, outside'
-- * Fixpoint convergence
, Converging(..)
, convergedRatio
, viterbiInsideOutside
) where


import Vanda.Hypergraph

import Control.Arrow hiding ((<+>))
import Data.Weight (Inside(Inside), unpack)
import Data.Semiring
import qualified Data.Map as M
import qualified Data.Set as S


-- | Computes the inside and outside weights for a given 'Hypergraph'.
insideOutside
  :: (Ord v, Converging w, Num w, Hypergraph h)
  => (Hyperedge v l i -> w)
                -- ^ this function is used do get the weight of an 'Hyperedge'
  -> v          -- ^ target node
  -> h v l i
  -> M.Map v (w, w)        -- ^ maps a vertex to its inside and outside weight
insideOutside w v h = M.map (unpack *** unpack) $ insideOutside' converged (Inside . w) v h


-- | The same as 'insideOutside', but a property to check if the fixpoint
-- iteration can be finished using two consecutive values in the fixpoint
-- iteration must be given.
insideOutside'
  :: (Ord v, Semiring w, Hypergraph h)
  => (w -> w -> Bool)
  -> (Hyperedge v l i -> w)
  -> v
  -> h v l i
  -> M.Map v (w, w)
insideOutside' c w target g
  = let mIn = inside' c g w
    in M.unionWith
      (\ (i, _) (_, o) -> (i, o))
      (M.map (\ i -> (i, zero)) mIn)
      (M.map (\ o -> (zero, o)) (outside' c w mIn target g))


-- Inside Weights ------------------------------------------------------------

-- | Computes the inside weights for a given 'Hypergraph'.
inside
  :: (Ord v, Converging w, Num w, Hypergraph h)
  => (Hyperedge v l i -> w) -> h v l i -> M.Map v w
inside w g = M.map unpack $ inside' converged g (Inside . w)


-- | The same as 'inside', but a property to check if the fixpoint
-- iteration can be finished using two consecutive values in the fixpoint
-- iteration must be given.
inside'
  :: (Ord v, Semiring w, Hypergraph h)
  => (w -> w -> Bool)
  -> h v l i
  -> (Hyperedge v l i -> w)
  -> M.Map v w
inside' c g w
  = go $ M.fromList [ (v, zero) | v <- S.toList $ nodes g ]
  where
    b = toBackwardStar g
    go m
      | checkMaps c m m' = m'
      | otherwise = go m'
      where
        m' = insideStep b w m


-- | Do one iteration step for the fixpoint computation of the inside weights.
insideStep
  :: (Semiring w, Ord v)
  => BackwardStar v l i
  -> (Hyperedge v l i -> w)
  -> M.Map v w
  -> M.Map v w
insideStep g w m
  = M.fromList
      [ (v, ins)
      | v <- S.toList $ nodes g
      , let ins = inH (backStar g v) zero
      , ins `seq` True
      ]
  where
    inH (e : es) s = s `seq` inH es (s <+> w e <.> inT (from e) one)
    inH []       s = s
    inT (v : vs) p = p `seq` inT vs (p <.> M.findWithDefault zero v m)
    inT []       p = p


-- Outside Weights -----------------------------------------------------------

-- | Computes the outside weights of a given 'Hypergraph'.
outside
  :: (Ord v, Converging w, Num w, Hypergraph h)
  => (Hyperedge v l i -> w)
  -> M.Map v w         -- ^ inside weights
  -> v                 -- ^ target node
  -> h v l i
  -> M.Map v w
outside w m v h = M.map unpack $ outside' converged (Inside . w) (M.map Inside m) v h


-- | The same as 'outside', but a property to check if the fixpoint
-- iteration can be finished using two consecutive values in the fixpoint
-- iteration must be given.
outside'
  :: (Ord v, Semiring w, Hypergraph h)
  => (w -> w -> Bool)
  -> (Hyperedge v l i -> w)
  -> M.Map v w
  -> v
  -> h v l i
  -> M.Map v w
outside' c w inm target g
  = go initial -- (M.singleton target 1)
  where
    initial
      = M.fromList
      $ (target, one) : [ (v, zero) | v <- S.toList (nodes g), v /= target ]
    aux = initOutsideAux w inm g
    go m'
      = {-trace "Dong!" $-}
        let m'' = outsideStep target aux m'
        in if checkMaps c m' m''
        then m''
        else go m''


-- | Do one iteration step for the fixpoint computation of the outside
-- weights.
outsideStep
  :: (Semiring w, Ord v)
  => v
  -> [(v, [(v, w)])]
  -> M.Map v w
  -> M.Map v w
outsideStep target aux m
  = M.insertWith (<+>) target one
  $ M.fromList [ (v, f lst zero) | (v, lst) <- aux ]
  where
    f ((v, w) : xs) s = s `seq` f xs (s <+> M.findWithDefault zero v m <.> w)
    f [] s = s


-- | Initialize the data structure used for computing the outside weights.
--
-- > outer(A)
-- >   = sum_{B, v, w} outer(B) *            p(B -> vAw) * innerList(v ++ w)
-- >   = sum_{B}       outer(B) * sum_{v, w} p(B -> vAw) * innerList(v ++ w)
-- >                 -- constant: ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
-- >   where
-- >     innerList w = prod_{1 <= i <= |w|} inner(w_i)
--
-- The constant part is precomputed for every combination of @A@ and @B@.
initOutsideAux
  :: (Semiring w, Ord v, Hypergraph h)
  => (Hyperedge v l i -> w)
  -> M.Map v w              -- ^ inside weights
  -> h v l i
  -> [(v, [(v, w)])]
initOutsideAux w m
  = M.toList
  . M.map (M.toList . M.fromListWith (<+>))
  . M.fromListWith (++)
  . concatMap
      (\ e ->
        let hd = to e
            tl = from e
            ws = map (\ v -> M.findWithDefault zero v m) tl
            ls = scanl (<.>) one ws
            rs = scanr (<.>) one ws
            ew = w e
        in zipWith3 (\ v l r -> (v, [(hd, ew <.> l <.> r)])) tl ls (tail rs)
      )
  . edges

-- Convergence ---------------------------------------------------------------

-- | Check a property for a component of all elements of two maps with the
-- same keys, respectively.
-- /Both maps must contain exactly the same keys for this function to work!/
checkMaps
  :: Ord k
  => (b -> b -> Bool)  -- ^ property
  -> M.Map k b
  -> M.Map k b
  -> Bool
checkMaps c m1 m2
  = and
  $ M.elems
  $ M.intersectionWith c m1 m2
  {-
  = and
  $ M.elems
  $ M.mergeWithKey
    (\ k x1 x2 -> Just $ c x1 x2) (const M.Tip) (const M.Tip) m1 m2
  -}

-- | The property @convergedRatio epsilon x y@ holds, iff the ratio between
-- @x@ and @y@ differs at most @epsilon@ from @1@.
convergedRatio :: (Ord a, Num a) => a -> a -> a -> Bool
convergedRatio epsilon x y
  = let (mi, ma) = if x < y then (x, y) else (y, x)
    in ma - mi <= ma * epsilon


-- | @True@, iff both arguments are equal or both are @NaN@.
convergedRealFloat :: (RealFloat a) => a -> a -> Bool
convergedRealFloat x y = x == y || (isNaN x && isNaN y)

{-
convergedRealFloat x y
  = let (mi, ma) = if x < y then (x, y) else (y, x)
    in (uncurry encodeFloat $ mapFst (1 +) $ decodeFloat mi) >= ma


convergedRealFloat
  = convergedRatio (encodeFloat 1 (negate (floatDigits undefined) + 1))
-}

-- | The class contains types whose elements can converge against a fixpoint
-- of a function.
class Converging a where
  -- | The property @converged x y@ holds, iff @x@ and @y@ are values of
  -- consecutive steps in a fixpoint iteration and @x@ and @y@ are close
  -- enough such that another iteration step would probably not improve
  -- the result significantly.
  converged :: a -> a -> Bool

instance Converging Float where
  converged = convergedRealFloat

instance Converging Double where
  converged = convergedRealFloat

instance (Converging a) =>  Converging (Inside a) where
  (Inside x) `converged` (Inside y) = x `converged` y

-- | This wrapper should allow us to use the same fixpoint computation
-- we used to compute inside/outside sums in order to calculate
-- Viterbi scores.
newtype Viterbi a = Viterbi { unViterbi :: a } deriving (Eq, Ord, Show)

instance (Ord a, Num a) => Num (Viterbi a) where
  a + b       = Viterbi (unViterbi a `max` unViterbi b)
  (-)         = undefined
  a * b       = Viterbi (unViterbi a * unViterbi b)
  abs         = Viterbi . abs . unViterbi
  fromInteger = Viterbi . fromInteger
  signum      = Viterbi . signum . unViterbi

instance Converging a => Converging (Viterbi a) where
  a `converged` b = unViterbi a `converged` unViterbi b

viterbiInsideOutside
  :: (Ord v, Converging w, Ord w, Num w, Hypergraph h)
  => (Hyperedge v l i -> w)
                -- ^ this function is used do get the weight of an 'Hyperedge'
  -> v          -- ^ target node
  -> h v l i
  -> M.Map v (w, w)        -- ^ maps a vertex to its inside and outside weight
viterbiInsideOutside f n g
  = M.map (unViterbi *** unViterbi) $ insideOutside (Viterbi . f) n g
