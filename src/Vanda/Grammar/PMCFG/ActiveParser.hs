-----------------------------------------------------------------------------
-- |
-- Module      :  ActiveParser
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
-- This module provides two functions for parsing words using the active
-- parsing algorithm by Burden and Ljunglöf.
-- @weightedParse@ uses a weighted PMCFG to find a list of all possible
-- derivation trees ordered by minimal cost / maximum probability. The
-- rules' weigthts need to be instances of @Monoid@ and @Dividable@.
-- @parse@ uses an unweighted grammar to find a list of derivation trees
-- ordered by least rule applications.
--
-- The parsing algorithm uses active and passive items to represent
-- possible subwords generated by a certain non-terminal. Whereas active
-- items represent an incomplete derivation (not all terminals of a rule 
-- are compared to the terminals of the word or not all non-terminals in 
-- the rule were replaced by valid subwords), passive items represent a full
-- rule application and thus a valid possible subword generated by rule.
-- To find all valid rule applications that generate a subword we want to 
-- parse, there are 4 different type of deductive rules applied until a
-- passive item is generated of the grammar's rule:
--
-- * prediction: an empty active item is generated by a grammar rule
-- * completion (terminal): a terminal symbol in the grammar rule's
-- composition function is read and replaced by the position in the word,
-- thus it should fit into the word and resulting ranges of neighboring 
-- symbols
-- * completion (non-terminal): a variable is replaced by a range of a
-- generated subword in the word, like a read terminal the resulting range
-- should fit in its environment
-- * conversion: if there are no symbols left to substitute by a range in
-- the current function component, the item marked to use the next componen;
-- if there are no components left, a passive item is created
--
-- In the end, all passive items are returned, as they are validly generated
-- subwords of the word to parse. These items are then filtered to be
-- generated by a staring non-terminal and generating the whole word.
--
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}


module Vanda.Grammar.PMCFG.ActiveParser
    ( parse
    , weightedParse
    ) where

import Vanda.Algorithms.InsideOutsideWeights (Converging)
import Vanda.Grammar.PMCFG
import Vanda.Grammar.PMCFG.Range
import Vanda.Grammar.PMCFG.DeductiveSolver
import Data.Weight
import qualified Vanda.Grammar.PMCFG.Chart as C

import qualified Data.IntMap       as IMap
import qualified Data.HashMap.Lazy as Map

import Data.Hashable (Hashable(hashWithSalt))
import Data.Tree (Tree)
import Data.Maybe (mapMaybe, maybeToList)
import Data.Semiring


data Item nt t wt = Passive nt Rangevector (C.Backtrace nt t wt) wt
                  | Active (Rule nt t) wt [Range] (Function t) (IMap.IntMap Rangevector) wt


instance (Eq nt, Eq t) => Eq (Item nt t wt)where
  (Active r _ rs fs completions _) == (Active r' _ rs' fs' completions' _) = r == r' && rs == rs' && completions == completions' && fs == fs'
  (Passive a rv bt _ ) == (Passive a' rv' bt' _) = a == a' && rv == rv' && bt == bt'
  _ == _ = False

instance (Hashable nt, Hashable t) => Hashable (Item nt t wt) where
  salt `hashWithSalt` (Passive a rho _ _) = salt `hashWithSalt` a `hashWithSalt` rho
  salt `hashWithSalt` (Active r _ _ fss _ _) = salt `hashWithSalt` r `hashWithSalt` length (concat fss)
    

instance (Show nt, Show t) => Show (Item nt t wt) where
  show (Passive a rv _ _) = "[Passive] " ++ show a ++ " " ++ show rv
  show (Active r _ rv f _ _) = "[Active] rule #" ++ show r ++ " " ++ show rv ++ " " ++ prettyPrintComposition f


type Container nt t wt =  (C.Chart nt t wt, Map.HashMap nt [Item nt t wt])

-- | Top-level function to parse a word using a PMCFG.
-- Uses weightedParse with additive costs for each rule, s.t. the number of rule applications is minimized.
parse :: (Hashable nt, Hashable t, Eq nt, Eq t, Ord nt) 
  => PMCFG nt t 
  -> Int 
  -> [t] 
  -> [Tree (Rule nt t)]
parse (PMCFG s rs) = weightedParse $ WPMCFG s $ zip rs $ repeat (cost 1 :: Cost Float)


-- | Top-level function to parse a word using a weighted PMCFG.
weightedParse :: forall nt t wt. (Hashable nt, Hashable t, Eq nt, Eq t, Ord wt, Weight wt, Ord nt, Converging wt) 
              => WPMCFG nt wt t 
              -> Int 
              -> [t] 
              -> [Tree (Rule nt t)]
weightedParse (WPMCFG s rs) bw w = C.readoff s (singleton $ entire w)
                                    $ fst $ chart (C.empty, Map.empty) update rules bw
    where
        iow = ioWeights s rs
        
        rules = initialPrediction w (filter ((`elem` s) . lhs) rs) iow
                : predictionRule w rs iow
                : conversionRule iow
                : [completionRule w iow]

        update :: Container nt t wt -> Item nt t wt -> (Container nt t wt, Bool)
        update (p, a) (Passive nta rho bt iw) = case C.insert p nta rho bt iw of
                                                     (p', isnew) -> ((p', a), isnew)
        update (p, a) item@(Active (Rule ((_, as),_)) _ _ ((Var i _:_):_) _ _)  = ((p, updateGroup (as !! i) item a), True)
        update (p, a) _ = ((p, a), True)


