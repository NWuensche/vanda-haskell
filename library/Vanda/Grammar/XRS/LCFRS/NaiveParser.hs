-----------------------------------------------------------------------------
-- |
-- Module      :  CYKParser
-- Copyright   :  (c) Thomas Ruprecht 2017
-- License     :  BSD-style
--
-- Maintainer  :  thomas.ruprecht@tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
--
-- This module provides two functions for parsing words using the 
-- naive (active) parsing algorithm by Burden and Ljunglöf.
-- @weightedParse@ uses a weighted PMCFG to find a list of all possible
-- derivation trees ordered by minimal cost / maximum probability. The
-- rules' weights need to be instances of @Monoid@ and @Dividable@.
-- @parse@ uses an unweighted grammar to find a list of derivation trees
-- ordered by least rule applications.
--
-- 
--
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

module Vanda.Grammar.XRS.LCFRS.NaiveParser
  ( parse
  , parse'
  ) where

import Data.Converging (Converging)
import Data.Hashable (Hashable(hashWithSalt))
import Data.Maybe (maybeToList, catMaybes)
import Data.Range
import Data.Semiring
import Data.Tree (Tree)
import Data.Weight
import Vanda.Grammar.PMCFG

import qualified Vanda.Grammar.XRS.LCFRS.Chart as C
import qualified Data.HashMap.Lazy             as Map
import qualified Data.MultiHashMap             as MMap
import qualified Data.HashSet                  as Set

-- | Passive and active items.
data Item nt t wt 
  = Active (Rule nt t) wt [nt] [Rangevector] InstantiatedFunction wt
  | Passive nt Rangevector (C.Backtrace nt t wt) wt


-- | Container type contains chart for passive items and map for active ones.
type Container nt t wt = ( C.Chart nt t wt
                         , MMap.MultiMap nt (Item nt t wt)
                         , Set.HashSet nt
                         )


