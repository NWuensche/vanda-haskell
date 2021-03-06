-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) Toni Dietze 2010
-- License     :  BSD-style
--
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

-- |
-- Maintainer  :  Toni Dietze
--
-- This module computes the intersect of a 'WSA.WSA' and a 'WTA.WTA'. The resulting 'WTA.WTA' will recognize the intersection of the languages of both automata.
-- This implementation uses the Early algorithm.
--
-- See <http://dl.acm.org/citation.cfm?id=1697236.1697238> for theoretical informations about the Bar-Hillel-Algorithm.

{-- snippet head --}
module Algorithms.WTABarHillelTopDown
( intersect
, intersect'
, -- * Miscellaneous
  intersectionItemCount
) where

--module Algorithms.WTABarHillelTopDown where

import Data.Hypergraph
import qualified Data.Queue as Q
import qualified Data.WSA as WSA
import qualified Data.WTA as WTA
import Tools.Miscellaneous (mapFst, mapSnd)

import qualified Data.Set as Set
import qualified Data.Map as Map

{-- /snippet head --}
----- Main ---------------------------------------------------------------------
{-- snippet Item --}
-- Item wsaState wtaState terminal weight
data Item p q t w i = Item
    { wsaStatesRev :: [p]               -- ^ List of states of a 'WSA' in reverse order.
    , wsaStatesFst :: p                 -- ^ The last state of the list above (meaning the first state of the not-reversed list).
    , wtaTrans     :: Hyperedge q t w i -- ^ The transition the item was built from.
    , wtaTransRest :: [q]               -- ^ List of states after the bullet.
    , weight       :: w                 -- ^ Weight of the transition of the 'WTA'
    }
{-- /snippet Item --}
{-- snippet State --}
-- State wsaState wtaState terminal weight
-- | A state represents the actual status of the algorithm.
data State p q t w i = State
    { itemq :: Q.Queue (Item p q t w i)                         -- ^ A 'Queue' of Items.
    , pmap  :: Map.Map q ([Hyperedge q t w i], Set.Set p)       -- ^ Map each state q of a 'WTA' to the transitions in the 'WTA' ('Hyperedge's) which use q as head vertex
                                                                -- and to the set of states of a 'WSA' for which the transitions already have been predicted
    , smap  :: Map.Map (p, t) [(p, w)]                          -- ^ Another representation of 'WSA'-transitions. An incoming state and a terminal are mapped to a list of outcoming states and weights.
    , cmap  :: Map.Map (p, q) (Set.Set p, [Item p q t w i])     -- ^ Map a 'WSA' state p and a 'WTA' state q to a set of 'WSA' states and a list of 'Item's.
    , epsilonTest :: t -> Bool                                  -- ^ Check, wether a terminal t should be interpreted as empty string or not.
    }
{-- /snippet State --}
{-- snippet intersect --}
{-- snippet head --}
-- | Intersect a 'WSA.WSA' and a 'WTA.WTA'.
intersect ::
  (Ord p, Ord q, Ord t, Num w) =>
  WSA.WSA p t w -> WTA.WTA q t w i -> WTA.WTA (p, q, p) t w i
intersect wsa wta = intersect' (const False) wsa wta

-- |  Intersect a 'WSA.WSA' and a 'WTA.WTA'. Use a boolean function to determine,
-- wether a terminal should be interpreted as empty string or not.
intersect' ::
  (Ord p, Ord q, Ord t, Num w) =>
  (t -> Bool)
  -> WSA.WSA p t w
  -> WTA.WTA q t w i
  -> WTA.WTA (p, q, p) t w i
{-- /snippet head --}
intersect' epsTest wsa wta
  = let finals  = [ ((ssi, ts, sso), w1 * w2 * w3)
                  | (ssi, w1) <- WSA.initialWeights wsa
                  , (ts , w2) <- Map.toList $ WTA.finalWeights wta
                  , (sso, w3) <- WSA.finalWeights wsa ]
        trans   = iter extractTransition (initState epsTest wsa wta)
    in WTA.wtaCreate finals trans

{-- /snippet intersect --}

{-- snippet iter --}
-- | Perform an iteration of the early algorithm, meaning apply complete, predict
-- and scan to the passed 'State' and return the resulting 'State'.
-- Return a list of 'WTA.Transitions' extracted from the items using the passed function.
iter ::
  (Ord p, Ord q, Ord t, Num w) =>
  (Item p q t w i -> Maybe a) -> State p q t w i -> [a]
