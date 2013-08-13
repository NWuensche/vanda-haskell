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


module Vanda.Grammar.NGrams.WTA 
  ( deltaS
  , deltaW
  , NState (Unary, Binary)
  ) where

import Vanda.Grammar.LM
import Data.Hashable
import Data.List (foldl',intercalate)

data NState v
  = Unary  [v]
  | Binary [v] [v]
  deriving (Eq, Ord)

instance Hashable i => Hashable (NState i) where
  hashWithSalt s (Unary a) = s `hashWithSalt` a
  hashWithSalt s (Binary a b) = s `hashWithSalt` a `hashWithSalt` b

instance Show v => Show (NState v) where
  show (Unary x)
    = intercalate "_" . map show $ x
  show (Binary x y)
    = (intercalate "_" . map show $ x) ++ "*" ++ (intercalate "_" . map show $ y) 

-- | transition state
deltaS :: LM a => a -> [NState v] -> [v] -> NState v
deltaS lm [] yield
  = if   order lm <= 1
    then Unary yield
    else Binary yield yield
deltaS lm xs _
  = let go (Unary x) = x
        go (Binary x y) = x ++ y
        str = concatMap go xs
        n = order lm
    in  if   length str < order lm
        then Unary str
        else Binary (take (n - 1) str) (last' (n-1) str)

-- | transition weight without backoff
--deltaW1 :: LM a => a -> [NState Int] -> [Int] -> Double
--deltaW1 _ [] _
--  = 1
--deltaW1 lm xs _
--  = sum . map (score lm) . filter (\ x -> length x >= order lm) . extractSubstrings $ xs

-- | helper for transition weights (calculates intermediate
--   values using backoff and cancels them out later)
deltaW :: LM a => a -> [NState Int] -> [Int] -> Double
deltaW lm [] yield
  = score lm yield
deltaW lm xs _
  = (sum . map (score lm)
         . extractSubstrings
         $ xs
    )
  - (sum . map (score lm)
         . map (\ (Unary x) -> x )
         . filter (\ x -> case x of
                            (Unary _)    -> True
                            (Binary _ _) -> False
                  )
         $ xs
    )

extractSubstrings :: [NState v] -> [[v]]
extractSubstrings xs
  = let go (rs, p) (Unary x) = (rs, p ++ x)
        go (rs, p) (Binary x y) = (rs ++ [(p ++ x)], y)
    in  (\ (rs, p) -> rs ++ [p]) . foldl' go ([], []) $ xs

last' :: Int -> [v] -> [v]
last' n xs = drop ((length xs) - n) xs
