-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) Johannes Osterholzer
-- License     :  BSD-style
--
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

{-# LANGUAGE FlexibleContexts #-}

module Algorithms.KAStar.State
  (
    KAStar ()
  , runKAStar
  , graph
  , goal
  , heuristic
  , inEdges
  , otherEdges
  , inEdgesMap
  , chart
  , agenda
  , agendaInsert
  , popAgenda
  , chartInsert
  , numDeriv
  ) where

import Control.Monad (liftM, liftM2)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import Control.Monad.Trans.State (State, get, put, runState)
import qualified Data.Map as M
import qualified Data.Heap as H
import qualified Data.Sequence as S
import Data.List (foldl')
import Data.Sequence ((<|))
import Data.Maybe (fromJust)

import Data.Hypergraph

import Algorithms.KAStar.Data

------------------------------------------------------------------------------
-- Algorithm State -----------------------------------------------------------
------------------------------------------------------------------------------

-- | Monad stack for state and configuration of the KA* algorithm
type KAStar p v l w i a
       = ReaderT (KAConfig v l w i) (State (KAState p v l w i)) a


-- | Holds configuration for KA*
data KAConfig v l w i = KAConfig {
    cfgNumDeriv   :: Int
    -- ^ number @k@ of derivations to be searched for
  , cfgGraph      :: Hypergraph v l w i
    -- ^ underlying graph
  , cfgGoal       :: v
    -- ^ goal node whose derivations are searched
  , cfgHeuristic  :: v -> w
    -- ^ the supplied heuristic function
  , cfgInEdges    :: M.Map v [(Hyperedge v l w i, Int)]
    -- ^ assigns tail-nodes to their hyperedge, together with their position
  , cfgOtherEdges :: M.Map v [(Hyperedge v l w i, Int)]
    -- ^ as 'cfgInEdges', but also for the edge's head node
  }


-- | Data structure holding run-time state of KA*
data KAState p v l w i = KAState {
      stChart          :: Chart v l w i
      -- ^ chart holds processed assignments
    , stAgenda         :: Agenda p v l w i
      -- ^ pqueue with prioritized assignments waiting to be processed
    , stItemsInserted  :: Int
      -- ^ number of assignments inserted into chart
    , stItemsGenerated :: Int
      -- ^ number of assignments inserted into agenda
    }


-- | Runs the KAStar monad, similar to runState
runKAStar :: KAStar p v l w i a
          -> Agenda p v l w i
          -> Int
          -> Hypergraph v l w i
          -> v
          -> (v -> w)
          -> M.Map v [(Hyperedge v l w i, Int)]
          -> M.Map v [(Hyperedge v l w i, Int)]
          -> (a, KAState p v l w i)
runKAStar kst a k gr g h ins others =
    let cfg   = KAConfig k gr g h ins others
        st    = KAState (C M.empty M.empty) a 0 0
    in runState (runReaderT kst cfg) st


-- | Returns number of derivations searched for
numDeriv :: KAStar p v l w i Int
numDeriv = cfgNumDeriv `liftM` ask


-- | Returns underlying graph
graph :: KAStar p v l w i (Hypergraph v l w i)
graph = cfgGraph `liftM` ask


-- | Returns goal node
goal :: KAStar p v l w i v
goal = cfgGoal `liftM` ask


-- | Returns supplied heuristic
heuristic :: KAStar p v l w i (v -> w)
heuristic = cfgHeuristic `liftM` ask


-- | Returns element from in-edges data structure, see 'cfgInEdges'
inEdges :: Ord v => v -> KAStar p v l w i [(Hyperedge v l w i, Int)]
inEdges v = (M.findWithDefault [] v . cfgInEdges) `liftM` ask


-- | Returns element from other-edges structure, see 'cfgOtherEdges'
otherEdges :: Ord v => v -> KAStar p v l w i [(Hyperedge v l w i, Int)]
otherEdges v = (M.findWithDefault [] v . cfgOtherEdges) `liftM` ask


-- | Returns the whole in-edges data structure, see 'cfgOtherEdges'
inEdgesMap :: KAStar p v l w i (M.Map v [(Hyperedge v l w i, Int)])
inEdgesMap = cfgInEdges `liftM` ask

-- | Returns momentary chart
chart :: KAStar p v l w i (Chart v l w i)
chart = lift $ stChart `liftM` get

-- | Returns the agenda
agenda :: KAStar p v l w i (Agenda p v l w i)
agenda = lift $ stAgenda `liftM` get


-- | Set the chart
putChart :: Chart v l w i -> KAStar p v l w i ()
putChart c = lift $ do
  st <- get
  put st{stChart = c}


-- | Set the agenda
putAgenda :: Agenda p v l w i -> KAStar p v l w i ()
putAgenda a = lift $ do
  st <- get
  put st{stAgenda = a}


-- | Increment number of inserted assignments
incItemsInserted :: KAStar p v l w i ()
incItemsInserted = lift $ do
  st <- get
  put st{stItemsInserted = stItemsInserted st + 1}


-- | Increment number of generated assignments by @n@
incItemsGenerated :: Int -> KAStar p v l w i ()
incItemsGenerated n = lift $ do
  st <- get
  put st{stItemsGenerated = stItemsGenerated st + n}


-- | @chartInsert a@ inserts assignment @a@ into the chart, provided it does
--   not already contain it (In this case, @Nothing@ is returned).
--   Ranked items are annotated with their corresponding rank upon insertion.
--   The number of inserted assignments is updated accordingly.
chartInsert
  :: (Ord v, Eq l, Eq w, Ord i)
  => Assignment v l w i
  -> KAStar p v l w i (Maybe (Assignment v l w i))
chartInsert assgmt = do
  enough <- case assgmt of
    (Ranked (K v _ _ _) _) -> liftM2 (>) ((flip numRanked v) `liftM` chart) numDeriv
    _                      -> return False
  contained <- chartContains assgmt
  if enough || contained
    then return Nothing
    else do
      incItemsInserted
      bpInsert assgmt
      Just `liftM` eInsert assgmt
  where
    bpInsert a@(Ranked (K _ e _ bps) _) = do
      c <- chart
      let bc' = foldl (\m k -> M.insertWith' (++) k [rk c a] m) (cBPMap c)
                [(eId e, bp, val) | bp <- [1 .. length bps]
                              , let val = bps !! (bp - 1)]
      putChart c{cBPMap = bc'}
    bpInsert _ = return ()
    eInsert a = do
      c <- chart
      putChart c{cEdgeMap = M.alter (Just . update c a) (node a) (cEdgeMap c)}
      return $ rk c a
    update _ a@(Inside _ _)  Nothing   = EM [a] [] S.empty
    update _ a@(Outside _ _) Nothing   = EM [] [a] S.empty
    update c a@(Ranked _ _)  Nothing   = EM [] []  (S.singleton $ rk c a)
    update _ a@(Inside _ _)  (Just ce) = ce{emInside = [a]}
    update _ a@(Outside _ _) (Just ce) = ce{emOutside = [a]}
    update c a@(Ranked _ _)  (Just ce) = ce{emRanked = rk c a <| emRanked ce}
    rk c (Ranked (K v e _ bps) w) =
      Ranked (K v e (succ $ numRanked c v) bps) w
    rk _ x = x


-- | @chartContains a@ checks whether the chart already contains an
--   assignment that is equal to @a@ (with no respect paid to the rank
--   of ranked items).
chartContains
  :: (Ord v, Eq l, Eq w, Eq i)
  => Assignment v l w i -> KAStar p v l w i Bool
chartContains (Inside (I v) _)
  = (not . null . flip insideAssignments v) `liftM` chart
chartContains (Outside (O v) _)
  = (not . null . flip outsideAssignments v) `liftM` chart
chartContains r@(Ranked (K v _ _ _) _)
  = (r `elem`) `liftM` (flip rankedAssignments v `liftM` chart)


-- | @agendaInsert as@ inserts the list @as@ of prioritized assignments
--   into the current agenda, updating the number of generated assignments
--   accordingly.
agendaInsert
  :: (Ord v, Ord w, H.HeapItem p (w, Assignment v l w i))
  => [(w, Assignment v l w i)] -> KAStar p v l w i ()
agendaInsert as = do
  incItemsGenerated $ length as
  putAgenda =<< flip (foldl' (flip H.insert)) as `liftM` agenda

popAgenda
  :: H.HeapItem p (w, Assignment v l w i)
  => KAStar p v l w i (Assignment v l w i)
popAgenda = do
  ((_, popped), agenda') <- (fromJust . H.view) `liftM` agenda
  putAgenda agenda'
  return popped
