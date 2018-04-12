-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) Technische Universität Dresden 2018
-- License     :  BSD-style
--
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

module Vanda.Grammar.LCFRS.ActiveParserTest
    (tests) where

import Test.HUnit
import Vanda.Grammar.PMCFG
import Vanda.Grammar.XRS.LCFRS.ActiveParser
import Data.Weight
import Data.Maybe (mapMaybe)
import Numeric.Log (Log)
import Control.Arrow (second)

exampleWPMCFG' :: WPMCFG Int (Probabilistic (Log Double)) Char
exampleWPMCFG' = case exampleWPMCFG of
                      (WPMCFG s rs) -> WPMCFG s $ map (second probabilistic) rs


tests :: Test
tests = TestList  [ TestCase 
                    $ assertEqual
                      "Cannot reproduce exmaple derivation" 
                      [exampleDerivation] 
                    $ parse 
                        exampleWPMCFG' 100 1 "aabccd"
                  , TestCase 
                    $ assertEqual 
                      "Cannot reproduce parsed string in yield"
                      ["aabbccdd"] 
                    $ mapMaybe yield 
                      $ parse exampleWPMCFG' 100 1 "aabbccdd"
                  ]
