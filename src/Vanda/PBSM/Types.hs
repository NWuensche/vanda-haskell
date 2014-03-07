-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.PBSM.Types
-- Copyright   :  (c) Technische Universität Dresden 2014
-- License     :  Redistribution and use in source and binary forms, with
--                or without modification, is ONLY permitted for teaching
--                purposes at Technische Universität Dresden AND IN
--                COORDINATION with the Chair of Foundations of Programming.
--
-- Maintainer  :  Toni.Dietze@tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

module Vanda.PBSM.Types where


import Vanda.Hypergraph
import qualified Data.Queue as Q

import Control.DeepSeq (NFData (), rnf)
import Control.Monad.State
import Control.Seq
import Data.Function (on)
import Data.List
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Tree


type SForest a = S.Set (Tree a)
type NT = SForest String
type T = String

data RTG n t = RTG
  { initialS :: S.Set n
  , ruleM    :: M.Map (t, Int) (M.Map n (S.Set [n]))
  } deriving Show


instance (NFData n, NFData t) => NFData (RTG n t) where
  rnf (RTG nS rM) = rnf nS `seq` rnf rM

seqRTG
  :: Strategy (S.Set n)
  -> Strategy (M.Map (t, Int) (M.Map n (S.Set [n])))
  -> Strategy (RTG n t)
seqRTG strat1 strat2 (RTG iniS rM) = strat1 iniS `seq` strat2 rM


rtg :: (Ord n, Ord t) => [n] -> [Rule n t] -> RTG n t
rtg inis
  = RTG (S.fromList inis)
  . M.fromListWith (M.unionWith S.union)
  . map (\ (Rule n t ns) -> ((t, length ns), M.singleton n (S.singleton ns)))


initials :: RTG n t -> [n]
initials = S.toList . initialS


rules :: RTG n t -> [Rule n t]
rules g
  = [ Rule n t ns
    | ((t, _), m) <- M.toList (ruleM g)
    , (n, nsS) <- M.toList m
    , ns <- S.toList nsS
    ]


ruleS :: (Ord n, Ord t) => RTG n t -> S.Set (Rule n t)
ruleS g
  = S.unions
      [ S.mapMonotonic (Rule n t) nsS
      | ((t, _), m) <- M.toList (ruleM g)
      , (n, nsS) <- M.toList m
      ]


data Rule n t
  = Rule { lhs :: n, lab :: t, succs :: [n] }
  deriving (Eq, Ord, Show)


instance (NFData n, NFData t) => NFData (Rule n t) where
  rnf (Rule n t ns) = rnf n `seq` rnf t `seq` rnf ns


instance Ord a => Ord (Tree a) where
  compare (Node x1 ts1) (Node x2 ts2)
    = case compare x1 x2 of
        EQ -> compare ts1 ts2
        o -> o


nonterminalS :: Ord n => RTG n t -> S.Set n
nonterminalS g
  = S.fromList $ do
      M.elems (ruleM g)
      >>= M.toList
      >>= (\ (n, nsS) -> n : concat (S.toList nsS))


mapNonterminals :: (Ord m, Ord n, Ord t) => (m -> n) -> RTG m t -> RTG n t
mapNonterminals f (RTG inS rM)
  = RTG (S.map f inS)
  $ M.map (M.mapKeysWith S.union f . M.map (S.map (map f))) rM


mapNonterminals' :: (Ord m, Ord n, Ord t) => (m -> n) -> RTG m t -> RTG n t
mapNonterminals' f g
  = mapNonterminals f g
  `using`
    seqRTG
      (seqFoldable rseq)
      (seqMap r0 (seqMap rseq (seqFoldable (seqList rseq))))


intifyNonterminals :: (Ord n, Ord t) => RTG n t -> RTG Int t
intifyNonterminals g
  = mapNonterminals intify g
  where
    intify n = M.findWithDefault
      (errorModule "intifyNonterminals: This must not happen.")
      n
      mapping
    mapping = M.fromList $ flip zip [1 ..] $ S.toList $ nonterminalS g


toHypergraph :: (Enum i, Num i, Ord v, Hypergraph h) => RTG v l -> h v l i
toHypergraph g
  = mkHypergraph $ zipWith toHyperedge [0 ..] $ rules g
  where
    toHyperedge i (Rule v l vs) = mkHyperedge v vs l i


language :: Ord n => RTG n t -> [Tree t]
language g@(RTG nS _)
  = concat
  $ transpose
  $ map (\ n -> M.findWithDefault [] n (languages g)) (S.toList nS)


languages :: Ord n => RTG n t -> M.Map n [Tree t]
languages g = langM
  where
    langM = M.map (concat . transpose . map apply) ruleM'
    apply (Rule _ l ns)
      = map (Node l)
      $ combinations
      $ map (\ n -> M.findWithDefault [] n langM) ns
    ruleM'
      = M.map (sortBy (compare `on` length . succs))
      $ M.fromListWith (++) [(lhs r, [r]) | r <- rules g]


combinations :: [[a]] -> [[a]]
combinations yss
  = if any null yss then [] else evalState go $ Q.singleton (id, yss)
  where
    go = untilState Q.null $ do
            (prefix, xss) <- state Q.deq
            fillQueue prefix xss
            return $ prefix $ map head xss

    fillQueue _ [] = return ()
    fillQueue prefix ((x : xs) : xss) = do
      unless (null xs) $ modify $ Q.enq (prefix, xs : xss)
      fillQueue (prefix . (x :)) xss
    fillQueue _ _ = errorModule "combinations: This must not happen."

    untilState predicate action = do
      x <- get
      if predicate x
        then return []
        else do
          y  <- action
          ys <- untilState predicate action
          return (y : ys)


yield :: Tree a -> [a]
yield (Node x []) = [x]
yield (Node _ xs) = concatMap yield xs


errorModule :: String -> a
errorModule = error . ("Vanda.PBSM.Types." ++)