iter extract s
  = if Q.null (itemq s)
    then []
    else
      let (i, itemq') = Q.deq (itemq s)
      in maybe id (:) (extract i) $
        iter extract $ complete i $ predict i s{itemq = itemq'}         -- the functions predict, complete  are called for the first
                                                                        --'Item' and the 'State' with a changed list of 'Items' (The first 'Item' is removed).
                                                                        -- Scanning is performed in the predict'-function.
{-- /snippet iter --}

{-- snippet extractTransition --}
-- | Extract a 'WTA.Transition' from an 'Item', if possible.
extractTransition ::
  Item p q t w i -> Maybe (Hyperedge (p, q, p) t w i)
extractTransition
    Item { wtaTransRest = []
         , wsaStatesRev = psRev
         , wtaTrans = trans
         , weight = w
         }
  = let ps = reverse psRev
    in Just $ hyperedge
        (head ps, eHead trans, head psRev)
        (zip3 ps (eTail trans) (tail ps))
        (eLabel trans)
        w
        (eId trans)
extractTransition _
  = Nothing
{-- /snippet extractTransition --}

----- Initialization -----------------------------------------------------------
{-- snippet init --}
-- | Construct a map representing the 'Transition's of a 'WSA'.
initScanMap ::
  (Ord p, Ord t) =>
  [WSA.Transition p t w] -> Map.Map (p, t) [(p, w)]
initScanMap ts
  = Map.fromListWith (++)
      [ (  (WSA.transStateIn  t, WSA.transTerminal t)
        , [(WSA.transStateOut t, WSA.transWeight   t)]
        )
      | t <- ts
      ]

-- | Construct the initial 'State'.
initState ::
  (Ord p, Ord q, Ord t, Num w) =>
  (t -> Bool) -> WSA.WSA p t w -> WTA.WTA q t w i -> State p q t w i
initState epsTest wsa wta
  = let state = State { itemq = Q.empty
                      , pmap  = Map.map (\x -> (x, Set.empty))
                              $ edgesM
                              $ WTA.toHypergraph wta
                      , smap  = initScanMap (WSA.transitions wsa)
                      , cmap  = Map.empty
                      , epsilonTest = epsTest
                      }
    in foldr predict' state
          [ (p, q)
          | (p, _) <- WSA.initialWeights wsa
          , q <- Map.keys $ WTA.finalWeights wta
          ]
{-- /snippet init --}

----- Predictor and Scanner ----------------------------------------------------
{-- snippet predict --}
-- | Perform a prediction step.
predict ::
  (Ord p, Ord q, Ord t, Num w) =>
  Item p q t w i -> State p q t w i -> State p q t w i
predict
    Item { wsaStatesRev = p:_
         , wtaTransRest = q:_
         }
  = predict' (p, q)
predict _
  = id
{-- /snippet predict --}

{-- snippet predict_ --}
-- | take two states of a 'WSA' and a 'WTA' respectively
-- and a 'State' and perform a prediction-step
predict' ::
  (Ord p, Ord q, Ord t, Num w) =>
  (p, q) -> State p q t w i -> State p q t w i
predict' (p, q) s
  = case Map.lookup q (pmap s) of
      Nothing -> s
      Just (ts, ps) ->
        if Set.member p ps
        then s
        else
          let newI t = Item [p] p t (eTail t) (eWeight t)
              pmap'  = Map.insert q (ts, Set.insert p ps) (pmap s)
          in foldr (scan . newI) (s { pmap = pmap' }) ts
{-- /snippet predict_ --}

{-- snippet scan --}
-- | Perform a scanning-step.
scan ::
  (Ord p, Ord t, Num w) =>
  Item p q t w i -> State p q t w  i-> State p q t w i
scan i@Item{wtaTransRest = []} s
  = let p = wsaStatesFst i
        t = eLabel (wtaTrans i)
        scanI (p', w) = i { wsaStatesRev = p':(wsaStatesRev i)
                          , weight = w * weight i
                          }
        update = maybe id (Q.enqListWith scanI) (Map.lookup (p, t) (smap s))
    in if (epsilonTest s) t
    then s { itemq = Q.enq (scanI (p, 1)) (itemq s) }
    else s { itemq = update (itemq s) }
scan i s
  = s { itemq = Q.enq i (itemq s) }
{-- /snippet scan --}

----- Completer ----------------------------------------------------------------
{-- snippet complete --}
-- | Perform a completion-step.
complete ::
  (Ord p, Ord q) => Item p q t w i-> State p q t w i -> State p q t w i
complete
    i@Item { wsaStatesRev = p:_
           , wtaTransRest = q:_
           }
    s
  = let ps'     = maybe [] (Set.toList . fst) (Map.lookup (p, q) (cmap s))
        itemq'  = Q.enqListWith (flip completeItem i) ps' (itemq s)
        cmap'   = Map.alter
                    (Just . maybe (Set.empty, [i]) (mapSnd (i:)))
                    (p, q)
                    (cmap s)
    in s { itemq = itemq', cmap = cmap' }
complete
    i@Item { wsaStatesRev = p':_
           , wtaTransRest = []
           }
    s
  = let p       = wsaStatesFst i
        q       = eHead (wtaTrans i)
        cmap'   = Map.alter
                    (Just . maybe (Set.singleton p', [])
                                  (mapFst (Set.insert p')))
                    (p, q)
                    (cmap s)
        is      = maybe [] snd (Map.lookup (p, q) (cmap s))
        itemq'  = Q.enqListWith (completeItem p') is (itemq s)
    in if maybe False (Set.member p' . fst) (Map.lookup (p, q) (cmap s))
       then s
       else s { itemq = itemq', cmap = cmap' }
complete _ _
  = error "WTABarHillelTopDown.complete"


completeItem :: p -> Item p q t w i -> Item p q t w i
completeItem p' i
  = i { wsaStatesRev = p':(wsaStatesRev i)
      , wtaTransRest = tail (wtaTransRest i)
      }

{-- /snippet complete --}

----- Debugging ----------------------------------------------------------------

showItem ::
  (Show p, Show q, Show t, Show w) => Item p q t w i -> [Char]
showItem i
  = let t   = wtaTrans i
        qs  = eTail t
        l   = length qs - length (wtaTransRest i)
        qs' = init (show (take l qs)) ++ "*" ++ tail (show (drop l qs))
    in     "[("
        ++ qs'
        ++ ", "
        ++ show (eLabel t)
        ++ ", "
        ++ show (eHead t)
        ++ ")"
        ++ ", "
        ++ show (weight i)
        ++ ", "
        ++ show (reverse $ wsaStatesRev i)
        ++ "]"

showItemLaTeX :: (Show w) => Item Char Char Char w i -> [Char]
showItemLaTeX i
  = let t   = wtaTrans i
        qs  = eTail t
        l   = length qs - length (wtaTransRest i)
        qs' = take l qs ++ "{\\bullet}" ++ drop l qs
        cts = (:[])
        term 'a' = "\\alpha"
        term 'b' = "\\beta"
        term _   = error "WTABarHillelTopDown.showItemLaTeX"
    in     "[("
        ++ qs'
        ++ ", "
        ++ term (eLabel t)
        ++ ", "
        ++ cts (eHead t)
        ++ ")"
        ++ ", "
        ++ show (weight i)
        ++ ", "
        ++ reverse (wsaStatesRev i)
        ++ "]"

getIntersectItems ::
  (Ord p, Show p, Ord q, Show q, Ord t, Show t, Num w, Show w) =>
  (t -> Bool) -> WSA.WSA p t w -> WTA.WTA q t w i -> [[Char]]
getIntersectItems epsTest wsa wta
  = iter (Just . showItem) (initState epsTest wsa wta)

getIntersectItemsLaTeX ::
  (Num w, Show w) =>
  (Char -> Bool)
  -> WSA.WSA Char Char w
  -> WTA.WTA Char Char w i
  -> [[Char]]
getIntersectItemsLaTeX epsTest wsa wta
  = zipWith (++)
        (map (\x -> "\\\\\n&  i_{" ++ show x ++ "} = ") [(1 :: Int) ..])
        (iter (Just . showItemLaTeX) (initState epsTest wsa wta))


intersectionItemCount
  :: (Ord p, Ord q, Ord t, Num w) => WSA.WSA p t w -> WTA.WTA q t w i -> Int
intersectionItemCount wsa wta
  = length $ iter Just (initState (const False) wsa wta)
