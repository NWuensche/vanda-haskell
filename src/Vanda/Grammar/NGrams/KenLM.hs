-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.Grammar.NGrams.KenLM
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
-- Uses the C library KenLM from <http://kheafield.com/code/kenlm/> to load
-- APRA files and score sentences.
--
-----------------------------------------------------------------------------

{-# LANGUAGE ForeignFunctionInterface #-}

module Vanda.Grammar.NGrams.KenLM
  ( -- * Types
    KenLM
  , KenLMState
    -- * Loading models
  , loadNGrams
    -- * Constants
  , beginSentenceState
  , nullContextState
    -- * Scoring
  , evaluate
  , evaluateLine
  ) where

import qualified Data.Text.Lazy as T
import qualified Data.List as L
import Foreign.C
import Foreign.Ptr
import System.IO.Unsafe
import Data.Array.Storable

data KenTrieModel = KenTrieModel
data State = State

type KenLM = Ptr KenTrieModel
type KenLMState = Ptr State

foreign import ccall "loadModel" cLoadNGrams
                 :: CString -> IO (Ptr KenTrieModel)

foreign import ccall "order" cOrder
                 :: KenLM -> CInt

foreign import ccall "index" cIndex
                 :: KenLM -> CString -> IO CInt

foreign import ccall "beginSentenceState" cBeginSentenceState
                 :: KenLM -> KenLMState

foreign import ccall "nullContextState" cNullContextState
                 :: KenLM -> KenLMState

foreign import ccall "lookup" cLookup
                 :: KenLM -> KenLMState -> CString -> IO CFloat

foreign import ccall "lookupInt" cLookupInt
                 :: KenLM -> KenLMState -> Ptr CInt -> CInt -> IO CFloat

foreign import ccall "score" cEvaluateLine
                 :: KenLM -> CString -> IO CFloat

foreign import ccall "scoreInt" cEvaluateLineInt
                 :: KenLM -> Ptr CInt -> CInt -> IO CFloat

-- | Loads a KenTrieModel from a binary ARPA file containing a TrieModel OR
-- a textual ARPA file.
loadNGrams
  :: FilePath                  -- ^ file name
  -> KenLM                     -- ^ model
loadNGrams s
  = unsafePerformIO $ withCString s cLoadNGrams

dictIndex
  :: KenLM
  -> T.Text
  -> Int
dictIndex m t
  = unsafePerformIO
  $ withCString
      (T.unpack t)
      (fmap fromIntegral . cIndex m) 

-- | Returns the State to use when at the beginning of a sentence.
beginSentenceState
  :: KenLM                     -- ^ model
  -> KenLMState                -- ^ 'State' for the beginning of a sentence
beginSentenceState
  = cBeginSentenceState

-- | Returns the State to use when there is no context.
nullContextState
  :: KenLM                     -- ^ model
  -> KenLMState                -- ^ 'State' for empty context
nullContextState
  = cNullContextState

-- | Scores a phrase beginning with a 'State'.
evaluate
  :: KenLM                     -- ^ model
  -> KenLMState                -- ^ 'State' to start with
  -> T.Text                    -- ^ phrase to score
  -> Float                     -- ^ score
evaluate m s t
  = unsafePerformIO
  $ withCString
      (T.unpack t)
      (fmap realToFrac . cLookup m s)

evaluateInt
  :: KenLM                     -- ^ model
  -> KenLMState                -- ^ 'State' to start with
  -> [Int]                     -- ^ phrase to score
  -> Float                     -- ^ score
evaluateInt m s is
  = unsafePerformIO
  $ do a <- newListArray
              (1, L.length is)
              (L.map fromIntegral is)
       withStorableArray a
         (\p -> fmap realToFrac . cLookupInt m s p . fromIntegral . L.length $ is)

-- | Scores a whole sentence.
evaluateLine
  :: KenLM                     -- ^ model
  -> T.Text                    -- ^ sentence to score
  -> Float                     -- ^ score
evaluateLine m s
  = unsafePerformIO
  $ withCString
      (T.unpack s)
      (fmap realToFrac . cEvaluateLine m)

order :: KenLM -> Int
order = fromIntegral . cOrder