instance (Eq nt, Eq t) => Eq (Item nt t wt) where
  (Active r _ _ rhos fs _) == (Active r' _ _ rhos' fs' _) = r    == r' 
                                                             && rhos == rhos' 
                                                             && fs   == fs'
  (Passive a rv _ _) == (Passive a' rv' _ _) = a  == a'
                                            && rv == rv'
  _ == _ = False


instance (Hashable nt, Hashable t) => Hashable (Item nt t wt) where
    salt `hashWithSalt` (Active r _ _ rhos _ _)
      = salt `hashWithSalt` r `hashWithSalt` rhos
    salt `hashWithSalt` (Passive a rho _ _)
      = salt `hashWithSalt` a `hashWithSalt` rho


instance (Show nt, Show t) => Show (Item nt t wt) where
  show (Active r _ as _ fs _) 
    = "[active] " ++ show r ++ "\n"
    ++ "nonterminals left: " ++ show as ++ "\n"
    ++ "current status: " ++ prettyPrintInstantiatedFunction fs
  show (Passive a rv _ _) 
    = "[passive] " ++ show a ++ " → " ++ show rv 


-- | Top-level function to parse a word using a weighted PMCFG.
parse :: forall nt t wt. (Hashable nt, Hashable t, Eq t, Ord wt, Weight wt, Ord nt, Converging wt) 
              => WPMCFG nt wt t     -- ^ weighted grammar
              -> Int                -- ^ beam width
              -> Int                -- ^ max number of parse trees
              -> [t]                -- ^ terminal word
              -> [Tree (Rule nt t)] -- ^ derivation tree of applied rules
parse g bw trees word
  = parse' (prepare g word) bw trees word

parse' :: forall nt t wt. (Hashable nt, Hashable t, Eq t, Ord wt, Weight wt, Ord nt, Converging wt)
              => (MMap.MultiMap nt (Rule nt t, wt), Map.HashMap nt (wt,wt), [nt])
              -> Int                        -- ^ beam width
              -> Int                        -- ^ maximum number of returned trees
              -> [t]                        -- ^ word
              -> [Tree (Rule nt t)]
parse' (rmap, iow, s') bw trees word 
  = C.parseTrees trees s' (singleton $ entire word)
  $ (\ (e, _, _) -> e)
  $ C.chartify (C.empty, MMap.empty, nset) update rules bw trees
    where
      rules = initialPrediction word (s' >>= (`MMap.lookup` rmap)) iow
              : predictionRule word rmap iow
              -- : conversionRule iow
              : [completionRule iow]
      
      nset = Set.fromList $ filter (not . (`elem` s')) $ Map.keys rmap

      update :: Container nt t wt
            -> Item nt t wt 
            -> (Container nt t wt, Bool)
      update (p, a, ns) (Passive nta rho bt word) 
        = case C.insert p nta rho bt word of 
               (p', isnew) -> ((p', a, ns), isnew)
      update (p, a, ns) item@(Active _ _ (nta:_) _ _ _)
        = ((p, MMap.insert nta item a, Set.delete nta ns), True)
      update c _ = (c, True)

initialPrediction :: forall nt t wt. (Hashable nt, Eq nt, Eq t, Semiring wt)
                  => [t]
                  -> [(Rule nt t, wt)]
                  -> Map.HashMap nt (wt, wt)
                  -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
initialPrediction word srules ios
  = Left 
  $ catMaybes [ implicitConversion (Active r w as [] fw inside, inside)
              | (r@(Rule ((_, as), f)), w) <- srules
              , fw <- instantiate word f
              , let inside = w <.> foldl (<.>) one (map (fst . (ios Map.!)) as)
              ]

-- | Constructs deductive rules using one rule of a grammar.
-- * prediction: initializes an active item without using antecendent items
predictionRule :: forall nt t wt. (Eq t, Eq nt, Hashable nt, Semiring wt) 
               => [t] 
               -> MMap.MultiMap nt (Rule nt t, wt)
               -> Map.HashMap nt (wt, wt)
               -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
predictionRule word rs ios = Right app
  where
    app :: Item nt t wt 
        -> Container nt t wt 
        -> [(Item nt t wt, wt)]
    app (Active _ _ (a:_) _ _ _) (_,_,notinitialized)
      = catMaybes
        [ implicitConversion (Active r' w' as' [] fw inside, inside <.> outside)
        | a `Set.member` notinitialized
        , (r'@(Rule ((_, as'), f')), w') <- MMap.lookup a rs
        , fw <- instantiate word f'
        , let inside = w' <.> foldl (<.>) one (map (fst . (ios Map.!)) as')
              outside = snd $ ios Map.! a
        ]
    app _ _ = []


implicitConversion :: (Item nt t wt, wt) -> Maybe (Item nt t wt, wt)
implicitConversion (Active r@(Rule ((a, _), _)) w [] rss fs inside, weight)
  = mapM toRange fs 
    >>= fromList 
    >>= (\ rv -> return (Passive a rv (C.Backtrace r w (reverse rss)) inside, weight))
implicitConversion i = Just i


-- | Constructs deductive rules using one rule of a grammar.
-- * completion: step-by-step substituting of variables in instantiated 
-- function using ranges of passive items
completionRule :: forall nt wt t. (Hashable nt, Eq nt, Weight wt)
               => Map.HashMap nt (wt, wt)
               -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
completionRule ios = Right app
  where
    app :: Item nt t wt -> Container nt t wt -> [(Item nt t wt, wt)]
    app i@(Active _ _ (next:_) _ _ _) (pas, _, _)
      = [ consequence
        | passive <- C.lookupWith Passive pas next
        , consequence <- consequences i passive
        ]
    app (Active _ _ [] _ _ _) _ = []
    app i@(Passive next _ _ _) (_, act, _)
      = [ consequence
        | active <- MMap.lookup next act
        , consequence <- consequences active i
        ]

    consequences (Active r w (a:as) rss fs ain) (Passive _ rv _ pin) 
      = catMaybes
        [ implicitConversion (Active r w as (rv:rss) fs' inside, inside <.> outside)
        | fs' <- maybeToList $ mapM concVarRange $ insert rv fs
        , let inside = ain <.> (pin </> fst (ios Map.! a))
              (Rule ((s,_),_)) = r 
              outside = snd $ ios Map.! s
        ]
    consequences _ _ = []



-- | Substitutes all variables with first index 0 with a corresponding range.
insert :: Rangevector -> InstantiatedFunction -> InstantiatedFunction
insert rv = map (map (substitute rv))
    where
        substitute :: Rangevector -> VarT Range -> VarT Range
        substitute rv' (Var 0 j) = T $ rv' ! j
        substitute _   (Var i j) = Var (i-1) j
        substitute _ r = r
