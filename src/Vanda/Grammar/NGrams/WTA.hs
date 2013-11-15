-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.Grammar.NGrams.WTA
-- Copyright   :  (c) Technische Universität Dresden 2013
-- License     :  Redistribution and use in source and binary forms, with
--                or without modification, is ONLY permitted for teaching
--                purposes at Technische Universität Dresden AND IN
--                COORDINATION with the Chair of Foundations of Programming.
--
-- Maintainer  :  Tobias.Denkinger@mailbox.tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
--
-- Queries an Automaton that represents an n-gram model.
--
-----------------------------------------------------------------------------


module Vanda.Grammar.NGrams.WTA where

import Vanda.Grammar.LM
import Data.Hashable
import Data.List (foldl', intercalate)

data State v
  = Nullary
  | Unary  [v]
  | Binary [v] [v]
  deriving (Eq, Ord)

instance Hashable i => Hashable (State i) where
  hashWithSalt s Nullary = s
  hashWithSalt s (Unary a) = s `hashWithSalt` a
  hashWithSalt s (Binary a b) = s `hashWithSalt` a `hashWithSalt` b


mapState :: (v -> v') -> State v -> State v'
mapState _ Nullary
  = Nullary
mapState f (Unary b)
  = Unary (map f b)
mapState f (Binary b1 b2)
  = Binary (map f b1) (map f b2)

emptyState :: State v
emptyState = Nullary

state :: v -> State v
state v = Unary [v]

instance Show v => Show (State v) where
  show s
    = case s of
        Nullary -> ""
        Unary x -> intercalate "_" $ map show x
        Binary x y -> (intercalate "_" $ map show x) ++ "*" ++ (intercalate "_" $ map show y)

delta' :: LM a => (a -> [State Int] -> [Int] -> Double) -> a -> [State Int] -> [Int] -> [(State Int, Double)]
delta' f lm qs w = [(deltaS lm qs w, f lm qs w)]

-- | transition state
deltaS :: (Show v, LM a) => a -> [State v] -> [v] -> State v
deltaS lm [] yield
  = let nM = order lm - 1
    in  if   length yield < nM
        then Unary yield
        else Binary (take nM yield) (last' nM yield)
deltaS lm xs _
  = let go Nullary = []
        go (Unary x) = x
        go (Binary x y) = x ++ y
        str = concatMap go xs
        nM = order lm - 1
    in  if   length str < nM + 1
        then Unary str
        else Binary (take nM str) (last' nM str)

-- | Extracts the currently visible substrings from a 'List' of states.
extractSubstrings :: [State v] -> [[v]]
extractSubstrings xs
  = let go (rs, p) Nullary = (rs, p)
        go (rs, p) (Unary x) = (rs, p ++ x)
        go (rs, p) (Binary x y) = (rs ++ [p ++ x], y)
    in  (\ (rs, p) -> rs ++ [p]) $ foldl' go ([], []) xs

last' :: Int -> [v] -> [v]
last' n xs = drop (length xs - n) xs
