-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.Util.Tree
-- Copyright   :  (c) Technische Universität Dresden 2014
-- License     :  BSD-style
--
-- Maintainer  :  Toni.Dietze@tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
--
-- Some useful functions for 'Tree's in addition to those from "Data.Tree".
--
-----------------------------------------------------------------------------

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module Vanda.Util.Tree
( -- * Two-dimensional drawing
  Drawstyle(..)
, drawstyleCompact1
, drawstyleCompact2
, drawTree'
, drawForest'
, -- * Image markup
  toTikZ
, -- * Extraction
  flattenRanked
, height
, annotateWithHeights
, subTrees
, yield
, filterTree
, -- * Manipulation
  defoliate
, -- * Map
  mapLeafs
, mapInners
, mapInnersAndLeafs
, mapWithSubtrees
, mapAccumLLeafs
, zipLeafsWith
, -- * newtype with Ord instance
  OrdTree(..)
) where


import Control.Arrow (second)
import Data.Coerce (coerce)
import Data.List (mapAccumL)
import Data.Tree


errorModule :: String -> a
errorModule = error . ("Vanda.Util.Tree." ++)


-- Two-dimensional drawing ---------------------------------------------------

-- | Defines how the branching structure of 'drawTree'' and 'drawForest''
-- looks like.
data Drawstyle = Drawstyle
  { br :: String  -- ^ branch at root
  , bi :: String  -- ^ branch at inner sibling
  , bl :: String  -- ^ branch at last sibling
  , lr :: String  -- ^ leaf at root
  , li :: String  -- ^ leaf at inner sibling
  , ll :: String  -- ^ leaf as last sibling
  , fi :: String  -- ^ filler for children of inner sibling
  , fl :: String  -- ^ filler for children of last sibling
  }


-- | Compact 'Drawstyle' similar to style of 'drawTree'.
drawstyleCompact1
  :: String     -- ^ separates the node label from the tree strtucture
  -> Drawstyle
drawstyleCompact1 sep = Drawstyle
  { br = ""
  , bi = "├" ++ sep
  , bl = "├" ++ sep
  , lr = ""
  , li = "└" ++ sep
  , ll = "└" ++ sep
  , fi = "│" ++ space
  , fl = " " ++ space
  }
  where space = ' ' <$ sep


-- | Compact 'Drawstyle' where the lines of the tree structure are completely
-- connected.
drawstyleCompact2
  :: Int        -- ^ width of the branches
  -> String     -- ^ separates the node label from the tree strtucture
  -> Drawstyle
drawstyleCompact2 width sep = Drawstyle
  { br = "┌" ++ sep
  , bi = "├" ++ line ++ "┬" ++ sep
  , bl = "├" ++ line ++ "─" ++ sep
  , lr = "╶" ++ sep
  , li = "└" ++ line ++ "┬" ++ sep
  , ll = "└" ++ line ++ "─" ++ sep
  , fi = "│" ++ space
  , fl = " " ++ space
  }
  where line  = replicate width '─'
        space = replicate width ' '



-- | Neat 2-dimensional drawing of a tree based on a 'Drawstyle'.
drawTree' :: Drawstyle -> Tree String -> String
drawTree'  = (unlines .) . draw

-- | Neat 2-dimensional drawing of a forest on a 'Drawstyle'.
drawForest' :: Drawstyle -> Forest String -> String
drawForest' drawstyle = unlines . map (drawTree' drawstyle)

