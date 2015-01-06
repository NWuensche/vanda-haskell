{-# LANGUAGE BangPatterns, DeriveDataTypeable, RecordWildCards #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.CBSM.Main
-- Copyright   :  (c) Technische Universität Dresden 2014
-- License     :  Redistribution and use in source and binary forms, with
--                or without modification, is ONLY permitted for teaching
--                purposes at Technische Universität Dresden AND IN
--                COORDINATION with the Chair of Foundations of Programming.
--
-- Maintainer  :  Toni.Dietze@tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

module Vanda.CBSM.Main
( main
, mainArgs
, cmdArgs
) where


import qualified Control.Error
import qualified Data.RevMap as RM
import           System.Console.CmdArgs.Explicit.Misc
import           Vanda.Algorithms.EarleyMonadic
import qualified Vanda.Algorithms.Earley.WSA as WSA
import           Vanda.CBSM.CountBasedStateMerging
import           Vanda.Corpus.SExpression as SExp
import qualified Vanda.Features as F
import qualified Vanda.Hypergraph as H
import           Vanda.Util.IO
import           Vanda.Util.Timestamps
import           Vanda.Util.Tree as T

import           Control.Applicative ((<$>))
import           Control.Arrow ((***))
import           Control.Monad
import qualified Data.Binary as B
import           Data.List (intercalate)
import           Data.Map ((!))
import qualified Data.Map as M
import           Data.Ord
import qualified Data.Set as S
import           Data.Tree
import qualified Data.Vector as V
import           Numeric.Log (Log(..))
import           System.Console.CmdArgs.Explicit
import           System.CPUTime
import           System.Directory ( createDirectoryIfMissing
                                  , doesDirectoryExist
                                  , getDirectoryContents )
import           System.Exit (exitFailure)
import           System.FilePath ((</>), (<.>))
import           System.IO ( Handle
                           , IOMode(..)
                           , hFlush
                           , hPutStrLn
                           , stdout
                           , withFile )
import           System.Posix.Files (fileExist)


errorHere :: String -> String -> a
errorHere = Control.Error.errorHere "Vanda.CBSM.Main"


data Args
  = Help String
  | PrintCorpora
    { flagAsForests :: Bool
    , flagDefoliate :: Bool
    , argCorpora :: [FilePath]
    }
  | CBSM
    { flagAsForests :: Bool
    , flagBeamWidth :: Int
    , flagDefoliate :: Bool
    , flagNormalize :: Bool
    , flagIterations :: Int
    , flagDir :: FilePath
    , argCorpora :: [FilePath]
    }
  | CBSM_Continue
    { flagBeamWidth :: Int
    , flagNormalize :: Bool
    , flagIterations :: Int
    , flagDir :: FilePath
    }
  | ShowInfo
    { flagIntToTreeMap :: FilePath
    , argInfo :: FilePath
    }
  | Parse
    { argGrammar :: FilePath
    , argCount :: Int
    }
  | Bests
    { argGrammar :: FilePath
    , argCount :: Int
    }
  deriving Show

cmdArgs :: Mode Args
cmdArgs
  = modes "Main" (Help $ defaultHelp cmdArgs) "Count-Based State Merging"
  [ (modeEmpty $ PrintCorpora False False [])
    { modeNames = ["print-corpora"]
    , modeHelp =
        "Print trees from TREEBANKs. Can be used to check for parsing \
        \errors. Every TREEBANK can be a file or a directory. Directories \
        \are traversed recursively. If no TREEBANK is given, the trees are \
        \read from standard input."
    , modeArgs = ([], Just flagArgCorpora)
    , modeGroupFlags = toGroup
        [ flagNoneAsForests
        , flagNoneDefoliate
        ]
    }
  , (modeEmpty $ CBSM False 1000 False False (pred maxBound) "" [])
    { modeNames = ["cbsm"]
    , modeHelp = "Read-off a grammar from TREEBANKs and generalize it. See \
        \printcorpora for further information about the TREEBANK arguments."
    , modeArgs = ([], Just flagArgCorpora)
    , modeGroupFlags = toGroup
        [ flagNoneAsForests
        , flagNoneDefoliate
        , flagReqBeamWidth
        , flagNoneNormalize
        , flagReqIterations
        , flagReqDir
        ]
    }
  , (modeEmpty $ CBSM_Continue 1000 False (pred maxBound) "")
    { modeNames = ["cbsm-continue"]
    , modeHelp = "Continue cbsm training with a grammar."
    , modeGroupFlags = toGroup
        [ flagReqBeamWidth
        , flagNoneNormalize
        , flagReqIterations
        , flagReqDir
        ]
    }
  , (modeEmpty $ ShowInfo "" "")
    { modeNames = ["show-info"]
    , modeHelp = "Show collected meta information and visualize the done \
                 \merges, if available."
    , modeArgs =
        ( [ flagArgMergeTreeMap{argRequire = True}
          ]
        , Nothing
        )
    , modeGroupFlags = toGroup
        [ flagReqIntToTreeMap
        ]
    }
  , (modeEmpty $ Parse "" 1)
    { modeNames = ["parse"]
    , modeHelp = "Parse newline-separated sentences from standard input."
    , modeArgs =
        ( [ flagArgGrammar{argRequire = True}
          , flagArgCount
          ]
        , Nothing
        )
    }
  , (modeEmpty $ Bests "" 1)
    { modeNames = ["bests"]
    , modeHelp = "View best trees of a grammar."
    , modeArgs =
        ( [ flagArgGrammar{argRequire = True}
          , flagArgCount
          ]
        , Nothing
        )
    }
  ]
  where
    flagNoneAsForests
      = flagNone ["as-forests"] (\ x -> x{flagAsForests = True})
          "the TREEBANKs contain forests instead of trees"
    flagNoneDefoliate
      = flagNone ["defoliate"] (\ x -> x{flagDefoliate = True})
          "remove leaves from trees in TREEBANKs"
    flagNoneNormalize
      = flagNone ["normalize"] (\ x -> x{flagNormalize = True})
          "normalize likelihood deltas by number of merged states"
    flagReqBeamWidth
      = flagReq ["beam-width"]
                (readUpdate $ \ a x -> x{flagBeamWidth = a})
                "BEAMWIDTH"
                "Larger values refine the search for the best merge \
                \candidate"
    flagReqIterations
      = flagReq ["iterations"]
                (readUpdate $ \ a x -> x{flagIterations = a})
                "ITERATIONS"
                "limit number of iterations"
    flagReqDir
      = flagReq ["dir"] (\ a x -> Right x{flagDir = a}) "DIRECTORY"
          "write output files to DIRECTORY instead of current"
    flagReqIntToTreeMap
      = flagReq ["int2tree"] (\ a x -> Right x{flagIntToTreeMap = a}) "FILE"
          "resolve Int to trees from the original corpus"
    flagArgCorpora
      = flagArg (\ a x -> Right x{argCorpora = argCorpora x ++ [a]}) "TREEBANK"
    flagArgMergeTreeMap
      = flagArg (\ a x -> Right x{argInfo = a}) "INFO-FILE"
    flagArgGrammar
      = flagArg (\ a x -> Right x{argGrammar = a}) "GRAMMAR-FILE"
    flagArgCount
      = flagArg (readUpdate $ \ a x -> x{argCount = a}) "COUNT"


filePathGrammar       :: FilePath -> Int -> FilePath
filePathIntToTreeMap  :: FilePath        -> FilePath
filePathInfo          :: FilePath -> Int -> FilePath
filePathLastIteration :: FilePath        -> FilePath
filePathStatistics    :: FilePath        -> FilePath
filePathGrammar       dir i = dir </> "grammar-" ++ show i <.> "bin"
filePathIntToTreeMap  dir   = dir </> "int2tree"           <.> "bin"
filePathInfo          dir i = dir </> "info-"    ++ show i <.> "bin"
filePathLastIteration dir   = dir </> "last-iteration"     <.> "txt"
filePathStatistics    dir   = dir </> "statistics"         <.> "csv"


type BinaryCRTG = CRTG Int String
type BinaryIntToTreeMap = M.Map Int (Tree String)
type BinaryInfo = Info Int


main :: IO ()
main = processArgs (populateHelpMode Help cmdArgs) >>= mainArgs


mainArgs :: Args -> IO ()

mainArgs (Help cs) = putStr cs

mainArgs PrintCorpora{..}
    = putStr
    . unlines
    . concatMap (\ (i, t) -> [ show i ++ ":"
                             , unwords (yield t)
                             , drawTreeColored t])
    . zip [1 :: Int ..]
    . map (if flagDefoliate then T.defoliate else id)
  =<< readCorpora flagAsForests argCorpora

mainArgs CBSM{..} = do
  exist <- fileExist (filePathIntToTreeMap flagDir)
  when exist $ do
    putStrLn $ "File exists: " ++ filePathIntToTreeMap flagDir
    putStrLn $ "Probably you have run cbsm in this directory before."
    putStrLn $ "Did you mean cbsm-continue?"
    exitFailure
  createDirectoryIfMissing True flagDir
  (g, tM) <- forestToGrammar
         <$> map (if flagDefoliate then T.defoliate else id)
         <$> readCorpora flagAsForests argCorpora
  B.encodeFile (filePathIntToTreeMap flagDir) (tM :: BinaryIntToTreeMap)
  withFile (filePathStatistics flagDir) AppendMode $ \ h -> do
    hPutStrLn h
      "CPU time,iteration,rules,states,initial states,beam width,beam index,\
      \candidate index,rule merges,state merges,initial-state merges,\
      \log likelihood delta,likelihood delta,log evaluation of merge,\
      \evaluation of merge"
    safeSaveLastGrammar flagDir h
      $ take (succ flagIterations)
      $ cbsm
          (if flagNormalize then normalizeLklhdByMrgdStates else flip const)
          flagBeamWidth
          (g, initialInfo (cntState g))

mainArgs CBSM_Continue{..} = do
  it   <- read <$> readFile (filePathLastIteration flagDir) :: IO Int
  g    <- B.decodeFile (filePathGrammar flagDir it) :: IO BinaryCRTG
  info <- B.decodeFile (filePathInfo    flagDir it) :: IO BinaryInfo
  withFile (filePathStatistics flagDir) AppendMode $ \ h -> do
    safeSaveLastGrammar flagDir h
      $ take (succ flagIterations)
      $ cbsm
          (if flagNormalize then normalizeLklhdByMrgdStates else flip const)
          flagBeamWidth
          (g, info)

mainArgs ShowInfo{..} = do
  info <- B.decodeFile argInfo :: IO BinaryInfo
  putStr "iteration           : " >> print (infoIteration       info)
  putStr "beam width          : " >> print (infoBeamWidth       info)
  putStr "beam index          : " >> print (infoBeamIndex       info)
  putStr "candidate index     : " >> print (infoCandidateIndex  info)
  putStr "rule merges         : " >> print (infoMergedRules     info)
  putStr "state merges        : " >> print (infoMergedStates    info)
  putStr "initial-state merges: " >> print (infoMergedInitials  info)
  putStrLn $ let l = infoLikelihoodDelta info
      in "likelihood delta    : exp " ++ show (ln l) ++ " = " ++ show l
  putStrLn $ let l = infoEvaluation info
      in "evaluation of merge : exp " ++ show (ln l) ++ " = " ++ show l
  putStrLn ""
  putStrLn ""
  putStrLn "merge history:"
  putStrLn ""
  m <- if null flagIntToTreeMap
       then return
          $ M.map (fmap $ \ x -> Node (show x) [])
          $ infoMergeTreeMap info
       else do tM <- B.decodeFile flagIntToTreeMap :: IO BinaryIntToTreeMap
               return
                $ M.map (fmap $ (tM !))
                $ infoMergeTreeMap info
  let mergeTree2Tree (State t c ) = Node (colorTTY [96] ("count: " ++ show c))
                                         [mapLeafs (colorTTY [93]) t]
      mergeTree2Tree (Merge i ms) = Node (colorTTY [7, 96] $ show i)
                                  $ map mergeTree2Tree ms
  forM_ (M.toAscList m) $ \ (i, t) -> do
    putStrLn $ show i ++ ":"
    putStrLn $ drawTree' (drawstyleCompact2 1 "") $ mergeTree2Tree t

mainArgs Parse{..} = do
  (hg, inis) <- toHypergraph <$> (B.decodeFile argGrammar :: IO BinaryCRTG)
  let comp e | a == 0    = [Right (H.label e)]
              | otherwise = map Left [0 .. a - 1]
        where a = H.arity e
  let feature = F.Feature (\ _ (i, _) xs -> i * product xs) V.singleton
  sents <- map words . lines <$> getContents
  forM_ sents $ \ sent -> do
    let (hg', _) = earley' (asBackwardStar hg) comp (WSA.fromList 1 sent) (M.keys inis)
    let inis' = M.mapKeys (\ k -> (0, k, length sent)) inis
    printWeightedDerivations
      $ take argCount
      $ bestsIni hg' feature (V.singleton 1) inis'

mainArgs Bests{..} = do
  (hg, inis) <- toHypergraph <$> (B.decodeFile argGrammar :: IO BinaryCRTG)
  let feature = F.Feature (\ _ i xs -> i * product xs) V.singleton
  printWeightedDerivations
    $ take argCount
    $ bestsIni (asBackwardStar hg) feature (V.singleton 1) inis


readCorpora :: Bool -> [FilePath] -> IO (Forest String)
readCorpora asForests corpora
    = (if asForests then concatMap SExp.toForest else map SExp.toTree)
  <$> if null corpora
        then SExp.parse SExp.pSExpressions "stdin"
          <$> getContents
        else concat
          <$> (   SExp.parseFromFiles SExp.pSExpressions
              =<< getContentsRecursive corpora
              )

printWeightedDerivations
  :: Show a => [(a, Tree (H.Hyperedge v String i))] -> IO ()
printWeightedDerivations xs =
  forM_ (zip [1 :: Int ..] xs) $ \ (i, (w, t)) -> do
    let t' = fmap H.label t
    putStrLn $ show i ++ ": " ++ show w
    putStrLn $ unwords $ yield t'
    putStrLn $ drawTreeColored t'


drawTreeColored :: Tree String -> String
drawTreeColored
  = drawTree' (drawstyleCompact2 0 "")
  . mapLeafs (colorTTY [93])


colorTTY :: [Int] -> String -> String
colorTTY cols str
  = "\ESC[" ++ intercalate ";" (map show cols) ++ "m" ++ str ++ "\ESC[m"


safeSaveLastGrammar :: FilePath -> Handle -> [(BinaryCRTG, Info Int)] -> IO ()
safeSaveLastGrammar dir h xs
  = handleInterrupt worker handler
  where
    worker :: ((BinaryCRTG, BinaryInfo) -> IO ()) -> IO ()
    worker update
      = forM_ xs $ \ x@(!g, Info{..}) -> do
          update $ x
          cpuTime <- getCPUTime
          let rules         = M.size $ cntRule  g
              states        = M.size $ cntState g
              initialStates = M.size $ cntInit  g
          hPutStrLn h $ intercalate ","
            [ showFixedComma 12 cpuTime  -- pico = 10^-12
            , show infoIteration
            , show rules
            , show states
            , show initialStates
            , show infoBeamWidth
            , show infoBeamIndex
            , show infoCandidateIndex
            , show infoMergedRules
            , show infoMergedStates
            , show infoMergedInitials
            , show (ln infoLikelihoodDelta)
            , show infoLikelihoodDelta
            , show (ln infoEvaluation)
            , show infoEvaluation
            ]
          hFlush h
          putStrLnTimestamped
            $ "Iteration " ++ show infoIteration ++ ": "
              ++ show rules         ++ " rules, "
              ++ show states        ++ " states, "
              ++ show initialStates ++ " initial states."
          hFlush stdout

    handler :: (BinaryCRTG, BinaryInfo) -> IO ()
    handler (g, info) = do
      let i = infoIteration info
      putStrLnTimestamped $ "Writing result of iteration " ++ show i ++ " ..."
      hFlush stdout
      B.encodeFile (filePathGrammar dir i) (g    :: BinaryCRTG)
      B.encodeFile (filePathInfo    dir i) (info :: BinaryInfo)
      writeFile (filePathLastIteration dir) (show i)
      putStrLnTimestamped
        $ "... done writing result of iteration " ++ show i ++ "."
      hFlush stdout


showFixedComma :: (Show a, Integral a) => Int -> a -> String
showFixedComma o = go
  where
    d = 10^o
    go x | r == 0    = show l
         | otherwise = show l ++ "." ++ replicate (o - length r') '0' ++ r'
      where l  = x `div` d
            r  = x - l * d
            r' = show r


progress :: (Int -> String) -> Int -> [a] -> IO a
progress msg n xs0 = go xs0 0
  where
    go [] _ = errorHere "progress" "list too short"
    go (x : xs) i = do
      putStrLn $ msg i
      x `seq` if i >= n
        then return x
        else go xs $! i + 1


bestsIni
  :: (H.Hypergraph h, Ord v, Eq l)
  => h v l i
  -> F.Feature l i x
  -> V.Vector Double
  -> M.Map v Double
  -> [(Double, H.Derivation v l i)]
bestsIni hg feat wV inis
  = mergesBy (comparing (Down . fst))
  $ M.elems
  $ M.intersectionWith (\ w' -> map (\ (F.Candidate w d _) -> (w' * w, d))) inis
  $ H.bests hg feat wV
  where

    -- | Merge sorted lists to a single sorted list.
    mergesBy :: (a -> a -> Ordering) -> [[a]] -> [a]
    mergesBy cmp = foldl (mergeBy cmp) []


    -- | Merge two sorted lists to a single sorted list.
    mergeBy :: (a -> a -> Ordering) -> [a] -> [a] -> [a]
    mergeBy cmp xs@(x:xs') ys@(y:ys')
      = case x `cmp` y of
          GT ->  y : mergeBy cmp xs  ys'
          _  ->  x : mergeBy cmp xs' ys
    mergeBy _ [] ys = ys
    mergeBy _ xs [] = xs


getContentsRecursive :: [FilePath] -> IO [FilePath]
getContentsRecursive paths
  = fmap concat
  $ forM paths $ \ path ->
      ifM (doesDirectoryExist path)
        ( getDirectoryContents path
          >>= getContentsRecursive
            . map (path </>)
            . filter (`notElem` [".", ".."])  -- TODO: this seems like a hack
        )
        (return [path])


ifM :: Monad m => m Bool -> m b -> m b -> m b
ifM predicateM thn els = do
  b <- predicateM
  if b then thn else els


test3 :: (Show l, Ord l) => Int -> [Tree l] -> IO ()
test3 n
  = putStr
  . unlines
  . concatMap (\ (w, d) -> [show w, drawTree' (drawstyleCompact2 0 "") $ fmap (show . H.label) d])
  . bests
  . (!! n)
  . iterate cbsmStep2
  . fst
  . forestToGrammar


test2 :: (Show l, Ord l) => Int -> [Tree l] -> IO ()
test2 n
  = putStr
  . unlines
  . map (unlines . map show . H.edges . asEdgeList . fst . toHypergraph)
  . take n
  . iterate cbsmStep2
  . fst
  . forestToGrammar


test1 :: (Show l, Ord l) => Int -> [Tree l] -> IO ()
test1 n
  = putStr
  . unlines
  . map (uncurry (++) . ((unlines . map show . H.edges . asEdgeList . fst . toHypergraph) *** (unlines . map showStep1)))
  . take n
  . tail
  . iterate step . (\ x -> (x, undefined))
  . fst
  . forestToGrammar
  where
    step (g, _) = (cbsmStep2 g, refineRanking $ enrichRanking $ mergeRanking g)

    showStep1 ((s, ((v1, n1), (v2, n2))), (mrg, delta))
      =  show s ++ "=" ++ show n1 ++ "+" ++ show n2 ++ ": "
      ++ show delta ++ ": "
      ++ show [v1, v2]
      ++ if M.size (RM.forward mrg) > 2
         then " -> " ++ show (map S.toList $ M.elems $ RM.backward mrg)
         else " (saturated)"


asEdgeList :: H.EdgeList v l i -> H.EdgeList v l i
asEdgeList = id

-- asBackwardStar :: H.BackwardStar v l i -> H.BackwardStar v l i
-- asBackwardStar = id
