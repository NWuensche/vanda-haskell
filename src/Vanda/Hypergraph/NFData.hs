-- | Makes Hyperedge an instance of 'NFData' for strict evaluation.

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Vanda.Hypergraph.NFData () where

import Control.DeepSeq
import qualified Data.Vector as V
import qualified Data.Set as S

import Vanda.Hypergraph.Basic

instance (NFData v, NFData l, NFData i) => NFData (Hyperedge v l i) where
  rnf (Nullary t l i) = rnf t `seq` rnf l `seq` rnf i
  rnf (Unary t f1 l i) = rnf t `seq` rnf f1 `seq` rnf l `seq` rnf i
  rnf (Binary t f1 f2 l i)
    = rnf t `seq` rnf f1 `seq` rnf f2 `seq` rnf l `seq` rnf i
  rnf (Hyperedge t f l i)
    = rnf t `seq` rnf (V.toList f) `seq` rnf l `seq` rnf i

instance (NFData v, NFData l, NFData i) => NFData (EdgeList v l i) where
  rnf (EdgeList vs es) = rnf vs `seq` rnf es

instance (NFData v, NFData l, NFData i) => NFData (BackwardStar v l i) where
  rnf (BackwardStar vs b _) = rnf [ b v | v <- S.toList vs ]
  
{-instance (NFData v) => NFData (S.Set v) where
  rnf s = rnf $ S.toList s-}