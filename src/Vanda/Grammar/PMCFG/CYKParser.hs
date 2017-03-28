-----------------------------------------------------------------------------
-- |
-- Module      :  CYKParser
-- Copyright   :  (c) Thomas Ruprecht 2017
-- License     :  Redistribution and use in source and binary forms, with
--                or without modification, is ONLY permitted for teaching
--                purposes at Technische Universität Dresden AND IN
--                COORDINATION with the Chair of Foundations of Programming.
--
-- Maintainer  :  thomas.ruprecht@tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
--
-- This module provides two functions for parsing words using the 
-- CYK-parsing algorithm by Seki et al.
--
-- 'weightedParse' uses a weighted PMCFG to find a list of all possible
-- derivation trees ordered by minimal cost / maximum probability. The
-- rules' weights need to be instances of 'Monoid' and 
-- 'Vanda.Grammar.PMCFG.DeductiveSolver.Dividable'.
-- 'parse' uses an unweighted grammar to find a list of derivation trees
-- ordered by least rule applications.
--
-- The algorithm uses a deduction system to parse the word. Items of this 
-- deduction system are a tuple of a non-terminal, a vector of ranges in
-- the word we want to parse and a tree of applied derivation rules. Thus
-- every item represents a (partial) derivation step that generated parts
-- of the word by their ranges in it. There is exactly one deduction
-- rule for every rule of the grammar that uses already generated items
-- of all non-terminals in the rule and produces an item of the rule's lhs
-- non-terminal. To validate the generated sub-word of this step, the ranges
-- if all non-terminal and terminal symbols in the composition function of
-- the rule are replaced by the possible ranges in the word and concatenated,
-- s.t. they have to fit.
--
--
--
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

module Vanda.Grammar.PMCFG.CYKParser where

import Vanda.Grammar.PMCFG.DeductiveSolver
import Data.Weight
import Vanda.Grammar.PMCFG.Range
import Vanda.Grammar.PMCFG
import qualified Vanda.Grammar.PMCFG.Chart as C

import Data.Hashable (Hashable(hashWithSalt))
import qualified Data.HashMap.Lazy  as Map
import Data.Maybe (maybeToList)
import Data.Semiring
import Data.Tree (Tree)


data Item nt t wt = Active (Rule nt t) wt InstantiatedFunction wt
                  | Passive nt Rangevector (C.Backtrace nt t wt) wt


type Container nt t wt = ( C.Chart nt t wt
                         , Map.HashMap nt [Item nt t wt]
                         )


instance (Eq nt, Eq t) => Eq (Item nt t wt) where
  (Active r _ fw _) == (Active r' _ fw' _) = r == r' && fw == fw' 
  (Passive a rv _ _) == (Passive a' rv' _ _) = a == a' && rv == rv'
  _ == _ = False


instance (Hashable nt, Hashable t) => Hashable (Item nt t wt) where
    salt `hashWithSalt` (Active r _ _ _) = salt `hashWithSalt` r
    salt `hashWithSalt` (Passive a rho _ _) = salt `hashWithSalt` a `hashWithSalt` rho


instance (Show nt, Show t) => Show (Item nt t wt) where
    show (Active r _ f _) = "[active] rule #" ++ show r ++ " " ++ prettyPrintInstantiatedFunction f
    show (Passive a rv _ _) = "[passive] " ++ show a ++ " " ++ show rv 


-- | Top-level function to parse a word using a grammar.
parse :: (Eq t, Eq nt, Hashable nt, Hashable t)
      => PMCFG nt t                               -- ^ the grammar
      -> Int                                      -- ^ approximation parameter
      -> [t]                                      -- ^ the word
      -> [Tree (Rule nt t)]                       -- ^ list of derivation trees 
parse (PMCFG s rules) = weightedParse $ WPMCFG s $ zip rules $ repeat (cost 1 :: Cost Int)


-- | Top-level function to parse a word using a weighted grammar.
weightedParse :: forall nt t wt. (Eq t, Eq nt, Hashable nt, Hashable t, Semiring wt, Ord wt)
              => WPMCFG nt wt t             -- ^ weighted grammar
              -> Int                        -- ^ beam width
              -> [t]                        -- ^ word
              -> [Tree (Rule nt t)]   -- ^ parse trees and resulting weights
