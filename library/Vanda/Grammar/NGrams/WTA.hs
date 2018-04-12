-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.Grammar.NGrams.WTA
-- Copyright   :  (c) Technische Universität Dresden 2013
-- License     :  BSD-style
--
-- Maintainer  :  Tobias.Denkinger@mailbox.tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
--
-- Queries an Automaton that represents an n-gram model.
--
-----------------------------------------------------------------------------

module Vanda.Grammar.NGrams.WTA
  ( State'
  , delta
  , nu
  , mapState
  , smoothedWTA
  , unsmoothedWTA
  ) where

import Data.List (foldl', intercalate)
import Data.Hashable
import Data.WTA
import Vanda.Grammar.LM
import qualified Data.Vector.Unboxed as VU

data State' v
  = Unary  [v]
  | Binary [v] [v]
  deriving (Eq, Ord)

instance Hashable i => Hashable (State' i) where
  hashWithSalt s (Unary a) = s `hashWithSalt` a
  hashWithSalt s (Binary a b) = s `hashWithSalt` a `hashWithSalt` b

instance Show v => Show (State' v) where
  show s
    = case s of
        Unary x -> intercalate "_" $ map show x
        Binary x y -> intercalate "_" (map show x)
                   ++ "*"
                   ++ intercalate "_" (map show y)

mapState' :: (v -> v') -> State' v -> State' v'
mapState' f (Unary b)      = Unary (map f b)
mapState' f (Binary b1 b2) = Binary (map f b1) (map f b2)

instance State State' where
  mapState = mapState'

instance Functor State' where
  fmap = mapState'

smoothedWTA :: LM a => (Int -> Int) -> a -> WTA Int (State' Int)
smoothedWTA rel lm = WTA (delta' (deltaW' rel) lm) (nuW' rel lm)

unsmoothedWTA :: LM a => (Int -> Int) -> a -> WTA Int (State' Int)
unsmoothedWTA rel lm = WTA (delta' (deltaW rel) lm) (nuW rel lm)

nuW :: LM a => (Int -> Int) -> a -> State' Int -> Double
nuW rel lm (Binary a b)
  = score lm (VU.fromList (flip (++) (map rel a) . replicate (order lm - 1) $ startSymbol lm))
  + score lm (VU.fromList (map rel b ++ [endSymbol lm]))
nuW rel lm (Unary a)
  = score lm (VU.fromList ( replicate (order lm - 1) (startSymbol lm)
                            ++ map rel a
                            ++ [endSymbol lm]
                          ))

-- | helper for transition weights (calculates intermediate
--   values using backoff and cancels them out later)
deltaW :: LM a => (Int -> Int) -> a -> [State' Int] -> [Int] -> Double
deltaW rel lm [] w
  = score lm . VU.fromList $ map rel w
deltaW rel lm xs _
  = sum . map (score lm . VU.fromList . map rel)
        . filter (\x -> length x >= order lm)
        $ extractSubstrings xs

nuW' :: LM a => (Int -> Int) -> a -> State' Int -> Double
nuW' rel lm (Binary a b)
  = nuW rel lm (Binary a b)
nuW' rel lm (Unary a)
  = nuW rel lm (Unary a) - score lm (VU.fromList $ map rel a)

-- | helper for transition weights (calculates intermediate
--   values using backoff and cancels them out later)
deltaW' :: LM a => (Int -> Int) -> a -> [State' Int] -> [Int] -> Double
deltaW' rel lm [] w
  = deltaW rel lm [] w
deltaW' rel lm xs _
  = (sum . map (score lm . VU.fromList . map rel)
         . extractSubstrings
         $ xs
    )
  - (sum . map (score lm . VU.fromList . map rel . (\ (Unary x) -> x ))
         . filter (\ x -> case x of
                            (Unary _) -> True
                            _         -> False
                  )
         $ xs
    )

delta'
  :: LM a
  => (a -> [State' Int] -> [Int] -> Double)
  -> a
  -> [State' Int]
  -> [Int]
  -> [(State' Int, Double)]
delta' f lm qs w = [(deltaS lm qs w, f lm qs w)]

-- | transition state
deltaS :: LM a => a -> [State' v] -> [v] -> State' v
deltaS lm [] w
  = let n = order lm - 1
    in  if   length w < n
        then Unary w
        else Binary (take n w) (last' n w)
deltaS lm xs _
  = let go (Unary x) = x
        go (Binary x y) = x ++ y
        str = concatMap go xs
        nM = order lm - 1
    in  if   length str < nM + 1
        then Unary str
        else Binary (take nM str) (last' nM str)

-- | Extracts the currently visible substrings from a 'List' of states.
extractSubstrings :: [State' v] -> [[v]]
extractSubstrings xs
  = let go (rs, p) (Unary x) = (rs, p ++ x)
        go (rs, p) (Binary x y) = (rs ++ [p ++ x], y)
    in  (\ (rs, p) -> rs ++ [p]) $ foldl' go ([], []) xs

last' :: Int -> [v] -> [v]
last' n xs = drop (length xs - n) xs
