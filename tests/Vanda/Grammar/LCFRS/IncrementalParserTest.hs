-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) Technische Universität Dresden 2018
-- License     :  BSD-style
--
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

module Vanda.Grammar.LCFRS.IncrementalParserTest
    (tests) where

import Test.HUnit
import Vanda.Grammar.XRS.LCFRS.IncrementalParser
import Vanda.Grammar.PMCFG 
import Data.Range
import Data.Maybe (mapMaybe)
import Numeric.Log (Log)
import qualified Data.IntMap                   as IMap
import Data.Weight
import Data.Maybe (mapMaybe)
import Numeric.Log (Log)
import Control.Arrow (second)

exampleWPMCFG' :: WPMCFG Int (Probabilistic (Log Double)) Char
exampleWPMCFG' = case exampleWPMCFG of
                      (WPMCFG s rs) -> WPMCFG s $ map (second probabilistic) rs

exampleRules' :: [Rule Int Char]
exampleRules' = [ Rule ((0, []), [[T 'a']]),
                    Rule ((0, []), [[T 'a', T 'b']]),
                  Rule ((0, [1,2]), [[Var 0 0, Var 1 0]]),
                  Rule ((0, [1]), [[Var 0 0]]),
                  Rule ((0, [1,3]), [[Var 0 0, Var 1 0, Var 1 1]]),
 --                 Rule ((0, [0]), [[Var 0 0, Var 0 0]]),
                  Rule ((1, []), [[T 'A']]),
                  Rule ((2, [3]), [[Var 0 1]]),
                  Rule ((3, []), [[T 'B'], [T 'C']])
                ]

exampleWPMCFG'' :: WPMCFG Int Double Char
exampleWPMCFG'' = fromWeightedRules [0] $ zip exampleRules' (cycle [1])

exampleWPMCFG''' :: WPMCFG Int (Probabilistic (Log Double)) Char
exampleWPMCFG''' = case exampleWPMCFG'' of
                      (WPMCFG s rs) -> WPMCFG s $ map (second probabilistic) rs
first :: (x,y,z) -> x
first (x,_,_) = x

tests :: Test
tests = TestList    [ 
--                        TestCase  $ assertEqual "ErrorMessage" "File Connected" testParse
--                        , TestCase $ assertEqual "Can't find item after init. Pred" Active (Rule ((2, []), [[], []])) 1 [Epsilon] ([[]]) IMap.empty 1 $ parse exampleWPMCFG 1000 100 "")
 --                       , TestCase $ assertEqual "Can't find item after init. Pred" ["a"] $ mapMaybe yield $ parse exampleWPMCFG''' 100 1 "a"
  --                      , TestCase $ assertEqual "Can't find item after init. Pred" ["ab"] $ mapMaybe yield $ parse exampleWPMCFG''' 100 1 "ab"
   --                     , TestCase $ assertEqual "Can't find item after init + Combine" ["A"] $ mapMaybe yield $ parse exampleWPMCFG''' 100 1 "A"
                        TestCase $ assertEqual "Can't find item after init + Combine" ["ABC"] $ mapMaybe yield $ parse exampleWPMCFG''' 100 1 "ABC"
                        ,TestCase $ assertEqual "Longer Parsing dosen't work" ["aabccd"] $ mapMaybe yield $ parse exampleWPMCFG' 100 1 "aabccd"
--                        , TestCase $ assertEqual "Can't find item after init + Combine" ["aa"] $ mapMaybe yield $ parse exampleWPMCFG''' 100 1 "aa"
--                      , TestCase $ not assertEqual "Wrong Pretty Printed Grammar" "Test" exampleGrammar
                     ]

--                        TestCase $ assertEquals "Active Item not in Chart after ",
--                       TestCase $ assertEqual "Chart Update doesn't work" 
