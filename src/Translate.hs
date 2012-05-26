module Main where 

import Data.Either
import Data.Maybe
import qualified Data.List as L
import qualified Data.Set as S
import Data.Tree as T
import qualified Data.Map as M
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import qualified Data.Ix as Ix
import qualified Data.Binary as B
import qualified Data.ByteString.Lazy as B
import Codec.Compression.GZip ( decompress )
import Data.Int ( Int32 )
import Debug.Trace
import Control.DeepSeq
import qualified Data.Text.Lazy as TIO
import qualified Data.Text.Lazy.IO as TIO
import System.Environment ( getArgs, getProgName )


import qualified Vanda.Algorithms.EarleyCFG as E
import qualified Vanda.Algorithms.Earley.WSA as WSA
import Vanda.Hypergraph.BackwardStar (fromEdgeList)
import Vanda.Features
import Vanda.Token
import Vanda.Hypergraph
import Vanda.Hypergraph.Binary ()
-- import Vanda.Hypergraph.NFData ()
import Vanda.Token


instance NFData (BackwardStar Token ([Either Int Token], [Either Int Token]) Int) where
  rnf (BackwardStar nodes edges memo) 
    = (rnf nodes `seq` rnf edges) `seq` rnf memo 

instance (Show v, Show i, Show l, Show x) => Show (Candidate v l i x) where 
  show c
    = "Gewicht: " ++ (show $ weight c) ++ "\n Ableitung: "
      ++ (show $ deriv c) ++ "\fdata: "
      ++ (show $ fdata c)
  
instance (Show v, Show i, Show l, Ord v) => Show (EdgeList v l i) where 
  show g 
    = show (S.toList $ nodesEL g) ++ "\n" ++ unlines (map show (edgesEL g))
    

loadSCFG
  :: String
  -> IO (BackwardStar String ([Either Int String], [Either Int String]) Int)
loadSCFG file
  = fmap (fromEdgeList . B.decode . decompress) $ B.readFile file

loadWeights :: String -> IO (VU.Vector Double)
loadWeights file
  = fmap (VU.fromList . B.decode . decompress) $ B.readFile file
  
loadText :: String -> IO String
loadText file
  = fmap (TIO.unpack . head . TIO.lines) $ TIO.readFile file

saveText :: String -> String -> IO ()
saveText text file = TIO.writeFile file (TIO.pack text)

toWSA :: String -> WSA.WSA Int String Double 
toWSA input = WSA.fromList 1 (L.words input)

{-
fakeWeights
  :: Hypergraph h 
  => h Token ([Either Int Token], [Either Int Token]) Int 
  -> M.Map Int Double
fakeWeights hg 
  = M.fromList $ zip (map ident $ edgesEL $ toEdgeList hg) (repeat 1)
-}

makeFeature nweights
  = (Feature pN V.singleton, V.singleton 1.0)
  where
    pN _ !i xs = (nweights VU.! fromIntegral (snd i)) * Prelude.product xs

getInitial hg = S.findMin (nodes hg)

newInitial v0 text = (0, v0, length (L.words text)) 

candToString
  :: (Show l, Show v, Show i)
  => (l -> [Either Int String])
  -> Derivation v l i
  -> String
candToString component cand
  = L.unwords
  . map (either ((map (candToString component) (T.subForest cand)) !!) id)
  . component
  . label
  . T.rootLabel
  $ cand

makeString
  :: (Ord p, Ord v, Show v, Show i, Show p, Show l)
  => M.Map (p, v, p)  [Candidate (p, v, p) l i Double] 
  -> (p, v, p)
  -> (l -> [Either Int String])
  -> String
makeString best nv0 component 
  = case M.lookup nv0 best of
      Nothing -> "(No translation.)"
      Just [] -> "(No translation.)"
      Just (c : _) -> trace (T.drawTree $ fmap show $ deriv c) $ candToString component (deriv c)


doTranslate hg input = output where
  -- weights = fakeWeights hg
  wsa = toWSA input -- :: WSA Int  l v 
  v0 = getInitial hg
  (nhg, nweights) = E.earley hg fst wsa v0
  (feat, featvec) = makeFeature nweights
  best = knuth nhg feat featvec
  nv0 = newInitial v0 input
  output = makeString best nv0 snd ++ "\n" ++ makeString best nv0 fst ++ "\n"


main :: IO ()
main = do
  progName <- getProgName
  args <- getArgs
  case args of
    ["-g", graph, "-s", inFile, "-t", outFile] -> do
      hg <- loadSCFG graph
      -- weights <- loadWeights
      input <- loadText inFile
      let output = doTranslate hg input
      saveText output outFile
    _ -> print $ "Usage: " ++ progName ++ "-g graphfile -t tokenfile -s sentence"
