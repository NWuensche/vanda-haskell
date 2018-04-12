-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) Sebastian Mielke 2015
-- License     :  BSD-style
--
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

module Vanda.Grammar.XRS.LCFRS.Evaluation
( sententialFront
, retranslateRule
, getDerivProbability
) where

import           Control.Monad (join)
import qualified Data.Array as A
import qualified Data.Vector as V

import           Data.NTT
import           Vanda.Hypergraph.IntHypergraph
import qualified Vanda.Hypergraph.Tree as VT

import           Vanda.Grammar.XRS.LCFRS

-- (crisp) RETRANSLATION from rules and derivations

translateNTTString
  :: (A.Array NTIdent String) -- ^ NTs
  -> (A.Array TIdent String) -- ^ Ts
  -> NTT
  -> String
translateNTTString a_nt _ (NT i) = a_nt A.! i
translateNTTString _ a_t (T i) = a_t A.! i

sententialFront
  :: MIRTG
  -> (A.Array NTIdent String) -- ^ NTs
  -> (A.Array TIdent String) -- ^ Ts
  -> Derivation Int Int
  -> V.Vector String -- a sentence (terminal symbol sequence)
sententialFront (MIRTG hg _ h') a_nt a_t dt
  | not $ and $ fmap (`elem` (edges hg)) dt
    = error "Not all rules are in the IRTG!"
  {- For testing: print other symbols, too. See hint below.
  | not $ ((to $ VT.rootLabel dt) `elem` initials)
    = error "Not starting with a start symbol!"
  | not $ V.length (h' V.! (to $ VT.rootLabel dt)) == 1
    = error "Start symbol has a fan-out /= 1"
  -}
  | otherwise
    -- Hint: the 'join' ignores the fan-out/tuple structure since
    -- we assume an output fan-out of 1
    = fmap (translateNTTString a_nt a_t) $ join $ getSpans h' dt

getSpans
  :: V.Vector (V.Vector (V.Vector CompFuncEntry)) -- ^ homomorphism, see above def.
  -> Derivation Int Int -- ^ hyperedge tree
  -> V.Vector (V.Vector NTT) -- ^ Terminal vectors, should only contain Ts
getSpans h' dt = fmap (join . fmap evalNT) preResult
  where
    he = VT.rootLabel dt
    preResult = (V.!) h' . label $ he
    -- ^ This already has the result type, but contains variables
    childSpans = V.concat $ map (getSpans h') $ VT.subForest dt
    evalNT t@(T _) = V.singleton t
    evalNT (NT x) = childSpans V.! x

retranslateRule
  :: (A.Array NTIdent String)
  -> (A.Array TIdent String)
  -> Rule -- ^ a rule
  -> String
retranslateRule a_nt a_t ((lhs, rhs), hom_f)
  =  (cut 8 $ (A.!) a_nt lhs)
  ++ " -> "
  ++ (cut 100 $ show $ map ((A.!) a_nt) rhs)
  ++ " // "
  ++ (show $ map (map retHomComponent) hom_f)
    where
      retHomComponent (T t) = (A.!) a_t t
      retHomComponent (NT v) = show v
      cut n = take n . (++ repeat ' ')

-- PROBABILISTIC foo

getDerivProbability
  :: MXRS
  -> Derivation Int Int
  -> Double
getDerivProbability (MXRS (MIRTG _ _ _) w)
  = product . flatten . fmap ((V.!) w . ident)
  where flatten = foldMap (:[])
