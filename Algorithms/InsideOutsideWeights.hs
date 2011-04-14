-- | Computation of inside and outside weights for 'Hypergraph's.
--
-- The weights are computed by a fixpoint approximation.
-- Alternative approaches for future implementations could be Newton's method
-- or hill climbing.
module Algorithms.InsideOutsideWeights (
-- * Inside and outside weights
  insideOutside, insideOutside'
, inside, inside'
, outside, outside'
-- * Fixpoint convergence
, Converging(..)
, convergedRatio
) where


import Data.Hypergraph

import qualified Data.Map  as M

-- import Debug.Trace


-- | Computes the inside and outside weights for a given 'Hypergraph'.
insideOutside
  :: (Ord v, Converging w, Num w)
  => (Hyperedge v l w' i -> w)
                -- ^ this function is used do get the weight of an 'Hyperedge'
  -> v          -- ^ target node
  -> Hypergraph v l w' i
  -> M.Map v (w, w)        -- ^ maps a vertex to its inside and outside weight
insideOutside w v g = insideOutside' converged w v g


-- | The same as 'insideOutside', but a property to check if the fixpoint
-- iteration can be finished using two consecutive values in the fixpoint
-- iteration must be given.
insideOutside'
  :: (Ord v, Num w)
  => (w -> w -> Bool)
  -> (Hyperedge v l w' i -> w)
  -> v
  -> Hypergraph v l w' i
  -> M.Map v (w, w)
insideOutside' c w target g
  = let mIn = inside' c w g
    in M.unionWith
      (\ (i, _) (_, o) -> (i, o))
      (M.map (\ i -> (i, 0)) mIn)
      (M.map (\ o -> (0, o)) (outside' c w mIn target g))


-- Inside Weights ------------------------------------------------------------

-- | Computes the inside weights for a given 'Hypergraph'.
inside
  :: (Ord v, Converging w, Num w)
  => (Hyperedge v l w' i -> w) -> Hypergraph v l w' i -> M.Map v w
inside w g = inside' converged w g


-- | The same as 'inside', but a property to check if the fixpoint
-- iteration can be finished using two consecutive values in the fixpoint
-- iteration must be given.
inside'
  :: (Ord v, Num w)
  => (w -> w -> Bool)
  -> (Hyperedge v l w' i -> w)
  -> Hypergraph v l w' i
  -> M.Map v w
inside' c w g
  = M.map fst $ go $ M.map ((,) 0) $ edgesM g
  where
    go m
      = {-trace "Ding!" $-}
        let m' = insideStep w m
        in if checkMapsOn fst c m m'
        then m'
        else go m'


-- | Do one iteration step for the fixpoint computation of the inside weights.
insideStep
  :: (Num w, Ord v)
  => (Hyperedge v l w' i -> w)
  -> M.Map v (w, [Hyperedge v l w' i])
  -> M.Map v (w, [Hyperedge v l w' i])
insideStep w m = M.map (\ (_, es) -> (insideHead w m es, es)) m


insideHead
  :: (Num w, Ord v)
  => (Hyperedge v l w' i -> w) -> M.Map v (w, a) -> [Hyperedge v l w' i] -> w
insideHead w m es
  = sum [ w e * insideTail m (eTail e) | e <- es ]
  -- = let step s e = s + w e * insideTail m (eTail e)
  --   in L.foldl' step 0 es


insideTail :: (Num w, Ord v) => M.Map v (w, a) -> [v] -> w
insideTail m vs
  = product [ maybe 0 fst (M.lookup v m) | v <- vs ]
  -- = let step p v = p * maybe 0 fst (M.lookup v m)
  --   in L.foldl' step 1 vs


-- Outside Weights -----------------------------------------------------------

-- | Computes the outside weights of a given 'Hypergraph'.
outside
  :: (Ord v, Converging w, Num w)
  => (Hyperedge v l w' i -> w)
  -> M.Map v w         -- ^ inside weights
  -> v                 -- ^ target node
  -> Hypergraph v l w' i
  -> M.Map v w
outside w g = outside' converged w g


-- | The same as 'outside', but a property to check if the fixpoint
-- iteration can be finished using two consecutive values in the fixpoint
-- iteration must be given.
outside'
  :: (Ord v, Num w)
  => (w -> w -> Bool)
  -> (Hyperedge v l w' i -> w)
  -> M.Map v w
  -> v
  -> Hypergraph v l w' i
  -> M.Map v w
outside' c w m target g
  = M.map fst $ go $ initOutsideMap w m target g
  where
    go m'
      = {-trace "Dong!" $-}
        let m'' = outsideStep m'
        in if checkMapsOn fst c m' m''
        then m''
        else go m''


-- | Do one iteration step for the fixpoint computation of the outside
-- weights.
outsideStep
  :: (Num w, Ord v)
  => M.Map v (w, [(v, w)])
  -> M.Map v (w, [(v, w)])
outsideStep m
  = M.map
      (\ (_, xs) ->
        ( sum [ maybe 0 fst (M.lookup v m) * w | (v, w) <- xs ]
          -- L.foldl' (\ s (v, w) -> s + maybe 0 fst (M.lookup v m) * w) 0 xs
        , xs)
      )
      m


-- | Initialize the data structure used for computing the outside weights.
--
-- > outer(A)
-- >   = sum_{B, v, w} outer(B) *            p(B -> vAw) * innerList(v ++ w)
-- >   = sum_{B}       outer(B) * sum_{v, w} p(B -> vAw) * innerList(v ++ w)
-- >                 -- constant: ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
-- >   where
-- >     innerList w = prod_{1 <= i <= |w|} inner(w_i)
--
-- The constant part is precomuted for every combination of @A@ and @B@.
initOutsideMap ::
  (Num w, Ord v)
  => (Hyperedge v l w' i -> w)
  -> M.Map v w              -- ^ inside weights
  -> v                      -- ^ target node
  -> Hypergraph v l w' i
  -> M.Map v (w, [(v, w)])
initOutsideMap w m target
  = M.insert target (1, [(target, 1)])
  . M.map ((,) 0 . M.toList . M.fromListWith (+))
  . M.fromListWith (++)
  . concatMap
      (\ e ->
        let hd = eHead e
            tl = eTail e
            ws = map (\ v -> M.findWithDefault 0 v m) tl
            ls = scanl (*) 1 ws
            rs = scanr (*) 1 ws
            ew = w e
        in zipWith3 (\ v l r -> (v, [(hd, ew * l * r)])) tl ls (tail rs)
      )
  . edges

-- Convergence ---------------------------------------------------------------

-- | Check a property for a component of all elements of two maps with the
-- same keys, respectively.
-- /Both maps must contain exactly the same keys for this function to work!/
checkMapsOn
  :: (a -> b)          -- ^ maps an element to the relevant component
  -> (b -> b -> Bool)  -- ^ property
  -> M.Map k1 a
  -> M.Map k2 a
  -> Bool
checkMapsOn f c m1 m2
  = go (M.elems m1) (M.elems m2)
  where
    go (x:xs) (y:ys) = c (f x) (f y) && go xs ys
    go []     []     = True
    go _      _
      = error "Algorithms.InsideOutsideWeights.checkMapsOn: Malformed maps."


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
