-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.PBSM.Main
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

module Vanda.PBSM.Main where


import Vanda.Hypergraph (label)
import Vanda.Hypergraph.DotExport
import Vanda.Corpus.Penn.Simple
import Vanda.Corpus.TreeTerm
import Vanda.PBSM.PatternBasedStateMerging
import Vanda.PBSM.PrettyPrint
import Vanda.PBSM.Types

import Control.Applicative ((<$>))
import Control.Arrow
import Data.List
import qualified Data.Set as S
import qualified Data.Tree as T
import Text.Parsec.String (parseFromFile)

import Debug.Trace

test
  = putStrLn $ drawRTG $ generalize S.unions g d
  where
    g = forestToGrammar [parseTree "g(g(a))"]
    d = [parseTree "g(g(g(g(g(g(a))))))"{-, parseTree "g(g(g(g(a))))"-}]


g'
  = generalize S.unions g d
  where
    g = forestToGrammar [parseTree "g(g(a))"]
    d = [{-parseTree "g(g(g(g(g(g(a))))))",-} parseTree "g(g(g(g(a))))"]

{-
test2
  = putStrLn $ unlines $ map drawDerivation $ deriveTree g t (head $ initials g)
--   = {-putStrLn $ unlines $ map drawDerivation $ -}holeDerivs
  where
    g = g'
    t = parseTree "g(g(g(g(g(g(a))))))"

    nts = initials g
    nts' = S.toList (nonterminalS g)
    holeDerivs
      = [ ( nt
          , t'
          , filter completeDerivation
          $ concatMap (deriveTree g t') nts'
          )
        | (nt, Left t')
            <- T.flatten $ maxSententialForm $ concatMap (deriveTree g t) nts
        ]
    underivableTrees = [t' | (_, t', ds) <- holeDerivs, null ds]
    merges
      = [ nt : map (fst . T.rootLabel) ds
        | (nt, _, ds) <- holeDerivs
        ]
-}

train prepareTree corpusFilter corpusFile1 corpusFile2
  = uncurry (generalize head)
  . first intifyNonterminals
  . second (zipWith (\ i t -> trace ("Tree " ++ show i ++ "\n" ++ T.drawTree t) t) [1 :: Int ..])
  . (\ x@(_, c) -> trace ("Corpus size: " ++ show (length c)) x)
  <$> prepareData prepareTree corpusFilter corpusFile1 corpusFile2
  where

{-
train2dot prepareTree corpusFilter f1 f2
  = ( render
    . fullHypergraph2dot drawNT label ""
    . toHypergraph
    ) <$> train prepareTree corpusFilter f1 f2
-}

unknownTerminals' prepareTree corpusFilter corpusFile1 corpusFile2 = do
  (g, ts) <- prepareData prepareTree corpusFilter corpusFile1 corpusFile2
  return $ S.unions $ map (unknownTerminals g) ts


prepareData prepareTree corpusFilter corpusFile1 corpusFile2 = do
  let prepareCorpus = map (prepareTree . toTree)
  g <- forestToGrammar . prepareCorpus <$> parsePennFile corpusFile1
  c <- filter (corpusFilter g) . prepareCorpus <$> parsePennFile corpusFile2
  return (g, c)


parsePennFile f
  = either (error . show) id <$> parseFromFile p_penn f


-- | Remove the leaves from a 'T.Tree'.
defoliate :: T.Tree t -> T.Tree t
defoliate (T.Node _ []) = error "Cannot defoliate a leaf-only tree."
defoliate (T.Node x xs)
  = T.Node x $ map defoliate $ filter (not . null . T.subForest) xs


hasCrossings = any ("*" `isPrefixOf`) . T.flatten


main
--   = train defoliate ((S.null .) . unknownTerminals) "PBSM/TestData/1a-penn-trees.txt" "PBSM/TestData/1b-penn-trees.txt"
  = train defoliate ((S.null .) . unknownTerminals) "PBSM/TestData/wsj1.combined" "PBSM/TestData/wsj2.combined"
  >>= print