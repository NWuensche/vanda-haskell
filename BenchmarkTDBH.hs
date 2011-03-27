-- Copyright (c) 2011, Toni Dietze

module Main where

import qualified Algorithms.NBest as NB
import qualified Data.WTA as WTA
import qualified Data.WSA as WSA
import Data.Hypergraph
import qualified Parser.Negra as Negra
import qualified RuleExtraction as RE
import qualified StateSplit as SPG
import qualified WTABarHillelTopDown as BH
import Tools.Miscellaneous (mapFst)
import Data.List (nub)

import TestData.TestWTA

import qualified Data.Map as M
import qualified Data.Tree as T
import Text.Parsec.String (parseFromFile)
import qualified Random as R
import System(getArgs)
import System.IO.Unsafe

main = do
  args <- getArgs
  case head args of
    "print" -> printFileHG (tail args)
    "train" -> train (tail args)
    "test" -> test (tail args)
    "convert" -> convert (tail args)


printFileHG [hgFile]
  = readFile hgFile
  >>= putStrLn . drawHypergraph . (read :: String -> Hypergraph (String, Int) String Double ())

getData
  = parseFromFile
      Negra.p_negra
      "Parser/tiger_release_aug07_notable_2000_utf-8.export"


train args = do
  let its = read (args !! 0)
  let exs = read (args !! 1)
  Right dta <- getData
  let ts = take exs $ negrasToTrees dta
  let trains = map onlyPreterminals ts
  let exPretermToTerm = mapIds (const []) $ SPG.initialize $ RE.extractHypergraph $ concatMap terminalBranches ts
  let gsgens
        = take (its + 1)
        $ SPG.train'
            trains
            "ROOT"
            (RE.extractHypergraph trains :: Hypergraph String String Double ())
            (R.mkStdGen 0)
  flip mapM_ (zip [0 ..] gsgens) $ \ (n, (g, _)) -> do
    writeFile ("hg_" ++ show exs ++ "_" ++ show n ++ ".txt") (show $ mapIds (const ()) g)
    writeFile ("hg_" ++ show exs ++ "_" ++ show n ++ "_withTerminals.txt")
      $ show
      $ mapIds (const ())
      $ hypergraph
          (  filter (null . eTail) (edges exPretermToTerm)
          ++ concatMap (extendEdge (edgesM exPretermToTerm)) (edges g)
          )
  where
    terminalBranches t@(T.Node _ [T.Node _ []]) = [t]
    terminalBranches (T.Node _ ts) = concatMap terminalBranches ts
    extendEdge eM e
      = if null (eTail e)
        then
          case M.lookup (fst $ eHead e, 0) eM of
            Nothing -> [e]
            Just es -> map (eMapWeight (eWeight e *) . eMapHead (const $ eHead e)) es
        else [e]


test args = do
  let hgFile = args !! 0
  let treeIndex = read $ args !! 1 :: Int
  let f = if args !! 2 == "p" then onlyPreterminals else id
  g <-  fmap (read :: String -> Hypergraph (String, Int) String Double ())
    $   readFile hgFile
  -- putStrLn $ drawHypergraph g
  Right dta <- getData
  let ts = {-filter ((< 15) . length . yield) $-} drop treeIndex $ map f (negrasToTrees dta)
  let wta = WTA.fromHypergraph ("ROOT", 0) g
  flip mapM_ ts $ \ t -> do
    let target' = (0, ("ROOT", 0), length $ yield t)
    let (_, g') = mapAccumIds (\ i _ -> {-i `seq`-} (i + 1, i)) (0 :: Int)
                $ dropUnreachables target'
                $ WTA.toHypergraph
                $ BH.intersect (WSA.fromList 1 $ yield t) wta
    let wta' = WTA.fromHypergraph target' g'
    let ts' = take 3
            $ filter ((t ==) . fst)
            $ filter ((0 /= ) . snd)
            $ map ( \ t' -> (t', WTA.weightTree wta' t'))
            $ nub
            $ filter (\ (T.Node r _) -> r == "ROOT")
            $ take 10000
            $ WTA.generate
            $ wta'
    let nbHg = hgToNBestHg g'
    let ts''  = map (mapFst (idTreeToLabelTree g' . hPathToTree) . pairToTuple)
              $ NB.best' nbHg target' 3
    print $ yield t
    -- putStrLn $ WTA.showWTA $ wta'
    if null (vertices g')
      then putStrLn "---!!! no parse !!!---"
      else do
        putStrLn $ T.drawTree t
        flip mapM_ ts'' $ \ (t', w) -> do
          putStr "Weight: "
          print $ w
          putStrLn $ T.drawTree t'
    putStrLn (replicate 80 '=')


convert args = do
  let hgFile = args !! 0
  g <-  fmap (mapIds (const ()) . (read :: String -> Hypergraph (String, Int) String Double [Int]))
    $   readFile hgFile
  let gRev = mapTails reverse g
  let hgFile' = reverse . drop 4  . reverse $ hgFile
  writeFile ("noId/" ++ hgFile) (show g)
  writeFile ("noId/" ++ hgFile' ++ "_reverse.txt") (show gRev)


negrasToTrees
  = concatMap
      ( fmap Negra.negraTreeToTree
      . Negra.negraToForest
      . Negra.filterPunctuation
      . Negra.sData
      )


onlyPreterminals (T.Node x [T.Node _ []]) = T.Node x []
onlyPreterminals (T.Node x ts) = T.Node x (map onlyPreterminals ts)


yield (T.Node r []) = [r]
yield (T.Node _ ts) = concatMap yield ts


traceFile file x y
  = unsafePerformIO (writeFile file (show x) >> return y)


hgToNBestHg g
  = ( vertices g
    , \ v -> map (\ e -> (eId e, eTail e)) $ M.findWithDefault [] v eM
    , \ i _ -> M.findWithDefault 0 i iM
    )
  where
    eM = edgesM g
    iM = M.fromList $ map (\ e -> (eId e, eWeight e)) $ edges g


hPathToTree (NB.B i bs)
  = T.Node i (map hPathToTree bs)


idTreeToLabelTree g
  = fmap (\ i -> M.findWithDefault (error "unknown eId") i iM)
  where
    iM = M.fromList $ map (\ e -> (eId e, eLabel e)) $ edges g


pairToTuple (NB.P x y) = (x, y)
