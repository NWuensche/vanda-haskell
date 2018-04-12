-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.GrammaticalInference.PDTA.Inference
-- Description :  grammatical inference of probabilistic deterministic tree
--                automata
-- Copyright   :  (c) Technische Universität Dresden 2016
-- License     :  BSD-style
--
-- Maintainer  :  Toni.Dietze@tu-dresden.de
-- Stability   :  experimental
-- Portability :  portable
--
-- This is a reimplementation of the algorithm presented in
-- “Stochastic Inference of Regular Tree Languages”
-- by Rafael C. Carrasco, Jose Oncina, and Jorge Calera.
-- There are two versions of this paper. Download them at:
--
-- * 2001: https://doi.org/10.1023/A:1010836331703
-- * 1998: https://doi.org/10.1007/BFb0054075
-----------------------------------------------------------------------------

{-# LANGUAGE BangPatterns, LambdaCase, ScopedTypeVariables #-}

module Vanda.GrammaticalInference.PDTA.Inference
(
-- * Functions from the Paper
  infer
, comp
, differ

-- * Auxiliary Functions
, dissectCorpus
, train
, parseEither
) where


import           Control.Arrow ((***))
import           Data.Coerce (coerce)
import           Data.IntMap (IntMap)
import qualified Data.IntMap.Lazy as IM
import qualified Data.IntMap.Strict as IMS
import           Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import           Data.List (foldl')
import           Data.Map (Map)
import qualified Data.Map.Lazy as M
import qualified Data.Map.Strict as MS
import           Data.Maybe (fromMaybe, isNothing)
-- import qualified Data.Set as S
import           Data.Tree
import           Data.Tuple (swap)
import           Data.Vector (Vector)
import qualified Data.Vector as V

import qualified Control.Error
import           Data.List.Extra (replaceOnce)
import           Vanda.Util.Tree (OrdTree(..), annotateWithHeights, subTrees)

import Debug.Trace


errorHere :: String -> String -> a
errorHere = Control.Error.errorHere "Vanda.GrammaticalInference.PDTA.Inference"


dissectCorpus
  :: forall f w a
  .  (Foldable f, Num w, Ord a)
  => f (Tree a, w)
  -> ( Vector (a, [Int])
     , Map (a, [Int]) Int
     , Vector w
     , Vector IntSet
     , Vector (Tree (Int, a)) )
dissectCorpus corpus
  = (packedForest, packedForestInv, treeIx2cnt, treeIx2parents, treeIx2tree)
  where
    -- packed forest
    packedForest :: Vector (a, [Int])
    packedForest
      = V.map (\ (Node (_, x) ts)
              -> (x, map (\ t -> fst $ tree2ixAndCnt M.! OrdTree t) ts) )
        treeIx2tree

    packedForestInv :: Map (a, [Int]) Int
    packedForestInv
      = M.fromListWith (errorHere "dissectCorpus.packedForestInv" "")
      $ V.toList
      $ V.map swap
      $ V.indexed packedForest

    -- Vector of counts
    treeIx2cnt :: Vector w
    treeIx2cnt
      = V.fromListN (M.size tree2ixAndCnt)
      $ map snd
      $ M.elems tree2ixAndCnt

    -- Vector of parent ids
    treeIx2parents :: Vector IntSet
    treeIx2parents
      = V.accum (flip IS.insert) (V.replicate (M.size tree2ixAndCnt) IS.empty)
      $ concatMap (\ (p, (_, cs)) -> map (flip (,) p) cs)
      $ V.toList
      $ V.indexed packedForest

    -- Vector of trees with annotated heights
    treeIx2tree :: Vector (Tree (Int, a))
    treeIx2tree
      = coerce
      $ V.fromListN (M.size tree2ixAndCnt)
      $ M.keys tree2ixAndCnt

    -- Map from tree with annotated heights to id and count
    -- TODO: Currently, we count every occurrence of a tree as a subtree.
    --       The pseudo-code counts a subtree only once per corpus tree.
    tree2ixAndCnt :: Map (OrdTree (Int, a)) (Int, w)
    tree2ixAndCnt
      = snd
      $ M.mapAccum (\ !a v -> (succ a, (a, v))) 0
      $ MS.fromListWith (+)
      $ coerce
      $ concatMap
          (\ (t, c) -> map (flip (,) c) $ subTrees $ annotateWithHeights t)
          corpus


train
  :: (Show σ, Foldable f, Ord σ, Fractional w)
  => Map (σ, [Int]) Int
  -> f (Tree σ, w)
  -> (Map Int w, IntMap (Map (σ, [Int]) w))
train transitions corpus
  = normalize *** fmap normalize
  $ foldl' stepCorpus (M.empty, IM.empty) corpus
  where
    stepCorpus (!rootW, !transW) (t, c)
      = ( MS.insertWith (+) (snd $ rootLabel t') c rootW
        , foldl' stepParsesubtree transW $ subTrees t'
        )
      where t' = parse transitions t
            stepParsesubtree m (Node (σ, q) ts)
              = IMS.insertWith
                  (MS.unionWith (+))
                  q
                  (MS.singleton (σ, map (snd . rootLabel) ts) c)
                  m


normalize :: (Foldable f, Functor f, Fractional a) => f a -> f a
normalize x = fmap (/ foldl' (+) 0 x) x
  -- we divide because
  -- > recip 0.09 * 0.09 = 0.9999999999999999


parse :: (Show σ, Show q, Ord σ, Ord q) => Map (σ, [q]) q -> Tree σ -> Tree (σ, q)
parse transitions = go
  where
    go (Node x ts) = Node (x, let key = (x, map (snd . rootLabel) ts') in fromMaybe (errorHere "parse" ("unknown transition: " ++ show key)) $ M.lookup key transitions)
                          ts'
         where ts' = map go ts


parseEither :: (Show σ, Show q, Ord σ, Ord q) => Map (σ, [q]) q -> Tree σ -> Either (σ, [q]) (Tree (σ, q))
parseEither transitions = go
  where
    go (Node x ts) = do
      ts' <- traverse go ts
      let key = (x, map (snd . rootLabel) ts')
      case M.lookup key transitions of
        Just q  -> return $ Node (x, q) ts'
        Nothing -> Left   $ key


infer
  :: ( Show w
     , Ord a, Foldable f, Floating w, Ord w)
  => w -> f (Tree a, w) -> (IntSet, Map (a, [Int]) Int, IntSet)
infer α corpus
  = go IS.empty M.empty IS.empty {-IS.empty-}
  $ IS.fromList
  $ V.toList
  $ V.map fst
  $ V.indexed
  $ V.takeWhile (\ case Node _ [] -> True; _ -> False) treeV
  where
    (packedV, packedM, cntV, parentsV, treeV) = dissectCorpus corpus

    getParents = IS.toList . (parentsV V.!)

    getChildren = snd . (packedV V.!)

    equiv = comp α getParents (packedV V.!) (`M.lookup` packedM) (cntV V.!)

    go ssub δ f {-seen-} w
      = case IS.minView w of
          Nothing -> (ssub, δ, f)
          Just (x, w') -> trace ("minimum⋅⋅: " ++ show x {-++ " = " ++ tree2term (fmap snd $ treeV V.! x)-}) $
            case filter (\ y -> trace (" equiv⋅⋅⋅: " ++ show x ++ " vs " ++ show y) $ equiv x y) (IS.toList ssub) of
              y : ys -> trace (" compatible with " ++ show x ++ " ≡ " ++ show y ++ if null ys then "" else "; other compatible: " ++ show ys)
                      $ go ssub
                          (M.insertWith err (packedV V.! x) y δ)
                          (IS.insert x f)
--                           seen'
                          w'
--                       $ IS.union w'
--                       $ IS.fromList
--                       $ filter (all (`IS.member` seen') . getChildren)
--                       $ getParents x
                where {-seen' = IS.insert x seen-}
                      err = errorHere "infer.go.branch 1"
                                      "would overwrite existing transition"
              [] -> trace (" no compatible for " ++ show x)
                  $ go ssub' (M.insertWith err (packedV V.! x) x δ) f {-seen'-}
                  $ IS.union w'
                  $ IS.fromList
                  $ filter (all (`IS.member` ssub') . getChildren)
                  $ getParents x
                where ssub' = IS.insert x ssub
                      {-seen' = IS.insert x seen-}
                      err = errorHere "infer.go.branch 2"
                                      "would overwrite existing transition"


comp
  :: forall a i t
   . ( Show a, Show i
     , Floating a, Ord a, Ord i, Traversable t)
  => a                   -- α
  -> (i -> [i])          -- tree ↦ trees containing tree as direct subtree
  -> (i -> t [i])        -- tree ↦ its root node containing subtrees
  -> (t [i] -> Maybe i)  -- node containing subtrees ↦ tree, if exists
  -> (i -> a)            -- tree ↦ count
  -> i                   -- tree 1
  -> i                   -- tree 2
  -> Bool                -- 'True' iff tree 1 and 2 are compatible
comp α getParents getTrans applyTrans getCnt = (not .) . incomp
  where
    incomp :: i -> i -> Bool
    incomp x y
      =  or [ trc (Just tx) mty
            $ case mty of
                Nothing -> differ2 (getCnt tx) 0
                Just ty -> differ2 (getCnt tx) (getCnt ty) || incomp tx ty
            | tx <- getParents x
            , mty <- map applyTrans
                   $ traverse (replaceOnce x y)
                   $ getTrans tx
            ]
      || or [ trc Nothing (Just ty)
            $ differ2 0 (getCnt ty)
            | ty <- getParents y
            , any isNothing
              $ map applyTrans
              $ traverse (replaceOnce y x)
              $ getTrans ty
            ]
      where
        trc :: Maybe i -> Maybe i -> b -> b
        trc mtx mty
          = trace
          $  "  incomp⋅: " ++ maybe "—" show mtx ++ " & " ++ show x
          ++        " vs " ++ maybe "—" show mty ++ " & " ++ show y

        differ2 = differ1 (getCnt x) (getCnt y)

    differ1 = differ α


differ :: (Show a, Floating a, Ord a) => a -> a -> a -> a -> a -> Bool
differ α     = let x = log (2 / α) / 2
  in \ m m' -> let r = sqrt (x / m) + sqrt (x / m')
  in \ f f' -> let l = abs (f / m - f' / m')
                   b = l > r
                in trace ("   differ: " ++ show f ++ " / " ++ show m ++ " − " ++ show f' ++ " / " ++ show m'
                     ++ "\n         ⇝ " ++ show b ++ " = " ++ show l ++ " > " ++ show r) b


------------------------------------------------------------------------------

{-
-- | This only considers trees with non-zero counts
-- comp
--   :: (Traversable t, Ord a, Floating a, Eq i)
--   => a
--   -> (i -> [i])
--   -> (i -> t [i])
--   -> (t [i] -> Maybe i)
--   -> (i -> a)
--   -> i
--   -> i
--   -> Bool
comp α getParents getTrans applyTrans getCnt = \ x y ->
    not $ or
    [ trace ("   comp: " ++ show tzx ++ " / " ++ show zx ++ " vs " ++ show tzy ++ " / " ++ show zy)
    $ differ2 (getCnt tzx) (getCnt tzy)
    | let gMA = getMutualAncestors getParents getTrans applyTrans
    , let differ1 = differ α
    , (zx, zy) <- gMA x y
    , let differ2 = differ1 (getCnt zx) (getCnt zy)
    , (tzx, tzy) <- gMA zx zy
    -- TODO: t must have depth 1 on the spine
    ]
-}
{-
getMutualAncestors
  :: (Traversable t, Eq a)
  => (a -> [a]) -> (a -> t [a]) -> (t [a] -> Maybe a) -> a -> a -> [(a, a)]
getMutualAncestors getParents getTrans applyTrans = go
  where go x y
          = (x, y)
          : concat
            [ go zx zy
            | zx <- getParents x
            , Just zy <- map applyTrans
                      $ traverse (replaceOnce x y)
                      $ getTrans zx
              -- TODO: also allow unseen (sub)trees?
            ]
-}

{-
-- | This one should work, but can be optimized.
comp
  :: forall a i t
   . (Traversable t, Ord a, Floating a, Ord i, Show a, Show i)
  => a
  -> (i -> [i])
  -> (i -> t [i])
  -> (t [i] -> Maybe i)
  -> (i -> a)
  -> i
  -> i
  -> Bool
comp α getParents getTrans applyTrans getCnt = (not .) . incomp
  where
    incomp :: i -> i -> Bool
    incomp x y = goxy S.empty (gMP x y)
      where goxy :: S.Set (i, i) -> [(i, Maybe i)] -> Bool
            goxy s ((tx, Nothing) : zs) = trace ("  comp⋅⋅⋅: " ++ show tx ++ " / " ++ show x ++ " vs — / " ++ show y) $ differ2 (getCnt tx) 0 || goxy s zs
            goxy s ((tx, Just ty) : zs) = goxy (S.insert (tx, ty) s) zs
            goxy s []                   = goyx s (gMP y x)

            goyx :: S.Set (i, i) -> [(i, Maybe i)] -> Bool
            goyx s ((ty, Nothing) : zs) = trace ("  comp⋅⋅⋅: — / " ++ show x ++ " vs " ++ show ty ++ " / " ++ show y) $ differ2 0 (getCnt ty) || goyx s zs
            goyx s ((ty, Just tx) : zs) = goyx (S.insert (tx, ty) s) zs
            goyx s []
              = any (\ (tx, ty) -> trace ("  comp⋅⋅⋅: " ++ show tx ++ " / " ++ show x ++ " vs " ++ show ty ++ " / " ++ show y)
                                 $ differ2 (getCnt tx) (getCnt ty) || incomp tx ty)
              $ S.toList s

            differ2 = differ1 (getCnt x) (getCnt y)

    differ1 = differ α

    gMP :: i -> i -> [(i, Maybe i)]
    gMP = getMutualParents getParents getTrans applyTrans


getMutualParents
  :: (Traversable t, Eq a)
  => (a -> [b]) -> (b -> t [a]) -> (t [a] -> Maybe c) -> a -> a -> [(b, Maybe c)]
getMutualParents getParents getTrans applyTrans = \ x y
  -> [ (tx, mty)
     | tx <- getParents x
     , mty <- map applyTrans
                $ traverse (replaceOnce x y)
                $ getTrans tx
      -- TODO: also allow unseen (sub)trees?
     ]
-}

{-
-- Here the complexity explodes.
-- comp
--   :: (Traversable t, Ord a, Floating a, Eq i)
--   => a
--   -> (i -> [i])
--   -> (i -> t [i])
--   -> (t [i] -> Maybe i)
--   -> (i -> a)
--   -> i
--   -> i
--   -> Bool
comp α getParents getTrans applyTrans getCnt = (not .) . incomp'
  where
    incomp' x y = incomp x y || incomp y x
    incomp x y = or
      [ trace ("  comp⋅⋅⋅: " ++ show tx ++ " / " ++ show x ++ " vs " ++ show mty ++ " / " ++ show y)
      $ case mty of
          Just ty -> differ2 (getCnt tx) (getCnt ty) || incomp' tx ty  -- TODO: the prime makes it loop endlessly – why?
          Nothing -> True
      | let differ2 = differ1 (getCnt x) (getCnt y)
      , tx <- getParents x
      , mty <- map applyTrans
                 $ traverse (replaceOnce x y)
                 $ getTrans tx
      -- TODO: also allow unseen (sub)trees?
      ]
    differ1 = differ α
    -- gMP = getMutualParents getParents getTrans applyTrans
-}

{-
-- | This is just wrong, because we do not ensure same contexts.
comp :: (Floating a, Ord a) => a -> (i -> [i]) -> (i -> a) -> i -> i -> Bool
comp α getAncestors getCnt x y
  = not $ or
    [ {-trace "hui" $-} differ2 (getCnt tzx) (getCnt tzy)
    | let differ1 = differ α
    , zx <- getAncestors x
    , zy <- getAncestors y
    , let differ2 = differ1 (getCnt zx) (getCnt zy)
    , tzx <- getAncestors zx
    , tzy <- getAncestors zy
    ]
-}