draw :: Drawstyle -> Tree String -> [String]
draw Drawstyle{ .. } (Node root ts0)
  = ((if null ts0 then lr else br) ++ root) : drawSubTrees ts0
  where
    draw' (Node x ts) = x : drawSubTrees ts

    drawSubTrees []
      = []
    drawSubTrees [t]
      = shift (if null (subForest t) then ll else li) fl (draw' t)
    drawSubTrees (t : ts)
      = shift (if null (subForest t) then bl else bi) fi (draw' t)
      ++ drawSubTrees ts

    shift first other = zipWith (++) (first : repeat other)


-- Image markup --------------------------------------------------------------

-- | Prints TikZ-Code for the given 'Tree'
toTikZ
  :: [Char]  -- ^ left delimiter of the node label
  -> [Char]  -- ^ right delimiter of the node label
  -> [Char]  -- ^ the indentation character
  -> Tree [Char]
  -> [Char]
toTikZ = go 1 where
  go _ l r _   (Node lbl []) = "node {" ++ l ++ lbl ++ r ++ "}"
  go n l r tab (Node lbl ts) 
    = (++) ("node {" ++ l ++ lbl ++ r ++ "}")
    . concat
    $ map (\x -> "\n"
              ++ (concat $ replicate n tab)
              ++ "child {"
              ++ (go (n + 1) l r tab x)
              ++ (case x of
                    Node _ [] -> ""
                    _         -> "\n" ++ (concat $ replicate n tab)
                )
              ++ "}"
          ) ts


-- Extraction ----------------------------------------------------------------

-- | The elements of a 'Tree' and the 'length' of their 'subForest's,
-- respectively, in pre-order.
flattenRanked :: Tree a -> [(a, Int)]
flattenRanked t = go t []                       -- idea from Data.Tree.flatten
  where go (Node x ts) xs = (x, length ts) : foldr go xs ts


-- | The length of the longest path of a tree. @'Node' _ []@ has height @1@.
height :: Tree a -> Int
height (Node _ xs) = succ $ maximum $ 0 : map height xs


{-
-- | Replace the 'Node's’ 'rootLabel's of a 'Tree' by pairs of the 'height' of
-- the subtree at that 'Node' and the subtree itself.
annotateWithHeights :: Tree a -> Tree (Int, Tree a)
annotateWithHeights t@(Node _ ts)
  = Node (succ $ maximum $ 0 : map (fst . rootLabel) ts', t) ts'
  where ts' = map annotateWithHeights ts
-}


-- | Replace the 'Node's’ 'rootLabel's of a 'Tree' by pairs of the 'height' of
-- the subtree at that 'Node' and the original 'rootLabel'.
annotateWithHeights :: Tree a -> Tree (Int, a)
annotateWithHeights (Node x ts)
  = Node (succ $ maximum $ 0 : map (fst . rootLabel) ts', x) ts'
  where ts' = map annotateWithHeights ts


-- | List of all subtrees in pre-order.
subTrees :: Tree a -> Forest a
subTrees t0 = go t0 []                          -- idea from Data.Tree.flatten
  where go t@(Node _ ts) xs = t : foldr go xs ts


-- | List of leaves from left to right.
yield :: Tree a -> [a]
yield t = go t []                               -- idea from Data.Tree.flatten
  where go (Node x []) xs = x : xs
        go (Node _ ts) xs = foldr go xs ts


-- | Get those node labels in preorder where the predicate for the respective
-- subtree holds.
filterTree :: (Tree a -> Bool) -> Tree a -> [a]
filterTree p = flip go []                       -- idea from Data.Tree.flatten
  where go t@(Node x ts) xs = (if p t then (x :) else id) (foldr go xs ts)


-- Manipulation --------------------------------------------------------------

-- | Removes the leaves of a 'T.Tree'.
defoliate :: Tree a -> Tree a
defoliate (Node _ []) = errorModule "defoliate: Tree has only one leaf."
defoliate (Node x xs)
  = Node x $ map defoliate $ filter (not . null . subForest) xs


-- Map -----------------------------------------------------------------------

-- | Apply a function to all leaves.
mapLeafs :: (a -> a) -> Tree a -> Tree a
mapLeafs g = mapInnersAndLeafs id g


-- | Apply a function to all inner nodes, i.e. nodes which are not leaves.
mapInners :: (a -> a) -> Tree a -> Tree a
mapInners f = mapInnersAndLeafs f id


-- | Apply different functions to inner nodes and leaves.
mapInnersAndLeafs
  :: (a -> b)  -- ^ function applied to inner nodes
  -> (a -> b)  -- ^ function applied to leaves
  -> Tree a
  -> Tree b
mapInnersAndLeafs f g = go
  where go (Node x ts) = Node (if null ts then g x else f x) (map go ts)


-- | Like 'fmap', but the mapped function gets the whole subtrees.
mapWithSubtrees :: (Tree a -> b) -> Tree a -> Tree b
mapWithSubtrees f = go
  where go t@(Node _ ts) = Node (f t) (map go ts)


-- | Like 'mapAccumL', but on the leaves of a tree.
mapAccumLLeafs :: (a -> b -> (a, b)) -> a -> Tree b -> (a, Tree b)
mapAccumLLeafs f = go
  where
    go a (Node x []) = second (flip Node []) (f a x)
    go a (Node x ts) = second (Node x) (mapAccumL go a ts)


-- | Like 'zipWith', but on the leaves of a tree. If the list has less
-- elements than the tree has leaves, the last leaves stay unchanged. If the
-- list has more elements than the tree has leaves, the overhang of the list
-- is discarded.
zipLeafsWith :: (a -> b -> b) -> [a] -> Tree b -> Tree b
zipLeafsWith f = (snd .) . go
  where
    go [] t = ([], t)
    go (x : xs) (Node y []) = (xs, Node (f x y) [])
    go      xs  (Node y ts) = second (Node y) (mapAccumL go xs ts)


-- newtype with Ord instance -------------------------------------------------

-- | A wrapper for 'Tree' to add an 'Ord' instance.
newtype OrdTree a = OrdTree { unOrdTree :: Tree a }
  deriving (Applicative, Eq, Foldable, Functor, Monad, Read, Show)


instance forall a. Ord a => Ord (OrdTree a) where
  compare (OrdTree (Node x1 ts1)) (OrdTree (Node x2 ts2))
    = case compare x1 x2 of
        EQ -> compare (coerce ts1 :: [OrdTree a]) (coerce ts2 :: [OrdTree a])
        o  -> o