initialPrediction :: forall nt t wt. (Hashable nt, Eq nt, Semiring wt, Eq t) 
                  => [t]
                  -> [(Rule nt t, wt)]
                  -> Map.HashMap nt (wt, wt)
                  -> DeductiveRule (Item nt t wt) wt (Container nt t wt)
initialPrediction word srules ios = DeductiveRule 0 gets app
  where
    gets :: Container nt t wt -> Item nt t wt -> [[Item nt t wt]]
    gets _ _ = [[]]

    app :: Container nt t wt -> [Item nt t wt] -> [(Item nt t wt, wt)]
    app _ [] =  [ (Active r w rho' f' IMap.empty inside, inside) 
                | (r@(Rule ((_, as), f)), w) <- srules
                , (rho', f') <- completeKnownTokens word IMap.empty [Epsilon] f
                , let inside = w <.> foldl (<.>) one (map (fst . (ios Map.!)) as)
                ]
    app _ _ = []



predictionRule :: forall nt t wt. (Weight wt, Eq nt, Hashable nt, Eq t) 
               => [t]
               -> [(Rule nt t, wt)]
               -> Map.HashMap nt (wt, wt)
               -> DeductiveRule (Item nt t wt) wt (Container nt t wt)
predictionRule word rs ios = DeductiveRule 1 gets app
  where
    gets :: Container nt t wt -> Item nt t wt -> [[Item nt t wt]]
    gets _ item@(Active _ _ _ ((Var _ _:_):_) _ _) = [[item]]
    gets _ _ = []
    
    app :: Container nt t wt 
        -> [Item nt t wt] 
        -> [(Item nt t wt, wt)]
    app _ [Active (Rule ((_, as), _)) w _ ((Var i _:_):_) _ _] = [ (Active r' w rho'' f'' IMap.empty inside, inside <.> outside)
                                                                 | (r'@(Rule ((a', as'), f')), w') <- rs
                                                                 , a' == (as !! i)
                                                                 , (rho'', f'') <- completeKnownTokens word IMap.empty [Epsilon] f'
                                                                 , let inside = w' <.> foldl (<.>) one (map (fst . (ios Map.!)) as')
                                                                       outside = snd $ ios Map.! a'
                                                                 ]
    app _ _ = []



conversionRule :: forall nt t wt. (Semiring wt, Hashable nt, Eq nt)
               => Map.HashMap nt (wt, wt)
               -> DeductiveRule (Item nt t wt) wt (Container nt t wt)
conversionRule ios = DeductiveRule 1 gets app
  where
    gets :: Container nt t wt -> Item nt t wt -> [[Item nt t wt]]
    gets _ i@(Active _ _ _ [] _ _) = [[i]]
    gets _ _ = []

    app :: Container nt t wt -> [Item nt t wt] -> [(Item nt t wt, wt)]
    app _ [Active r w rs [] completions inside] = [ (Passive a rv (C.Backtrace r w rvs) inside, inside <.> outside)
                                                  | rv <- maybeToList $ fromList $ reverse rs
                                                  , let rvs = IMap.elems completions
                                                        (Rule ((a, _), _)) = r
                                                        outside = snd $ ios Map.! a
                                                  ]
    app _ _ = []

completeKnownTokens :: (Eq t) => [t] -> IMap.IntMap Rangevector -> [Range] -> Function t -> [([Range], Function t)]
completeKnownTokens _ _ rs [[]] = [(rs, [])]
completeKnownTokens w m rs ([]:fs) = completeKnownTokens w m (Epsilon:rs) fs
completeKnownTokens w m (r:rs) ((T t:fs):fss) = [ (r':rs, fs:fss)
                                                | r' <- mapMaybe (safeConc r) $ singletons t w
                                                ] >>= uncurry (completeKnownTokens w m)
completeKnownTokens w m (r:rs) ((Var i j:fs):fss) = case i `IMap.lookup` m of
                                                         Just rv -> case safeConc r (rv ! j) of
                                                                         Just r' -> completeKnownTokens w m (r':rs) (fs:fss)
                                                                         Nothing -> []
                                                         Nothing -> [(r:rs, (Var i j:fs):fss)]
completeKnownTokens _ _ _ _ = []
    

completionRule :: forall nt t wt. (Hashable nt, Eq nt, Eq t, Weight wt) 
               => [t]
               -> Map.HashMap nt (wt, wt)
               -> DeductiveRule (Item nt t wt) wt (Container nt t wt)
completionRule word ios = DeductiveRule 2 gets app
  where
    gets :: Container nt t wt -> Item nt t wt -> [[Item nt t wt]]
    gets (passives, _) active@(Active (Rule ((_, as), _)) _ _ ((Var i _:_):_) _ _) = [ [passive, active]
                                                                                     | passive <- C.lookupWith Passive passives (as !! i) 
                                                                                     ]
    gets (_, actives) passive@(Passive a _ _ _) =  [ [passive, active]
                                                   | active <- Map.lookupDefault [] a actives
                                                   ]
    gets _ _ = []

    app :: Container nt t wt -> [Item nt t wt] -> [(Item nt t wt, wt)]
    app _ [Passive a rv _ piw, Active r w (range:rho) ((Var i j:fs):fss) c aiw] = [ (Active r w rho' f' c' inside, inside <.> outside)
                                                                                  | range' <- maybeToList $ safeConc range (rv ! j)
                                                                                  , let c' = IMap.insert i rv c
                                                                                        inside = aiw <.> (piw </> fst (ios Map.! a))
                                                                                        outside = snd $ ios Map.! a
                                                                                  , (rho', f') <- completeKnownTokens word c' (range':rho) (fs:fss)
                                                                                  ]
    app _ _ = []
