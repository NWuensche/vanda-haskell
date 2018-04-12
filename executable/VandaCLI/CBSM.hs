-----------------------------------------------------------------------------
-- |
-- Module      :  VandaCLI.CBSM
-- Copyright   :  (c) Technische Universität Dresden 2014–2017
-- License     :  BSD-style
--
-- Maintainer  :  Toni.Dietze@tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
-----------------------------------------------------------------------------

{-# LANGUAGE BangPatterns, RecordWildCards #-}

module VandaCLI.CBSM
( main
, mainArgs
, cmdArgs
, Args()
) where


import           Control.Arrow (second)
import qualified Codec.Compression.GZip as GZip
import           Control.Concurrent (getNumCapabilities)
import           Control.Monad
import qualified Data.Binary as B
import qualified Data.ByteString.Lazy as BS
import           Data.Foldable (for_)
import           Data.List (intercalate, nub, minimumBy, maximumBy, sort)
import           Data.List.Split (wordsBy)
import           Data.Map ((!))
import qualified Data.Map as M
import           Data.Maybe (maybeToList)
import           Data.Ord
import qualified Data.Set as S
import           Data.Tree
import qualified Data.Vector as V
import           Numeric.Log (Log(..))
import           System.Console.CmdArgs.Explicit (processArgs)
import           System.CPUTime
import           System.Directory (createDirectoryIfMissing)
import           System.Exit (exitFailure)
import           System.FilePath ((</>), (<.>), takeExtension)
import           System.IO ( Handle
                           , IOMode(..)
                           , hFlush
                           , hPutStr
                           , hPutStrLn
                           , stdout
                           , withFile )
import           System.Posix.Files (fileExist)
import           System.Posix.Signals (sigUSR1)
import           System.Random (StdGen, mkStdGen)
import           Text.PrettyPrint (render)


import qualified Control.Error
import           Control.Monad.Extra (ifM)
import           Data.List.Extra (at, groupWithRanges, isSingleton, toRanges)
import           System.Console.CmdArgs.Explicit.Misc
import           Vanda.Algorithms.EarleyMonadic
import qualified Vanda.Algorithms.Earley.WSA as WSA
import           VandaCLI.CBSM.CmdArgs
import           Vanda.CBSM.CountBasedStateMerging
import           Vanda.CBSM.CRTG hiding (rules)
import           Vanda.CBSM.Merge (prettyPrintMerge)
import           Vanda.CBSM.StatisticsRenderer
import           Vanda.Corpus.Binarization (Nodetype(..))
import           VandaCLI.Corpus.Binarization.CmdArgs
import           Vanda.Corpus.Penn.Text (treeToPenn)
import qualified VandaCLI.Corpus.SExpression.CmdArgs as SExp
import qualified Vanda.Features as F
import qualified Vanda.Hypergraph as H
import           Vanda.Hypergraph.DotExport (fullHypergraph2dot)
import           Vanda.Hypergraph.Recognize
import           Vanda.Util.CommandlineInfo (commandlineInfo)
import           Vanda.Util.Histogram
import           Vanda.Util.IO
import           Vanda.Util.Timestamps
import           Vanda.Util.Tree as T


errorHere :: String -> String -> a
errorHere = Control.Error.errorHere "Vanda.CBSM.Main"


type BinaryCRTG = CRTG Int String
type BinaryIntToTreeMap = M.Map Int (Tree String)
type BinaryInfo = Info StdGen Int


main :: IO ()
main = processArgs (populateHelpMode Help cmdArgs) >>= mainArgs


mainArgs :: Args -> IO ()

mainArgs (Help cs) = putStr cs

mainArgs PrintCorpora{..} = do
  putStr
    . unlines
    . zipWith ( drawTreeFormatted (SExp.flagBinarization flagsCorpora)
                                  flagOutputFormat
              . show
              ) [1 :: Int ..]
    . map fst
   =<< SExp.readCorpora flagsCorpora

mainArgs opts@CBSM{..} = do
  exist <- fileExist (flagDir </> fileNameOptions)
  when exist $ do
    putStrLn $ "File exists: " ++ (flagDir </> fileNameOptions)
    putStrLn   "Probably you have run cbsm in this directory before."
    putStrLn   "Did you mean cbsm-continue?"
    exitFailure
  createDirectoryIfMissing True flagDir
  writeFile (flagDir </> fileNameOptions) (show opts)
  appendFile (flagDir </> fileNameCommandlineInfo) =<< commandlineInfo
  (g, tM) <- forestToGrammar' <$> SExp.readCorpora flagsCorpora
  encodeFile (flagDir </> fileNameIntToTreeMap) (tM :: BinaryIntToTreeMap)
  numCapabilities <- getNumCapabilities
  putStrLnTimestamped $ "numCapabilities: " ++ show numCapabilities
  withFile (flagDir </> fileNameStatistics) AppendMode $ \ hStat ->
   withFile (flagDir </> fileNameEvaluations) AppendMode $ \ hEvals ->
   withFile (flagDir </> fileNameEquivBeamIndizes) AppendMode $ \ hBeam ->
   withFileIf flagLogBeamVerbose (flagDir </> fileNameLogBeamVerbose)
              AppendMode $ \ mhLogBeamVerbose -> do
    hPutStrLn hStat
      "CPU time,\
      \iteration,\
      \rules,\
      \states,\
      \initial states,\
      \merge pairs,\
      \beam width,\
      \beam index,\
      \saturation steps,\
      \rule merges,\
      \state merges,\
      \initial-state merges,\
      \log₂ likelihood delta,\
      \likelihood delta,\
      \log₂ evaluation of merge,\
      \evaluation of merge,\
      \heuristic,\
      \best heuristic,\
      \total saturation steps"
    hPutStrLn hEvals "iteration,beam index low,beam index high,\
      \log₂ evaluation of merge,evaluation of merge"
    hPutStrLn hBeam "iteration,beam index low,beam index high"
    for_ mhLogBeamVerbose $ \ h -> hPutStrLn h
      "iteration,\
      \beam index,\
      \heuristic,\
      \log₂ evaluation,\
      \log₂ Δ likelihood,\
      \log₂ factor rules,log₂ factor states,log₂ factor initial,\
      \rule merges,state merges,initial merges,\
      \seed state 1,seed state 2,\
      \saturation steps"
    safeSaveLastGrammar flagSaveCounter flagSaveTimer flagVerboseInfo
                        flagDir hStat hEvals hBeam mhLogBeamVerbose
      $ take (succ flagIterations)
      $ cbsm
          ConfigCBSM
            { confNumCapabilities  = numCapabilities
            , confMergeGroups      = mergeGroups
                                       (SExp.flagBinarization flagsCorpora)
                                       flagRestrictMerge
                                       tM
            , confEvaluate         = if flagNormalize
                                     then normalizeLklhdByMrgdStates
                                     else flip const
            , confHeuristic        = heuristic flagHeuristic
            , confBeamWidth        = flagBeamWidth
            , confDynamicBeamWidth = flagDynamicBeamWidth
            , confShuffleStates    = flagShuffle == FSStates
            , confShuffleMerges    = flagShuffle == FSMerges
            }
          (g, initialInfo (mkStdGen flagSeed) (cntState g))

mainArgs CBSMContinue{..} = do
  opts <- read <$> readFile (flagDir </> fileNameOptions) :: IO Args
  appendFile (flagDir </> fileNameCommandlineInfo)
    .   (unlines ["", replicate 78 '─', ""] ++)
    =<< commandlineInfo
  it   <- read <$> readFile (flagDir </> fileNameLastIteration) :: IO Int
  g    <- decodeFile (flagDir </> fileNameGrammar it) :: IO BinaryCRTG
  info <- decodeFile (flagDir </> fileNameInfo    it) :: IO BinaryInfo
  groups <- mergeGroups (SExp.flagBinarization $ flagsCorpora opts)
                        (flagRestrictMerge opts)
    <$> (decodeFile (flagDir </> fileNameIntToTreeMap)
           :: IO BinaryIntToTreeMap)
  numCapabilities <- getNumCapabilities
  putStrLnTimestamped $ "numCapabilities: " ++ show numCapabilities
  withFile (flagDir </> fileNameStatistics) AppendMode $ \ hStat ->
   withFile (flagDir </> fileNameEvaluations) AppendMode $ \ hEvals ->
   withFile (flagDir </> fileNameEquivBeamIndizes) AppendMode $ \ hBeam ->
   withFileIf (flagLogBeamVerbose opts) (flagDir </> fileNameLogBeamVerbose)
              AppendMode $ \ mhLogBeamVerbose ->
    safeSaveLastGrammar (flagSaveCounter opts)
                        (flagSaveTimer   opts)
                        (flagVerboseInfo opts)
                        flagDir hStat hEvals hBeam mhLogBeamVerbose
      $ take flagIterations
      $ tail
      $ cbsm
          ConfigCBSM
            { confNumCapabilities  = numCapabilities
            , confMergeGroups      = groups
            , confEvaluate         = if flagNormalize opts
                                     then normalizeLklhdByMrgdStates
                                     else flip const
            , confHeuristic        = heuristic (flagHeuristic opts)
            , confBeamWidth        = flagBeamWidth
            , confDynamicBeamWidth = flagDynamicBeamWidth opts
            , confShuffleStates    = flagShuffle opts == FSStates
            , confShuffleMerges    = flagShuffle opts == FSMerges
            }
          (g, info)

mainArgs ShowGrammar{..}
  = putStrLn
  . prettyPrintCRTG show id
  =<< (decodeFile argGrammar :: IO BinaryCRTG)


mainArgs ShowInfo{..} = do
  Info{..} <- decodeFile argInfo :: IO BinaryInfo
  putStr "iteration           : " >> print infoIteration
  putStr "prng state          : " >> print infoRandomGen
  putStr "merge pairs         : " >> print infoMergePairs
  putStr "beam width          : " >> print infoBeamWidth
  putStr "beam index          : " >> print infoBeamIndex
  let putBeamEntry BeamEntry{..} = do
        let showLogValue x = "2^" ++ show (ld x) ++ " = " ++ show x
        putStrLn   ""
        putStrLn   "beam entry:"
        putStrLn $ "index               : " ++ show beIndex
        putStrLn $ "heuristic           : " ++ show beHeuristic
        putStrLn $ "evaluation          : " ++ showLogValue beEvaluation
        putStrLn $ "Δ likelihood        : " ++ showLogValue beLikelihoodDelta
        putStrLn $ "factor rules        : " ++ showLogValue beFactorRules
        putStrLn $ "factor states       : " ++ showLogValue beFactorStates
        putStrLn $ "factor initial      : " ++ showLogValue beFactorInitials
        putStrLn $ "rule merges         : " ++ show beMergedRules
        putStrLn $ "state merges        : " ++ show beMergedStates
        putStrLn $ "initial merges      : " ++ show beMergedInitials
        putStrLn $ "seed state 1        : " ++ show (fst beMergeSeed)
        putStrLn $ "seed state 2        : " ++ show (snd beMergeSeed)
        putStrLn $ "saturation steps    : " ++ show beSaturationSteps
        putStrLn ""
        putStrLn "saturated merge: "
        putStr (prettyPrintMerge beMergeSaturated)
  case infoBeam of
    [be] -> putBeamEntry be
    _    -> maybe (return ()) putBeamEntry (infoBeam `at` pred infoBeamIndex)
  putStrLn ""
  putStrLn ""
  m <- if null flagIntToTreeMap
       then return Nothing
       else Just <$> (decodeFile flagIntToTreeMap :: IO BinaryIntToTreeMap)
  let colorState = colorTTY [91]
      colorIter  = colorTTY [7, 96]
      colorCount = colorTTY [96]
      colorLeaf  = colorTTY [93]
      mergeTree2Tree (State s c)
        = ( Node (colorState (show s) ++ " # " ++ colorCount (show c))
            $ maybe [] (\ int2tree -> [mapLeafs colorLeaf $ int2tree ! s]) m
          , c )
      mergeTree2Tree (Merge i ms)
        = ( Node (colorIter (show i) ++ " # " ++ colorCount (show c)) ts
          , c )
        where (ts, c) = second sum $ unzip $ map mergeTree2Tree ms
  putStrLn $ "merge history: (colors:"
           ++ ", " ++ colorState "state"
           ++ ", " ++ colorIter  "iteration"
           ++ ", " ++ colorCount "count"
           ++ maybe "" (const $ ", " ++ colorLeaf "leaf") m
           ++ ")"
  putStrLn ""
  forM_ (M.toAscList infoMergeTreeMap) $ \ (i, t) -> do
    putStrLn $ colorState (show i) ++ ":"
    putStrLn $ drawTree' (drawstyleCompact1 "─") $ fst $ mergeTree2Tree t

mainArgs Parse{..} = do
  (hg, inis) <- toHypergraph <$> (decodeFile argGrammar :: IO BinaryCRTG)
  let comp e | a == 0    = [Right (H.label e)]
              | otherwise = map Left [0 .. a - 1]
        where a = H.arity e
  let feature = F.Feature (\ _ (i, _) xs -> i * product xs) V.singleton
  sents <- map words . lines <$> getContents
  forM_ sents $ \ sent -> do
    let wsa = createWSA flagUnknownWords hg sent
    let (hg', _) = earley' (asBackwardStar hg) comp wsa (M.keys inis)
    let inis' = M.mapKeys (\ k -> (0, k, length sent)) inis
    printWeightedTrees
        flagBinarization flagUnbinarize flagOutputFormat flagMessageNoParse
      $ take argCount
      $ map (second $ unknownWordOutput flagUnknownWordOutput sent
                    . fmap H.label)
      $ bestsIni hg' feature (V.singleton 1) inis'
    hFlush stdout

mainArgs GrammarToDOT{..}
  = putStrLn
  . render
  . fullHypergraph2dot show H.label argGrammar
  . (fst . toHypergraph :: BinaryCRTG -> H.EdgeList Int String Double)
  =<< (decodeFile argGrammar :: IO BinaryCRTG)

mainArgs Bests{..} = do
  (hg, inis) <- toHypergraph <$> (decodeFile argGrammar :: IO BinaryCRTG)
  let feature = F.Feature (\ _ i xs -> i * product xs) V.singleton
  printWeightedTrees
      flagBinarization flagUnbinarize flagOutputFormat "language empty"
    $ take argCount
      $ map (second $ fmap H.label)
    $ bestsIni (asBackwardStar hg) feature (V.singleton 1) inis

mainArgs RenderBeam{..} =
  renderBeam flagRunLengthEncoding
             argColumn
             (wordsBy (==',') flagSortFormatString) -- TODO: unless it occurs in a mixedness mapper format string...
             flagColormapMin
             flagColormapMax
             flagChunkSize
             (chunkCruncher flagChunkCruncher)
             argRenderBeamInput
             argRenderBeamOutput

mainArgs RenderBeamInfo{..} = do
  Info{..} <- B.decodeFile argInfo :: IO BinaryInfo
  int2tree <- B.decodeFile argIntToTreeMap :: IO BinaryIntToTreeMap
  renderBeamInfo argRenderBeamInput
                 argRenderableCats
                 (wordsBy (==',') flagSortFormatString) -- TODO: unless it occurs in a mixedness mapper format string...
                 infoMergeTreeMap
                 int2tree
                 flagChunkSize
                 (chunkCruncher flagChunkCruncher)
                 argRenderBeamOutput

mainArgs RecognizeTrees{..} = do
  binGrammar <- decodeFile argGrammar :: IO BinaryCRTG
  trees <- map fst <$> SExp.readCorpora flagsCorpora
  let (hg, initsMap) = toHypergraph binGrammar :: (H.ForwardStar Int String Double, M.Map Int Double)
      logProbs = map (logBase 2 . totalProbOfTree (hg, initsMap)) trees
      stateCount = S.size $ H.nodes hg
      nonZeros = filter ((/=logBase 2 0) . snd) $ zip trees logProbs
      nonZeroLogProbs = map snd nonZeros
      nonZeroCount = length nonZeros
      meanLogProb = sum nonZeroLogProbs / fromIntegral nonZeroCount
  
  putStrLn $ intercalate "\t" [ show stateCount
                              , show (sum logProbs)
                              , show nonZeroCount
                              , show meanLogProb
                              ]
  when flagPrintRecognizable
    $ putStr
    $ unlines
    $ zipWith ( drawTreeFormatted FBNone FOFPenn
              . show
              ) [1 :: Int ..]
    $ map fst nonZeros

chunkCruncher :: Ord a => FlagChunkCruncher -> [a] -> a
chunkCruncher FCCMaximum xs
  = maximum xs
chunkCruncher FCCMinimum xs
  = minimum xs
chunkCruncher FCCMajority xs
  = fst
  $ maximumBy (comparing snd)
  $ M.toList
  $ histogram xs
chunkCruncher FCCMinority xs
  = fst
  $ minimumBy (comparing snd)
  $ M.toList
  $ histogram xs
chunkCruncher FCCMedian xs
  = head $ drop (length xs `div` 2) $ sort xs


data RestrictMergeFeature a
  = RMFBinLeaf Bool
  | RMFBinMeta Bool
  | RMFLeaf Bool
  | RMFTerminal a
  | RMFUnary Bool
  deriving (Eq, Ord)


rmFeature
  :: FlagBinarization
  -> FlagRestrictMerge
  -> Tree String
  -> RestrictMergeFeature String
rmFeature b FRMBinLeaf   = RMFBinLeaf . (Leaf ==) . nodetypeByFlag b
rmFeature b FRMBinMeta   = RMFBinMeta . (Meta ==) . nodetypeByFlag b
rmFeature _ FRMLeafs     = RMFLeaf . null . subForest
rmFeature _ FRMTerminals = RMFTerminal . rootLabel
rmFeature _ FRMUnary     = RMFUnary . isSingleton . subForest


mergeGroups
  :: Ord v
  => FlagBinarization
  -> [FlagRestrictMerge]
  -> M.Map v (Tree String)
  -> [S.Set v]
mergeGroups b flags
  = map S.fromList
  . M.elems
  . M.fromListWith (++)
  . map (\ (v, t) -> (map ($ t) features, [v]))
  . M.toList
  where
    features = map (rmFeature b) (nub flags)


heuristic :: FlagHeuristic -> Double -> Double -> Double
heuristic FHCountSum               = heuristicCountSum
heuristic FHPartialLikelihoodDelta = heuristicPartialLikelihoodDelta


createWSA
  :: (H.Hypergraph h, Ord v, Ord l, Num w)
  => FlagUnknownWords -> h v l i -> [l] -> WSA.WSA Int l w
createWSA flag hg xs
  = case flag of
      FUWStrict    -> id
      FUWArbitrary -> replaceUnknownsInWSA
  $ WSA.fromList 1 xs
  where
    knownWords
      = S.fromList $ map H.label $ filter ((0 ==) . H.arity) $ H.edges hg
    replaceUnknownsInWSA x
      = x{WSA.transitions = concatMap replaceUnknowns $ WSA.transitions x}
    replaceUnknowns t
      = if S.member (WSA.transTerminal t) knownWords
        then [t]
        else map (\ w -> t{WSA.transTerminal = w}) $ S.toList knownWords


unknownWordOutput
  :: FlagUnknownWordOutput -> [String] -> Tree String -> Tree String
unknownWordOutput FUWOOriginal s t
  = zipLeafsWith const s t
unknownWordOutput FUWOReplacement _ t = t
unknownWordOutput FUWOBoth s t
  = zipLeafsWith (\ x y -> x ++ "/" ++ y) s t


printWeightedTrees
  :: Show a
  => FlagBinarization
  -> Bool              -- ^ undo binarization before output
  -> FlagOutputFormat
  -> String
  -> [(a, Tree String)]
  -> IO ()
printWeightedTrees _ _ _ msg [] = putStrLn msg
printWeightedTrees b unbin fmt _ xs =
  forM_ (zip [1 :: Int ..] xs) $ \ (i, (w, t)) ->
    putStrLn
      $ drawTreeFormatted
          (if unbin then FBNone else b)
          fmt
          (show i ++ ": " ++ show w)
      $ if unbin then decodeByFlag b t else t


drawTreeFormatted
  :: FlagBinarization
  -> FlagOutputFormat
  -> String
  -> Tree String
  -> String
drawTreeFormatted _ FOFBranches cs t
  = unlines
  $ map ((cs ++ ": ") ++)
  $ branches t
  where
    branches (Node cs ts) = unwords (cs : "→" : map rootLabel ts)
                          : concatMap branches ts
drawTreeFormatted _ FOFPenn   _  t = treeToPenn id t
drawTreeFormatted b FOFPretty cs t = cs ++ newline
                                  ++ unwords (yieldByFlag b t) ++ newline
                                  ++ drawTreeColored b t
drawTreeFormatted b FOFYield  _  t = unwords (yieldByFlag b t)


drawTreeColored :: FlagBinarization -> Tree String -> String
drawTreeColored b
  = drawTree' (drawstyleCompact1 "─")
  . mapWithSubtrees (\ t@(Node x _) -> case nodetypeByFlag b t of
                              Leaf  -> colorTTY [93] x
                              Meta  -> colorTTY [90] x
                              Inner -> x
                    )


colorTTY :: [Int] -> String -> String
colorTTY cols str
  = "\ESC[" ++ intercalate ";" (map show cols) ++ "m" ++ str ++ "\ESC[m"


newline :: String
newline = unlines [""]


safeSaveLastGrammar
  :: Maybe Int     -- ^ save interval in number of results
  -> Maybe Int     -- ^ save interval in microseconds
  -> Bool          -- ^ 'True': write full 'Info's to files;
                   --   'False': remove every but the chosen candidate from
                   --   'infoBeam' before writing to file
  -> FilePath      -- ^ directory where the results are saved
  -> Handle        -- ^ handle to log general statistics
  -> Handle        -- ^ handle to log evaluations of candidates in beam
  -> Handle        -- ^ handle to log equivalent beam indizes
  -> Maybe Handle  -- ^ handle to log full beam information
  -> [(BinaryCRTG, Info StdGen Int)]
  -> IO ()
safeSaveLastGrammar
  saveCounter saveTimer verboseInfo dir hStat hEvals hBeam mhLogBeamVerbose xs
  = handleOnDemand saveCounter saveTimer [sigUSR1] worker handler
  where
    worker :: ((BinaryCRTG, BinaryInfo) -> IO ()) -> IO ()
    worker update
      = forM_ xs $ \ x@(!g, Info{..}) -> do
          cpuTime <- getCPUTime
          let rules         = M.size $ cntRule  g
              states        = M.size $ cntState g
              initialStates = M.size $ cntInit  g
              showIfValid n = if n < 0 then "NaN" else show n
          hPutStrLn hStat $ intercalate ","
            $ [ showFixedComma 12 cpuTime  -- pico = 10^-12
              , show infoIteration
              , show rules
              , show states
              , show initialStates
              , showIfValid infoMergePairs
              , showIfValid infoBeamWidth
              , showIfValid infoBeamIndex
              ]
            ++ case infoBeam `at` pred infoBeamIndex of
                 Just BeamEntry{..}
                         -> [ show beSaturationSteps
                            , show beMergedRules
                            , show beMergedStates
                            , show beMergedInitials
                            , show (ld beLikelihoodDelta)
                            , show beLikelihoodDelta
                            , show (ld beEvaluation)
                            , show beEvaluation
                            , show beHeuristic
                            ]
                 Nothing -> ["NaN", "NaN", "NaN", "NaN" , "0.0", "1.0", "0.0", "1.0", "0"]
            ++ case infoBeam of
                 BeamEntry{..} : _ -> [show beHeuristic]
                 []                -> ["0"]
            ++ [ show $ sum $ map beSaturationSteps infoBeam ]
          hPutStr hEvals
            $ unlines
            $ map (\ (lo, hi, e) -> show infoIteration ++ ","
                                 ++ show (succ lo) ++ ","
                                 ++ show (succ hi) ++ ","
                                 ++ show (ld (head e)) ++ ","
                                 ++ show (head e) )
            $ groupWithRanges
            $ map beEvaluation infoBeam
          hPutStr hBeam
            $ unlines
            $ map (\ (lo, hi) -> show infoIteration ++ ","
                              ++ show lo ++ ","
                              ++ show hi)
            $ toRanges infoEquivalentBeamIndizes
          for_ mhLogBeamVerbose $ \ h -> do
            forM_ infoBeam $ \ BeamEntry{..} ->
              hPutStrLn h
                $ intercalate ","
                  [ show infoIteration
                  , show beIndex
                  , show beHeuristic
                  , show (ld beEvaluation)
                  , show (ld beLikelihoodDelta)
                  , show (ld beFactorRules)
                  , show (ld beFactorStates)
                  , show (ld beFactorInitials)
                  , show beMergedRules
                  , show beMergedStates
                  , show beMergedInitials
                  , show (fst beMergeSeed)
                  , show (snd beMergeSeed)
                  , show beSaturationSteps
                  ]
            hFlush h
          hFlush hStat
          hFlush hEvals
          hFlush hBeam
          putStrLnTimestamped
            $ "Iteration " ++ show infoIteration ++ ": "
              ++ show rules         ++ " rules, "
              ++ show states        ++ " states, "
              ++ show initialStates ++ " initial states, "
              ++ show infoMergePairs ++ " possible merges."
          hFlush stdout
          update x

    handler :: (BinaryCRTG, BinaryInfo) -> IO ()
    handler (g, info) = do
      let i = infoIteration info
      putStrLnTimestamped $ "Writing result of iteration " ++ show i ++ " ..."
      hFlush stdout
      encodeFile (dir </> fileNameGrammar i) (g    :: BinaryCRTG)
      encodeFile (dir </> fileNameInfo    i)
        $ if verboseInfo
          then info :: BinaryInfo
          else info{infoBeam = maybeToList
                             $ infoBeam info `at` pred (infoBeamIndex info)}
      writeFile (dir </> fileNameLastIteration) (show i)
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


withFileIf :: Bool -> FilePath -> IOMode -> (Maybe Handle -> IO r) -> IO r
withFileIf True  name mode act = withFile name mode (act . Just)
withFileIf False _    _    act = act Nothing


ld :: Log Double -> Double
ld (Exp x) = invLog2 * x

invLog2 :: Double
invLog2 = 1 / log 2


-- TODO: Remove file extension hack.
decodeFile :: B.Binary a => FilePath -> IO a
decodeFile file
  = if takeExtension file == ".gz"
     then decodeGZip file
     else ifM (fileExist file)
              (B.decodeFile file)
              (ifM (fileExist  (file <.> "gz"))
                   (decodeGZip (file <.> "gz"))
                   (errorHere "decodeFile" $ "File does not exist: " ++ file)
              )
  where
    decodeGZip f = B.decode . GZip.decompress <$> BS.readFile f


-- TODO: Remove file extension hack.
encodeFile :: B.Binary a => FilePath -> a -> IO ()
encodeFile file = BS.writeFile (file <.> "gz") . GZip.compress . B.encode
