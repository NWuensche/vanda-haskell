-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) Johannes Osterholzer
-- License     :  BSD-style
--
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

{-# LANGUAGE FlexibleContexts #-}

module Algorithms.KAStar
  (
    kbest
  , kworst
  )
  where

import Control.Monad
import qualified Data.Map as M
import qualified Data.Tree as T
import qualified Data.Heap as H
import Data.List (foldl')
import Data.Maybe (mapMaybe)

import Data.Hypergraph

import Algorithms.KAStar.State
import Algorithms.KAStar.Data

------------------------------------------------------------------------------
-- Deduction rules -----------------------------------------------------------
------------------------------------------------------------------------------

-- | Create the initial assignments together with their priorities to be put
--   on the agenda
initialAssignments
  :: (Num w, Ord v, Eq l, Eq i)
  => KAStar p v l w i [(w, Assignment v l w i)]
initialAssignments = do
  g <- graph
  h <- heuristic
  return $ map (ins h) . filter ((==0) . length . eTail)
      . concat . M.elems . edgesM $ g
    where ins h e = let w = eWeight e
                        p = w * (h . eHead $ e)
                    in (p, Inside (I . eHead $ e) w)


-- | Create those new prioritized assignments to be put on the agenda that
--   are using the last popped assignment, the /trigger/.
newAssignments
  :: (Num w, Ord v, Ord l, Ord w, Ord i)
  => Assignment v l w i
  -> KAStar p v l w i [(w, Assignment v l w i)]
newAssignments trigger = do
  h   <- heuristic
  g   <- goal
  c   <- chart
  is  <- inEdges $ node trigger
  os  <- otherEdges $ node trigger
  inE <- inEdgesMap
  return $ case trigger of
             (Inside  _ _) -> switchRule c g trigger
                              ++ ins c h trigger is
                              ++ outs c trigger os
             (Outside _ _) -> outs c trigger os
                              ++ builds c trigger inE os
             (Ranked  _ _) -> builds c trigger inE os
    where
      ins c h trig        = concatMap (inRule c h trig)
      outs c trig         = concatMap (outRule c trig)
      builds c trig is os = concatMap (buildRuleO c trig) os
                            ++ buildRuleL c trig is
                            ++ buildRuleR c trig


-- | The Switch-rule generates the initial outside item for the goal node @g@,
--   triggered by an inside assignment for @g@.
switchRule
  :: (Num w, Ord v, Eq l, Eq i)
  => Chart v l w i
  -> v
  -> Assignment v l w i
  -> [(w, Assignment v l w i)]
switchRule _ g trigger = do
  guard $ isInside trigger && node trigger == g
--  ig <- insideAssignments c g
  return $! (weight trigger, Outside (O g) 1)


-- | The In-rule generates a new inside assignment from the inside assignments
--   for its tail nodes. Only triggered by an inside assignment.
inRule
  :: (Num w, Ord v, Eq l, Eq i)
  => Chart v l w i
  -> (v -> w)
  -> Assignment v l w i
  -> (Hyperedge v l w i, Int)
  -> [(w, Assignment v l w i)]
inRule c h trigger (e, r) = do
        ibsl <- mapM (insideAssignments c) . take r $ eTail e
        ibsr <- mapM (insideAssignments c) . drop (r + 1) $ eTail e
        let ibs = ibsl ++ [trigger] ++ ibsr
            w   = eWeight e * (product . map weight $ ibs)
            p   = h (eHead e) * w
        return $! (p, Inside (I (eHead e)) w)


-- | The Out-rule generates a new outside assignment from a list of inside
--   asssignments and an outside assignment. Triggered by an outside or inside
--   assignment.
outRule
  :: (Num w, Ord v, Eq l, Eq i)
  => Chart v l w i
  -> Assignment v l w i
  -> (Hyperedge v l w i, Int)
  -> [(w, Assignment v l w i)]
outRule c trigger (e, r) = do
  (oa, ibs) <- if r == 0
               then do
                 guard $ isOutside trigger
                 liftM2 (,) [trigger] (mapM (insideAssignments c) (eTail e))
               else do
                 guard $ isInside trigger
                 ibsl <- mapM (insideAssignments c) . take (r - 1) $ eTail e
                 ibsr <- mapM (insideAssignments c) . drop r $ eTail e
                 liftM2 (,) (outsideAssignments c $ eHead e)
                            [ibsl ++ [trigger] ++ ibsr]
  i <- [0 .. (length ibs - 1)]
  let w = eWeight e * weight oa
          * (product . map weight $ take i ibs) -- drop i-th element
          * (product . map weight $ drop (i + 1) ibs)
      p = w * weight (ibs !! i)
  return $! (p, Outside (O (eTail e !! i)) w)

-- | Checks whether the nodes of the supplied assignments are compatible
--   with the tail nodes of the supplied hyperedge.
--   May be removed later.
assert :: Eq v => [Assignment v l w i] -> Hyperedge v l w i -> Bool
assert as e = and (zipWith f as $ eTail e) && length as == length (eTail e)
  where f a v = node a == v

-- | buildRuleO is either triggered by an outside assignment for node @v@. We
--   then find all edges with @v@ as head node and combine the 1-best
--   derivations of their tail nodes.
--   Or it is triggered by a ranked derivation assignment. Then we combine
--   this item along all hyperedges in question with the 1-best derivations
--   of the edge's tail nodes.
buildRuleO
  :: (Num w, Ord v, Eq l, Eq i)
  => Chart v l w i
  -> Assignment v l w i
  -> (Hyperedge v l w i, Int)
  -> [(w, Assignment v l w i)]
buildRuleO c trigger@(Outside _ _) (e, 0) = do
  as <- mapM (flip (nthRankedAssignment c) 1) (eTail e)
  unless (assert as e) (error "error in buildRuleO") --TODO:remove
  let w   = eWeight e * (product . map weight $ as)
      p   = w * weight trigger
      bps = map rank as
  return $! (p, Ranked (K (eHead e) e 0 bps) w)
buildRuleO c trigger@(Ranked _ _) (e, r) = do
  guard $ r /= 0 && rank trigger == 1
  oa  <- outsideAssignments c $ eHead e
  asl <- zipWithM (nthRankedAssignment c) (take (r - 1) $ eTail e) (repeat 1)
  asr <- zipWithM (nthRankedAssignment c) (drop r $ eTail e) (repeat 1)
  let as  = asl ++ [trigger] ++ asr
      w   = eWeight e * (product . map weight $ as)
      p   = w * weight oa
      bps = map rank as
  unless (assert as e) (error "error in buildRuleO") --TODO:remove
  return $! (p, Ranked (K (eHead e) e 0 bps) w)
buildRuleO _ _ _ = []


-- | buildRuleL is triggered by an @r@-ranked derivation assignment for node
--   @v@. We find all assignments with @(r-1)@-backpointers to @v@ and
--   combine them with the trigger.
buildRuleL
  :: (Num w, Ord v, Ord l, Ord w, Ord i)
  => Chart v l w i
  -> Assignment v l w i
  -> M.Map v [(Hyperedge v l w i, Int)]
  -> [(w, Assignment v l w i)]
buildRuleL c trigger@(Ranked _ _) ie
  = concatMap rule (M.findWithDefault [] (node trigger) ie)
  where
    rule (e, s) = do
      Ranked (K _ e' _ bps) _ <- rankedWithBackpointer c e (s+1) (rank trigger - 1)
      unless (eqHyperedges e e' && bps !! s == rank trigger - 1) $
        error "error with rankedWithBackpointer in buildRuleL" --TODO: remove
      asl <- take s `liftM` zipWithM (nthRankedAssignment c) (eTail e) bps
      asr <- drop (s+1) `liftM` zipWithM (nthRankedAssignment c) (eTail e) bps
      oa  <- outsideAssignments c (eHead e)
      let as = asl ++ [trigger] ++ asr
          w  = eWeight e * (product . map weight $ as)
          p  = w * weight oa
          bp = map rank as
      unless (assert as e) (error "error in buildRuleL") --TODO: remove
      return $! (p, Ranked (K (eHead e) e 0 bp) w)
buildRuleL _ _ _ = []

-- | buildRuleR is triggered by a ranked derivation assignment for node @v@
--   with backpointers @bps@. We decide for all of those backpointers if the
--   next-best ranked assignment was inserted and return the newly generated
--   assignments.
buildRuleR
  :: (Num w, Ord v, Eq l, Eq i)
  => Chart v l w i
  -> Assignment v l w i
  -> [(w, Assignment v l w i)]
buildRuleR c (Ranked (K _ e _ bps) _) = do
  r <- [1 .. length bps]
  let bps' = zipWith (+) bps (unit (length bps) r)
  as <- zipWithM (nthRankedAssignment c) (eTail e) bps'
  oa <- outsideAssignments c (eHead e)
  unless (assert as e) (error "error in buildRuleO") --TODO: remove
  let w = eWeight e * (product . map weight $ as)
      p = w * weight oa
  return $! (p, Ranked (K (eHead e) e 0 bps') w)
  where
    -- r-th unit vector of dimension n
    unit n r = replicate (r - 1) 0 ++ [1] ++ replicate (n - r) 0
buildRuleR _ _ = []


------------------------------------------------------------------------------
-- KAStar --------------------------------------------------------------------
------------------------------------------------------------------------------

-- | @kbest graph g h k@ finds the @k@ best derivations of the goal
-- node @g@ in @graph@, applying the heuristic function @h@.
-- /Watch out:/ Hyperedge IDs need to be unique for KA* to work as intended!
kbest
  :: (Num w, Ord v, Ord w, Ord l, Ord i)
  => Hypergraph v l w i
  -> v
  -> (v -> w)
  -> Int
  -> [(T.Tree (Hyperedge v l w i), w)]
kbest = kastar (H.empty :: H.MaxPrioHeap w (Assignment v l w i))


-- | @kworst graph g h k@ finds the @k@ worst derivations of the goal
-- node @g@ in @graph@, applying the heuristic function @h@.
-- /Watch out:/ Hyperedge IDs need to be unique for KA* to work as intended!
kworst
  :: (Num w, Ord v, Ord w, Ord l, Ord i)
  => Hypergraph v l w i
  -> v
  -> (v -> w)
  -> Int
  -> [(T.Tree (Hyperedge v l w i), w)]
kworst = kastar (H.empty :: H.MinPrioHeap w (Assignment v l w i))


-- | @kastar agenda graph g h k@ finds the @k@ best derivations of the goal
-- node @g@ in @graph@, applying the heuristic function @h@. "Best" thereby
-- means best with respect to the order induced by the @agenda@.
-- /Watch out:/ Hyperedge IDs need to be unique for KA* to work as intended!
kastar
  :: (Num w, Ord v, Ord w, Ord l, Ord i, H.HeapItem p (w, Assignment v l w i))
  => Agenda p v l w i
  -> Hypergraph v l w i
  -> v
  -> (v -> w)
  -> Int
  -> [(T.Tree (Hyperedge v l w i), w)]
kastar a gr g h k
  = --trace ("Inserted " ++ (show . stItemsInserted $ info)
    --  ++ " assignments, generated " ++ (show . stItemsGenerated $ info)
    --  ++ "assignments.\n") $
    reverse . mapMaybe (traceBackpointers res) $ rankedAssignments res g
  where (res, _)      = runKAStar kst a k gr g h ins others
        (ins, others) = edgesForward gr
        kst = do
          agendaInsert =<< initialAssignments
          loop
        loop = do
          m <- process  -- try to pop new assignment
          case m of
            Nothing        -> chart  -- we're done, return the chart
            (Just trigger) -> (agendaInsert =<< newAssignments trigger)
                              >> loop -- generate new assignments and continue

-- | @process@ pops assignments until
--
--   (1) there are none left or we have found the necessary number of
--       derivations of @g@, returning @Nothing@ /or/
--
--   (2) the popped assignment is not contained in the chart. In this case,
--       it is inserted and returned with its according rank.
process
  :: (Ord v, Ord w, Ord i, Ord l, H.HeapItem p (w, Assignment v l w i))
  => KAStar p v l w i (Maybe (Assignment v l w i))
process = do
  d <- done
  if d then return Nothing
       else do -- agenda != empty
         popped <- popAgenda
         trigger <- chartInsert popped
         case trigger of
           Nothing -> process
           _       -> return trigger
  where done = do
          e <- H.isEmpty `liftM` agenda
          l <- liftM2 numRanked chart goal
          k <- numDeriv
          return $ e || l >= k


------------------------------------------------------------------------------
-- Helper functions ----------------------------------------------------------
------------------------------------------------------------------------------

-- | Computes data structures for efficient association of tail nodes with
--   their respective hyperedges.
edgesForward
  :: Ord v
  => Hypergraph v l w i
  -> ( M.Map v [(Hyperedge v l w i, Int)]
     , M.Map v [(Hyperedge v l w i, Int)])
edgesForward gr = (compute ins, compute others)
  where
    compute f = foldl' (\m (a, b) -> M.insertWith' (++) a b m) M.empty
                . concatMap f $ es
    ins e = [(eTail e !! i, [(e, i)]) | i <- [0 .. pred . length . eTail $ e]]
    others e = (eHead e, [(e, 0)])
               : [(eTail e !! i, [(e, i + 1)])
                    | i <- [0 .. pred . length . eTail $ e]]
    es = concat . M.elems . edgesM $ gr


-- | @traceBackpointers chart a@ reconstructs a derivation from the backpointers
--   contained in the ranked derivation assignment @a@. If @a@ is not such an
--   assignment, it returns @Nothing@.
traceBackpointers
  :: Ord v
  => Chart v l w i
  -> Assignment v l w i
  -> Maybe (T.Tree (Hyperedge v l w i), w)
traceBackpointers c a@(Ranked _  w) = do
  t <- helper a
  return (t, w)
  where helper (Ranked (K _ e _ bps) _) = T.Node e `fmap` mapM
          (\(rk, idx) -> helper . head $ nthRankedAssignment c (eTail e !! idx) rk)
          (zip bps [0..])
        helper _ = Nothing
traceBackpointers _ _ = Nothing


