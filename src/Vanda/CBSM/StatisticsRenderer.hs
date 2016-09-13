-----------------------------------------------------------------------------
-- |
-- Module      :  Vanda.CBSM.StatisticsRenderer
-- Description :  visualize statistical data generated by cbsm
-- Copyright   :  (c) Technische Universität Dresden 2016
-- License     :  Redistribution and use in source and binary forms, with
--                or without modification, is ONLY permitted for teaching
--                purposes at Technische Universität Dresden AND IN
--                COORDINATION with the Chair of Foundations of Programming.
--
-- Maintainer  :  Toni.Dietze@tu-dresden.de
-- Stability   :  unknown
-- Portability :  portable
--
-- Visualize statistical data generated by cbsm.
-----------------------------------------------------------------------------

{-# LANGUAGE BangPatterns #-}

module Vanda.CBSM.StatisticsRenderer
( renderBeam
, renderBeamInfo
) where


import           Codec.Picture  -- package JuicyPixels
import qualified Data.Binary as B
import qualified Data.ByteString.Lazy.Char8 as C
import           Data.List (foldl', intercalate, sortOn, groupBy, elemIndex, sort, minimumBy)
import           Data.List.Split (splitOn, chunksOf)
import qualified Data.Map.Lazy as M
import           Data.Maybe (fromMaybe)
import           Data.Ord (Down(..), comparing)
import qualified Data.Set as S
import qualified Data.Tree as T

import qualified Control.Error
import           Vanda.CBSM.CountBasedStateMerging
import           Vanda.Util.Timestamps (putStrLnTimestamped, putStrLnTimestamped')


import Debug.Trace

errorHere :: String -> String -> a
errorHere = Control.Error.errorHere "Vanda.CBSM.StatisticsRenderer"

divUp :: Int -> Int -> Int
divUp x y = case quotRem x y of
              (i,0) -> i
              (i,_) -> i+1

safeMapping
  :: Eq s
  => [s]     -- ^ list containing values we want to map to their index
  -> Int     -- ^ value for all Just values not present in the list
  -> Int     -- ^ value for all Nothing values
  -> Maybe s -- ^ thing we want to map to its index
  -> Int     -- ^ the index
safeMapping cats wildcard nothing maybe
  = case maybe of
      Nothing  -> nothing
      (Just s) -> case s `elemIndex` cats of
                    Nothing -> wildcard
                    Just i  -> i

readCats :: String -> [String]
readCats ms
  | (length ms < 3 || head ms /= '(' || last ms /= ')')
    = errorHere "readCats" $ "Malformed terminal/category string " ++ ms
  | otherwise
    = splitOn "|" (init $ tail ms) -- remove () and split on |

data Sortable = SortableDouble Double
              | SortableDownDouble (Down Double)
              | SortableMaybeString (Maybe String)
              | SortableMappingInt Int
              deriving (Eq, Ord, Show)
genSorter
  :: String                                        -- ^ format string segment
  -> [C.ByteString]                                -- ^ row data
  -> (Int -> (IntState, IntState) -> Maybe String) -- ^ get mixedness of merge at iter
  -> (Int -> Sortable)                             -- ^ Sortable given the iteration
genSorter "" _ _ _ = errorHere "genSorter" "empty format string segment"
genSorter ('m':ms) rowdata getMixedness iter
  | null ms
    = SortableMaybeString mixedness
  | otherwise
    = let unsafeCats = readCats ms
          wildcardPos = fromMaybe (maxBound - 1) $ "*" `elemIndex` unsafeCats
          mixedPos    = fromMaybe  maxBound      $ "-" `elemIndex` unsafeCats
      in SortableMappingInt $ safeMapping unsafeCats wildcardPos mixedPos mixedness
  where
    statePair = ( unsafeReadInt $ rowdata !! 9
                , unsafeReadInt $ rowdata !! 10)
    mixedness = getMixedness iter statePair
genSorter s rowdata _ _
  | not $  length s >= 2
        && all (flip elem "0123456789") (init s)
        && last s `elem` "ad"
    = errorHere "genSorter" $ "Malformed format string segment " ++ s
  | otherwise = let col = unsafeReadInt $ C.pack $ init s
                    colval = unsafeReadDouble $ rowdata !! col
    in case last s of
         'a' -> SortableDouble colval
         'd' -> SortableDownDouble $ Down colval

-- | Visualize the beam using a heat map.
--
-- The input file is usually called @statistics-evaluations.csv@.
renderBeam
  :: Bool                 -- ^ run length encoding used?
  -> Int                  -- ^ after-index (!) column to render (0-based)
  -> [String]             -- ^ sorting format string (already split)
  -> Double               -- ^ value mapped to the minimum color
  -> Double               -- ^ value mapped to the maximum color
  -> Int                  -- ^ chunk size for scaling the beam
  -> ([Double] -> Double) -- ^ combining chunk candidates
  -> FilePath             -- ^ input csv file
  -> FilePath             -- ^ output png file
  -> IO ()
renderBeam rle col sortformats minval maxval
  = renderBeamWith rle reader renderer
  where
    getMixedness = errorHere "renderBeam" "tried to access a getMixedness function!"
    iter         = errorHere "renderBeam" "tried to access the iteration!"
    reader iter rowdata
      = let sortable = [genSorter s rowdata getMixedness iter | s <- sortformats]
            renderable = unsafeReadDouble $ rowdata !! col
        in (sortable, renderable)
    renderer = colormap minval maxval

type IntState = Int
renderBeamInfo
  :: FilePath                            -- ^ input csv file
  -> String                              -- ^ renderable terminals/categories
  -> [String]                            -- ^ sorting format string (already split)
  -> M.Map IntState (MergeTree IntState) -- ^ merge tree (history)
  -> M.Map IntState (T.Tree String)      -- ^ int2tree map
  -> Int                                 -- ^ chunk size for scaling the beam
  -> ([Maybe String] -> Maybe String)    -- ^ combining chunk candidates
  -> FilePath                            -- ^ output png file
  -> IO ()
renderBeamInfo fileIn renderableCats sortformats infoMergeTreeMap int2tree chunkSize combiner fileOut = do
  let allTreesTilNow = M.elems infoMergeTreeMap
      megaMergeTree = if length allTreesTilNow == 1
                        then head allTreesTilNow
                        else (Merge (maxBound :: Int) allTreesTilNow)
      termsOverTime :: M.Map IntState [(Int, [String])]
      termsOverTime = M.map (map getTerms)
                    $ turnMergeTree megaMergeTree
      
  let getTermsOfStateAt :: Int -> IntState -> [String]
      getTermsOfStateAt iter = snd
                             . last
                             . takeWhile ((<iter) . fst)
                             . (termsOverTime M.!)
      getMixedness :: Int -> (IntState, IntState) -> Maybe String
      getMixedness iter (s1, s2)
        = case (getTermsOfStateAt iter s1, getTermsOfStateAt iter s1) of
            ([x], [y]) -> if x == y
                            then Just x
                            else Nothing
            _          -> Nothing
      allTerms = S.toAscList
               $ S.fromList
               $ concatMap (getTermsOfStateAt 0)
               $ M.keys termsOverTime
      reader iter rowdata
        = let s1 = unsafeReadInt $ rowdata !! 9
              s2 = unsafeReadInt $ rowdata !! 10
              sortable = [genSorter s rowdata getMixedness iter | s <- sortformats]
              renderable = getMixedness iter (s1, s2)
          in (sortable, renderable)
      
      -- thanks to colorbrewer2 :)
      colorList = [ PixelRGB8 166 206 227
                  , PixelRGB8  31 120 180
                  , PixelRGB8 178 223 138
                  , PixelRGB8  51 160  44
                  , PixelRGB8 251 154 153
                  , PixelRGB8 227  26  28
                  , PixelRGB8 253 191 111
                  , PixelRGB8 255 127   0
                  , PixelRGB8 202 178 214
                  , PixelRGB8 106  61 154
                  , PixelRGB8 255 255 153
                  , PixelRGB8 177  89  40
                  ] ++ repeat (PixelRGB8 0 0 0)
      unsafeCats = readCats renderableCats
      wildcardPos = maxBound-1 :: Int
      nothingPos  = maxBound :: Int
      indexMapper = safeMapping unsafeCats wildcardPos nothingPos
      colorMapper i
        | i ==  maxBound    = PixelRGB8  95  95  95
        | i == (maxBound-1) = PixelRGB8 160 160 160
        | otherwise = colorList !! i
  
  putStrLnTimestamped' $ "All terminal symbols: " ++ show allTerms
  --print $ getTermsOfStateAt 0 $ C.pack "5"
  
  renderBeamWith False reader (colorMapper . indexMapper) chunkSize combiner fileIn fileOut
  where
    getTerms
      :: (Int, [IntState])
      -> (Int, [String])
    getTerms (iter, states)
      = (,) iter
      $ S.elems
      $ S.fromList
      $ map (T.rootLabel . (int2tree M.!))
      $ states

-- | The result maps all states into a list containing the list of all
-- "equivalent" states from a certain iteration on.
turnMergeTree :: Ord v => MergeTree v -> M.Map v [(Int, [v])]
turnMergeTree = M.map (map readoff) . turn
  where
    turn :: Ord v => MergeTree v -> M.Map v [MergeTree v]  --  v == Int / Tree a
    turn mt@(State v _)     = M.singleton v [mt]
    turn mt@(Merge iter cs) = M.unionWith (++) childrenMap thisNodeMap
      where
        childrenMap = M.unionsWith undefined $ map turn cs
        thisNodeMap = M.unionsWith undefined $ map (flip M.singleton [mt]) allLeafs
        allLeafs = flattenMergeTree mt -- TODO: looks really optimizable...
    readoff :: MergeTree v -> (Int, [v])
    readoff (State v _)     = ((-1), [v])
    readoff (Merge iter cs) = (iter, concatMap flattenMergeTree cs)
    pp (State v _) = show v
    pp (Merge _ cs) = "(" ++ (intercalate "," $ map pp cs) ++ ")"

flattenMergeTree :: MergeTree v -> [v]
flattenMergeTree (State x _) = [x]
flattenMergeTree (Merge iter cs) = concatMap flattenMergeTree cs

renderBeamWith
  :: Ord a
  => Bool                                       -- ^ run length encoding used?
  -> (Int -> [C.ByteString] -> ([Sortable], a)) -- ^ read function for row after indices
  -> (a -> PixelRGB8)                           -- ^ render function for the column
  -> Int                                        -- ^ chunk size for scaling the beam
  -> ([a] -> a)                                 -- ^ combining chunk candidates
  -> FilePath                                   -- ^ input csv file
  -> FilePath                                   -- ^ output png file
  -> IO ()
renderBeamWith rle reader renderer chunkSize combiner fileIn fileOut = do
  putStrLnTimestamped "Starting …"
  let getIter = (\ (i,_,_) -> i + 1)
      getBeam = (\ (_,i,_) -> i + 1)
      getWidth = getBeam . last . takeWhile ((==1) . getIter)
  w <- getWidth . parseCSVData rle reader <$> readCSV fileIn
  h <- unsafeReadInt . head . last        <$> readCSV fileIn
  let chunkedW = (w `divUp` chunkSize)
  putStrLnTimestamped'
    $ "Writing image of dimensions " ++ show chunkedW ++ "×" ++ show h ++ " …"
  writePng fileOut
    .   toImage chunkedW h renderer
    .   map traceMe
    -- Intra-iter sorting and combining
    .   processPerIter
    -- Parsing
    .   parseCSVData rle reader
    =<< readCSV fileIn
  putStrLnTimestamped "Done."
  where
    traceMe t@(iter, 0, _) 
      | iter `mod` 10 == 0 = traceShow iter t
      | otherwise = t
    traceMe t = t
    -- processPerIter :: Ord a => [(Int, Int, ([Sortable], a))] -> [(Int, Int, a)]
    processPerIter
      = concat
      . map (processIntraIter . unzip3)
      . groupBy (\ (a,_,_) (b,_,_) -> a == b)
    -- processIntraIter :: Ord a => ([Int], [Int] , [([Sortable], a)]) -> [(Int, Int, a)]
    processIntraIter ((iter:_), _, cands)
      = zipWith (\ pos val -> (iter, pos, val)) [0..]
      $ map combiner
      $ chunksOf chunkSize
      $ map snd . sortOn fst
      $ cands

toImage :: Int -> Int -> (a -> PixelRGB8) -> [(Int, Int, a)] -> Image PixelRGB8
toImage w h renderer
  = snd
  . (\ acc -> generateFoldImage step acc w h) -- we're really rather mapping
  where
    step ((y1, x1, e) : as) x2 y2
      | x1 == x2  &&  y1 == y2  =  (as, renderer e)
    step as _ _  =  let errCol = PixelRGB8 0xFF 0xFF 0xFF in (as, errCol)


readCSV :: FilePath -> IO [[C.ByteString]]
readCSV file
  =   tail -- remove header row
  .   map (C.split ',')
  .   C.lines
  <$> C.readFile file

parseCSVData
  :: Bool                         -- ^ run length encoding used?
  -> (Int -> [C.ByteString] -> a) -- ^ read function for row after indices
  -> [[C.ByteString]]             -- ^ full CSV
  -> [(Int, Int, a)]
parseCSVData rle reader
  = map (\(i, b, x) -> (pred i, pred b, x)) -- ^ zero-base index values
  . concatMap (parseCSVRow rle reader)
  where
    parseCSVRow True reader (rawIter:bl:bh:values)
      = let iter = unsafeReadInt rawIter
        in [ ( iter
             , b
             , reader iter values
             )
             | b <- [unsafeReadInt bl .. unsafeReadInt bh]
           ]
    parseCSVRow False reader (rawIter:rawb:values)
      = parseCSVRow True reader (rawIter:rawb:rawb:values)

unsafeReadInt :: C.ByteString -> Int
unsafeReadInt x
  = case C.readInt x of
      Just (i, y) -> if C.null y then i else err
      _           -> err
  where
    err = errorHere "unsafeReadInt" $ "No parse for: " ++ show x

unsafeReadDouble :: C.ByteString -> Double
unsafeReadDouble = read . C.unpack  -- TODO: read is awfully slow!



-- gnuplot> show palette
--         palette is COLOR
--         rgb color mapping by rgbformulae are 7,5,15
--         figure is POSITIVE
--         all color formulae ARE NOT written into output postscript file
--         allocating ALL remaining color positions for discrete palette terminals
--         Color-Model: RGB
--         gamma is 1.5
--
-- gnuplot> show palette rgbformulae
--           * there are 37 available rgb color mapping formulae:
--              0: 0               1: 0.5             2: 1
--              3: x               4: x^2             5: x^3
--              6: x^4             7: sqrt(x)         8: sqrt(sqrt(x))
--              9: sin(90x)       10: cos(90x)       11: |x-0.5|
--             12: (2x-1)^2       13: sin(180x)      14: |cos(180x)|
--             15: sin(360x)      16: cos(360x)      17: |sin(360x)|
--             18: |cos(360x)|    19: |sin(720x)|    20: |cos(720x)|
--             21: 3x             22: 3x-1           23: 3x-2
--             24: |3x-1|         25: |3x-2|         26: (3x-1)/2
--             27: (3x-2)/2       28: |(3x-1)/2|     29: |(3x-2)/2|
--             30: x/0.32-0.78125 31: 2*x-0.84       32: 4x;1;-2x+1.84;x/0.08-11.5
--             33: |2*x - 0.5|    34: 2*x            35: 2*x - 0.5
--             36: 2*x - 1
--           * negative numbers mean inverted=negative colour component
--           * thus the ranges in `set pm3d rgbformulae' are -36..36

colormap :: Double -> Double -> Double -> PixelRGB8
colormap minval maxval x
  = PixelRGB8
      (round $ 0xFF * sqrt p)
      (round $ 0xFF * p ^ (3 :: Int))
      (round $ 0xFF * (0 `max` sin (2 * pi * p)))
  where
    p = (clamp x - minval) / range
    clamp x = if minval < maxval
                then minval `max` x `min` maxval
                else minval `min` x `max` maxval
    range = maxval - minval


{-
colormap :: Double -> PixelRGB8
colormap
  = colorgradient
    [ (-20, PixelRGB8 0x00 0x00 0x00)
    , (-15, PixelRGB8 0x00 0x00 0xFF)
    , (-10, PixelRGB8 0xFF 0x00 0x00)
    , (  0, PixelRGB8 0xFF 0xFF 0x00)
    ]


colorgradient :: [(Double, PixelRGB8)] -> Double -> PixelRGB8
colorgradient (stop0@(hi0, hiCol0) : stops0) x
  = if x <= hi0
    then hiCol0
    else go stop0 stops0
  where
    go :: (Double, PixelRGB8) -> [(Double, PixelRGB8)] -> PixelRGB8
    go (_, col) [] = col
    go (lo, PixelRGB8 lr lg lb) (stop@(hi, hiCol@(PixelRGB8 hr hg hb)) : stops)
      = case compare x hi of
          LT -> PixelRGB8 (crossfade lr hr) (crossfade lg hg) (crossfade lb hb)
          EQ -> hiCol
          GT -> go stop stops
      where
        position = (x - lo) / (hi - lo)
        crossfade from to = round $ (1 - position) * fromIntegral from + position * fromIntegral to
colorgradient [] _
  = errorHere "colorgradient" "Empty list."
-}
