-----------------------------------------------------------------------------
-- |
-- Module      :  VandaCLI.PDTA
-- Copyright   :  (c) Technische Universität Dresden 2016
-- License     :  BSD-style
--
-- Maintainer  :  Toni.Dietze@tu-dresden.de
-- Stability   :  experimental
-- Portability :  portable
-----------------------------------------------------------------------------

{-# LANGUAGE RecordWildCards #-}

module VandaCLI.PDTA
( main
, mainArgs
, cmdArgs
, Args()
) where


import           Control.Arrow (second)
import           Data.Either (isRight)
import           Data.Foldable (for_)
import qualified Data.IntMap.Lazy as IM
import qualified Data.IntSet as IS
import           Data.List (intercalate, sort, transpose)
import qualified Data.Map.Lazy as M
import qualified Data.Set as S
import           Data.Tree
import           Data.Tuple (swap)
import qualified Data.Vector as V
import           System.Console.CmdArgs.Explicit (processArgs)

import           System.Console.CmdArgs.Explicit.Misc (populateHelpMode)
import qualified VandaCLI.Corpus.SExpression.CmdArgs as SExp
import           VandaCLI.PDTA.CmdArgs
import           Vanda.GrammaticalInference.PDTA.Inference
import           Vanda.Util.PrettyPrint (columnize)
import           Vanda.Util.Tree (OrdTree(..), subTrees)


main :: IO ()
main = processArgs (populateHelpMode Help cmdArgs) >>= mainArgs


mainArgs :: Args -> IO ()

mainArgs (Help cs) = putStr cs

mainArgs Infer{..} = do
  corpus <- map (second fromIntegral) <$> SExp.readCorpora flagsCorpora
  debugDissectCorpus corpus
  let corpussize = sum $ map snd corpus
      corpussubtrees = S.size $ S.fromList
                     $ map OrdTree $ concatMap (subTrees . fst) corpus
      alpha = case argAlpha of
                FAConst c         -> c
                FARecipCorpussize -> recip corpussize
      (ssub, δ, f) = infer alpha corpus
  putStrLn "=== general information ========================================="
  putStrLn $ "corpus size                  : " ++ show corpussize
  putStrLn $ "number of different subtrees : " ++ show corpussubtrees
  putStrLn $ "α                            : " ++ show alpha
  putStrLn "=== ssub ========================================================"
  putStrLn $ "number of elements: " ++ show (IS.size ssub)
  print ssub
  putStrLn "=== δ ==========================================================="
  putStrLn $ "number of elements: " ++ show (M.size δ)
  putStr
    $ columnize [" <- ", " "]
    $ transpose
    $ map (\ (q, (l, qs)) -> [show q, l, show qs])
    $ sort $ map swap $ M.toList δ
  putStrLn "=== f ==========================================================="
  print f
  putStrLn "=== unrecognizable corpus trees ================================="
  for_ corpus $ \ (t, _) ->
    case parseEither δ t of
      Left  x -> print x
      Right _ -> return ()
  let recCount = length $ filter isRight $ map (parseEither δ . fst) corpus
      corpuslength = length corpus
  putStrLn $ show recCount ++ " / " ++ show corpuslength ++ " ("
    ++ show (round (100 * fromIntegral recCount / fromIntegral corpuslength))
    ++ "%) recognizable"

  let (rootW, transW) = train δ corpus
  putStrLn "=== root weights ================================================"
  putStr $ unlines $ map show $ M.toList rootW
  putStrLn "=== transitions weights ========================================="
  putStr
    $ columnize [" <- ", " ", " # "]
    $ transpose
    $ map (\ (q, ((σ, qs), w)) -> [show q, σ, show qs, show w])
    $ concatMap (traverse M.toList)
    $ IM.toList transW


------------------------------------------------------------------------------

debugDissectCorpus
  :: (Foldable f, Floating a, Show a) => f (Tree String, a) -> IO ()
debugDissectCorpus corpus = do
  let (packedV, _{-packedM-}, cntV, parentsV, treeV) = dissectCorpus corpus
--       getParents = IS.toList . (parentsV V.!)
--       getChildren = snd . (packedV V.!)
--       getAncestors = closure getParents . (: [])
--   for_ [0 .. V.length parentsV - 1] $ \ i -> do
--     putStr $ show i ++ " -> "
--     print $ getAncestors i
--     putStrLn ""
  putStrLn "=== packedV problems ============================================"
  putStr $ unlines $ map show $ V.toList $ V.filter (\ (x, (_, xs)) -> any (x <=) xs) $ V.indexed packedV
  putStrLn "=== parentsV problems ==========================================="
  putStr $ unlines $ map show $ V.toList $ V.filter (\ (x, xs) -> any (x >=) $ IS.toList xs) $ V.indexed parentsV
  putStrLn "=== packedV ====================================================="
  putStr $ unlines $ map show $ V.toList $ V.indexed packedV
  putStrLn "=== cntV ========================================================"
  putStr $ unlines $ map show $ V.toList $ V.indexed cntV
  putStrLn "=== parentsV ===================================================="
  putStr $ unlines $ map show $ V.toList $ V.indexed parentsV
  putStrLn "=== treeV ======================================================="
  putStr
    $ unlines
    $ map (\ (i, t) -> show i ++ " = " ++ tree2term t)
    $ V.toList
    $ V.indexed
    $ fmap (fmap snd) treeV


{-
closure :: (Int -> [Int]) -> [Int] -> [Int]
closure f = go IS.empty
      where go done = (>>= \ x -> if x `IS.member` done
                                  then []
                                  else x : go (IS.insert x done) (f x)
                      )
-}


-- this is rather inefficient
tree2term :: Tree String -> String
tree2term (Node x []) = x
tree2term (Node x ts) = x ++ "(" ++ intercalate ", " (map tree2term ts) ++ ")"


-- | unneeded function
diffSortedLists :: Ord a => [a] -> [a] -> ([a], [a], [a])
diffSortedLists xs@(x : xs') ys@(y : ys')
  = case compare x y of
      LT -> (x : ls,     bs,     rs) where (ls, bs, rs) = diffSortedLists xs' ys
      EQ -> (    ls, x : bs,     rs) where (ls, bs, rs) = diffSortedLists xs' ys'
      GT -> (    ls,     bs, y : rs) where (ls, bs, rs) = diffSortedLists xs  ys'
diffSortedLists [] ys = ([], [], ys)
diffSortedLists xs [] = (xs, [], [])

------------------------------------------------------------------------------

testCorpus :: [(Tree String, Double)]
testCorpus
  = [ (Node "a" [], 4)
    , (Node "a" [Node "a" [Node "a" []]], 2)
    , (Node "a" [Node "a" [Node "a" [Node "a" [Node "a" []]]]], 1)
    , (Node "a" [Node "a" [], Node "a" []], 8)
    ]
