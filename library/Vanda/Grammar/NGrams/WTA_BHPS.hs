-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.Grammar.NGrams.WTA_BHPS
-- Copyright   :  (c) Technische Universität Dresden 2013
-- License     :  BSD-style
--
-- Maintainer  :  Tobias.Denkinger@mailbox.tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
--
-- Queries an Automaton that represents an n-gram model. Assigns weights as
-- early as possible to enable early pruning.
--
-----------------------------------------------------------------------------


module Vanda.Grammar.NGrams.WTA_BHPS
  ( State'
  , delta
  , mapState
  , makeWTA
  ) where

import Data.Hashable
import Data.WTA
import Vanda.Grammar.LM
import qualified Data.Vector.Unboxed as VU

data State' v = Binary [v] [v] deriving (Eq, Ord, Show)

instance Hashable i => Hashable (State' i) where
  hashWithSalt s (Binary a b) = s `hashWithSalt` a `hashWithSalt` b

mapState' :: (v -> v') -> State' v -> State' v'
mapState' f (Binary b1 b2) = Binary (map f b1) (map f b2)

instance State State' where
  mapState = mapState'

instance Functor State' where
  fmap = mapState'

makeWTA
  :: LM a
  => a
  -> (Int -> Int)
  -> [Int]
  -> WTA Int (State' Int)
makeWTA lm rel gamma
  = WTA (delta' lm rel gamma) (const 1)

delta'
  :: LM a
  => a                      -- ^ language model
  -> (Int -> Int)           -- ^ relabelling
  -> [Int]                  -- ^ Gamma
  -> [State' Int]           -- ^ in-states
  -> [Int]                  -- ^ input symbol
  -> [(State' Int, Double)] -- ^ out-states with weights
delta' lm rel gamma [] w
  = let nM = order lm - 1
    in  [ (Binary w1 w2, score lm . VU.fromList $ map rel (w1 ++ w))
        | w1 <- sequence . take nM $ repeat gamma
        , let w2 = last' nM $ w1 ++ w
        ]
delta' _ _ _ xs _
  = let check _ [] = True
        check (Binary _ lr) (r@(Binary rl _):qs) = (lr == rl) && check r qs
        check' (q:qs) = check q qs
        check' _ = True
        lft = (\(Binary a _) -> a) $ head xs
        rgt = (\(Binary _ b) -> b) $ last xs
        q' = Binary lft rgt
    in  [ (q', 1) | check' xs ]

last' :: Int -> [v] -> [v]
last' n xs = drop (length xs - n) xs