weightedParse (WPMCFG s rs) bw word = C.readoff s (singleton $ entire word)
                                      $ fst $ chart (C.empty, Map.empty) update deductiveRules bw
  where
    insides = insideWeights rs
    outsides = outsideWeights insides rs s

    deductiveRules = initialPrediction word (filter ((`elem` s) . lhs) rs) insides 
                      : prediction word rs insides outsides
                      : [completion outsides]

    update :: Container nt t wt
           -> Item nt t wt
           -> (Container nt t wt, Bool)
    update (passives, actives) (Passive a rho bt iw) = case C.insert passives a rho bt iw of
                                                            (passives', isnew) -> ((passives', actives), isnew)
    update (passives, actives) item@(Active (Rule ((_, as), _)) _ _ _) = ((passives, updateGroups as item actives), True)


initialPrediction :: forall nt t wt. (Eq nt, Eq t, Hashable nt, Semiring wt) 
                  => [t]
                  -> [(Rule nt t, wt)]
                  -> Map.HashMap nt wt
                  -> DeductiveRule (Item nt t wt) wt (Container nt t wt)
initialPrediction word srules insides = DeductiveRule 0 gets app
  where
    gets :: Container nt t wt -> Item nt t wt -> [[Item nt t wt]]
    gets _ _ = [[]]
    
    app :: Container nt t wt
        -> [Item nt t wt] 
        -> [(Item nt t wt, wt)]
    app _ [] =  [ (Active r w fw inside, inside)
                | (r@(Rule ((_, as), f)), w) <- srules
                , fw <- instantiate word f
                , let inside = w <.> foldl (<.>) one (map (insides Map.!) as)
                ]
    app _ _ = []
    
prediction :: forall nt t wt. (Eq nt, Eq t, Hashable nt, Semiring wt) 
           => [t]
           -> [(Rule nt t, wt)]
           -> Map.HashMap nt wt
           -> Map.HashMap nt wt
           -> DeductiveRule (Item nt t wt) wt (Container nt t wt)
prediction word rs insides outsides = DeductiveRule 1 gets app
  where
    gets :: Container nt t wt -> Item nt t wt -> [[Item nt t wt]]
    gets _ i@Active{} = [[i]]
    gets _ _ = []
    
    app :: Container nt t wt 
        -> [Item nt t wt] 
        -> [(Item nt t wt, wt)]
    app _ [Active (Rule ((_, as), _)) _ _ _] = [ (Active r' w' fw inside, inside <.> outside)
                                               | (r'@(Rule ((a', as'), f')), w') <- rs
                                               , a' `elem` as
                                               , fw <- instantiate word f'
                                               , let inside = w' <.> foldl (<.>) one (map (insides Map.!) as')
                                                     outside = outsides Map.! a'
                                               ]
    app _ _ = []
      
completion :: forall nt t wt. (Eq nt, Eq t, Hashable nt, Semiring wt) 
           => Map.HashMap nt wt
           -> DeductiveRule (Item nt t wt) wt (Container nt t wt)
completion outsides = DeductiveRule 3 gets app
  where
    gets :: Container nt t wt -> Item nt t wt -> [[Item nt t wt]]
    gets (passives, _) i@(Active (Rule ((_, as), _)) _ _ _) = [ i:candidates
                                                              | candidates <- mapM (C.lookupWith Passive passives) as
                                                              ]
    gets (passives, actives) i@(Passive a _ _ _) = [ active:candidates
                                                   | active@(Active (Rule ((_, as), _)) _ _ _ ) <- Map.lookupDefault [] a actives
                                                   , candidates <- filter (elem i) $ mapM (C.lookupWith Passive passives) as
                                                   ]
    
    app :: Container nt t wt -> [Item nt t wt] -> [(Item nt t wt, wt)]
    app _ (Active r@(Rule ((a, _), _)) w fw _: pas) = [ (Passive a rv (C.Backtrace r w rvs) inside, inside <.> outside)
                                                      | rv <- maybeToList $ insert rvs fw
                                                      , let inside = mconcat ws <.> w
                                                            outside = outsides Map.! a
                                                      ]
      where
        (rvs, ws) = foldr (\ (Passive _ rv _ iw) (rvs', ws') -> (rv:rvs', iw:ws')) ([], []) pas
        
        insert :: [Rangevector] -> InstantiatedFunction -> Maybe Rangevector
        insert rvs' = (>>= fromList) . mapM ((>>= toRange) . concVarRange . map (insert' rvs'))
          
        insert' :: [Rangevector] -> VarT Range -> VarT Range
        insert' rvs' (Var x y)  = T $ rvs' !! x ! y
        insert' _ r' = r'
    app _ _ = []