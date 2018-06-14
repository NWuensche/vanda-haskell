{-# LANGUAGE ScopedTypeVariables #-}

module Vanda.Grammar.XRS.LCFRS.IncrementalParser
  ( testParse,
    parse,
    exampleGrammar,
    Container
  ) where

-- TODO Active Item aufraümen
-- Prepare: 1. Regelsortieren (S -> [Rules, die mit S starten], A ->...),  2. NT -> (inputw, outputw), Alle Start-NT mit inputw >0
-- Default werte: Weight - 1, Beam Width - 10000, max number of ret. Trees -1 (!= Fanout)

import Data.Hashable (Hashable(hashWithSalt))
import Data.Converging (Converging)
import Data.Maybe (mapMaybe, maybeToList,catMaybes, isNothing)
import Data.Range
import Data.Semiring
import Data.Tree (Tree)
import Data.Weight
import Vanda.Grammar.PMCFG
import Debug.Trace(trace)

import qualified Data.HashMap.Lazy             as Map

import qualified Data.MultiHashMap             as MMap
import qualified Data.IntMap                   as IMap
import qualified Data.HashSet                  as Set
import qualified Vanda.Grammar.XRS.LCFRS.Chart as C

testParse :: String
testParse = "File Connected"


exampleGrammar :: String
exampleGrammar = prettyPrintWPMCFG prettyShowString prettyShowString exampleWPMCFG

-- From executable/PMCFG.hs
prettyShowString :: (Show w) => w -> String
prettyShowString s = '\"' : concatMap g (show s) ++ "\"" where
  g c    = [c]

data Item nt t wt = Active (IMap.IntMap Range) (Rule nt t) wt Int Range [VarT t] (Function t) (IMap.IntMap (IMap.IntMap Range)) (IMap.IntMap wt)  | Passive (IMap.IntMap (Rule nt t)) (Rule nt t) wt (IMap.IntMap Range) (IMap.IntMap (IMap.IntMap Range)) wt deriving (Show) 
-- Erste IMap sind Kompa Rules
-- Erste IMap Pass für Komp
-- Erstes wt in Pass ist Rule Weight für Backtrace
-- erste IMap sind fertige Ranges, Int ist Ri, Range ist jetzige Range, die schon fertig ist, [VarT t] ist das, was bei Ri gerade noch nicht fertig ist, zweite IMap ist quasi x_i,j , wobei äußere IMAp i darstellt, innere das j
--
-- Passive Item nach Thomas nicht def, einfach in Container reinwerfenk
-- 2. Elem Passive: Ranges aller Komp -> Werden später noch zu RV,
-- 3. Elem Passive: Ranges aller NT -> Werden später noch zu RVs

instance (Eq nt, Eq t) => Eq (Item nt t wt) where
  (Active cr r _ ri left right nc completions _) == (Active cr' r' _ ri' left' right' nc' completions' _) 
    =  cr          == cr'
    && r           == r' 
    && ri          == ri'
    && left        == left'
    && right       == right'
    && nc          == nc'
    && completions == completions'
  (Passive phi r _ rhos nts _) == (Passive phi' r' _ rhos' nts' _)
    =  phi         == phi'
    && r           == r' 
    && rhos        == rhos' 
    && nts          == nts'


instance (Hashable nt, Hashable t) => Hashable (Item nt t wt) where
  salt `hashWithSalt` (Active _ r _ _ left _ _ _ _) 
    = salt `hashWithSalt` r `hashWithSalt` left
  salt `hashWithSalt` (Passive _ r _ rhos nts _) 
    = salt `hashWithSalt` r


{-instance (Show nt, Show t) => Show (Item nt t wt) where
  show (Active r _ _ ri left right _ _ _)
    = "[Active] " ++ show r ++ "\n" 
    ++ "current status: Ri:" ++ show(ri)++  ", " ++ show (left) ++ " • " ++ prettyPrintComposition show [right] -- TODO Ausführlicher
-}
-- From active Parser
type Container nt t wt = ( C.Chart nt t wt -- Passive Items
                         , MMap.MultiMap (nt, Int) (Item nt t wt) --Map Variablen onto List of Active Items, that need NT in the next Step
                         , Set.HashSet nt -- All NTs, which are not init. right now
                         , MMap.MultiMap (nt, Int) (Item nt t wt) -- Map, welche zeigt, wer alles schon Variable aufgelöst hat (known)
                         , [Item nt t wt] -- All Items in Chart(all), TODO Optimize this
                         , [Rule nt t]  --All Rules
                         )
{- update :: Container nt t wt -> Item nt t wt -> (Container nt t wt, Bool)
update (p, a, n) item@(Active (Rule ((_, as),_)) _ _ ((Var i _:_):_) _ _)
 = ((p, MMap.insert (as !! i) item a, (as !! i) `Set.delete` n), True)
update (p, a, n) _ = ((p, a, n), True) TODO Hier rein, wann ein actives Item in Chart kommt-} 


-- From active Parser
parse :: forall nt t wt.(Show nt, Show t, Show wt, Hashable nt, Hashable t, Eq t, Ord wt, Weight wt, Ord nt, Converging wt) 
      => WPMCFG nt wt t -- Grammar
      -> Int -- Beam Width
      -> Int -- Max. Amount of Parse Trees
      -> [t] -- Word
      -> [Tree (Rule nt t)]
parse g bw tops w = parse' (prepare g w) bw tops w

parse' :: forall nt t wt.(Show nt, Show t, Show wt, Hashable nt, Hashable t, Eq t, Ord wt, Weight wt, Ord nt, Converging wt) 
       => (MMap.MultiMap nt (Rule nt t, wt), Map.HashMap nt (wt,wt), [nt]) -- prepare Result (RuleMap NT-Rules, IO-Weights NTs, Reachable Items
       -> Int -- Beam Width
       -> Int -- Max. Amount of Parse Trees
       -> [t] -- Word
       -> [Tree (Rule nt t)]
parse' (rmap, iow, s') bw tops w
  = trace' "Trees" (C.parseTrees tops (trace' "Start Rules" s')
    (singleton $ entire w) -- Goal Item TODO Falsches GOal item?
  $ (\ (e, _, _, _, _, _) -> (trace' "Passive Items End" e)) -- parse Trees just needs passive Items from Container
   $ (\container@(_,_,_,_,all,_) -> (trace ("\nAll Items End: " ++ ( show all) ++ "\n") container))
  $ C.chartify (C.empty, MMap.empty, nset, MMap.empty, [], (map fst $ map snd $ MMap.toList rmap)) update rules bw tops)
    where
      nset = Set.fromList $ filter (not . (`elem` s')) $ Map.keys rmap
      
      rules = (initialPrediction w (s' >>= (`MMap.lookup` rmap)) iow)
            : predictionRule w (trace' "All Rules" (map snd $ MMap.toList (trace' "Map with all Rules" rmap))) iow -- Mache aus Rule Map eine Liste aller Rules
            : scanRule w iow -- Mache aus Rule Map eine Liste aller Rules
            : combineRule w iow
            : [vervoll w iow]

-- | Prediction rule for rules of initial nonterminals.
-- Predicted alles, bei dem Terminale am Anfang stehen und Startsymbol auf lhs hat
initialPrediction :: forall nt t wt. (Hashable nt, Eq nt, Semiring wt, Eq t, Show nt, Show t, Show wt) 
                  => [t]
                  -> [(Rule nt t, wt)]
                  -> Map.HashMap nt (wt, wt)
                  -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
initialPrediction word srules ios 
  = Left 
      (trace' "initPred" [ (Active IMap.empty r w ri left right'' fs' IMap.empty inside, inside)  --TODO Darf fs theoretisch nicht durch [] ersetzen, aber da es sowieso bald wegkommt, ist das egal
      | (r@(Rule ((_, as), (f:fs))), w) <- (trace' "Rules" srules) -- TODO, was ist, wenn Rule nicht f:fs ist, sondern nur 1 ELement ist. Geht das überhaupt?
      , (ri, right', fs') <- allCombinations 0 [] f fs
      , (left, right'') <- completeKnownTokens' word IMap.empty Epsilon right'
      --, (left, right, ri) <- completeKnownTokensWithRI word fs 0 -- Jede Funktion einmal komplete known Tokens übegeben -> 1 Item für jedes Ri
      , let inside = w <.> foldl (<.>) one (map (fst . (ios Map.!)) as)
        --TODO Warum hier bei Act. Parser kein outside weight? Warum ist das also 1?
      ] )

-- Get all Componentens of a function with all remaining components
allCombinations :: Int -> Function t  -> [VarT t] -> Function t -> [(Int, [VarT t],  Function t)]
allCombinations i xs x [] = [(i, x, xs)]
allCombinations i xs x y'@(y:ys) = (i, x, xs ++ y') : (allCombinations (i+1) (x:xs) y ys)

-- complete Terminals
completeKnownTokens' :: (Eq t)
                    => [t] 
                    -> IMap.IntMap Rangevector 
                    -> Range
                    -> [VarT t]
                    -> [(Range, [VarT t])]
completeKnownTokens' _ _ r [] = [(rs, [])]
completeKnownTokens' w m r (T t:fs)
    = [ (r', fs)
        | r' <- mapMaybe (safeConc r) $ singletons t w
       ] >>= uncurry (completeKnownTokens' w m)
--TODO Warum in Active Parser noch schauen nach Variablen?
completeKnownTokens' _ _ _ _ = []
-- | Prediction rule for rules of initial nonterminals.
-- Predicted alles, bei dem Terminale am Anfang stehen 
-- TODO Mit initPred zusammenwerfen?
predictionRule :: forall nt t wt. (Hashable nt, Eq nt, Semiring wt, Eq t, Show nt, Show t, Show wt) 
                  => [t]
                  -> [(Rule nt t, wt)]
                  -> Map.HashMap nt (wt, wt)
                  -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
predictionRule word rules ios 
  = Left 
      (trace' "Pred" [ (Active IMap.empty r w ri left right'' fs' IMap.empty inside, inside <.> outside)  --TODO Darf fs theoretisch nicht durch [] ersetzen, aber da es sowieso bald wegkommt, ist das egal
      | (r@(Rule ((a, as), (f:fs))), w) <- (trace' "Rules" rules) -- TODO, was ist, wenn Rule nicht f:fs ist, sondern nur 1 ELement ist. Geht das überhaupt?
      --, (left, right,ri) <- completeKnownTokensWithRI word fs 0 -- Jede Funktion einmal komplete known Tokens übegeben -> 1 Item für jedes Ri
      , (ri, right', fs') <- allCombinations 0 [] f fs
      , (left, right'') <- completeKnownTokens' word IMap.empty Epsilon right'
      , let inside = w <.> foldl (<.>) one (map (fst . (ios Map.!)) as)
            outside = snd $ ios Map.! a
      ] )

scanRule :: forall nt t wt. (Show nt, Show t, Show wt, Hashable nt, Eq nt, Eq t, Weight wt)
        => [t] -- Word
        -> Map.HashMap nt (wt, wt) -- weights
        -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
scanRule word iow = Right app
    where
        app :: Item nt t wt -> Container nt t wt -> [(Item nt t wt, wt)]
        app (Active cr r@(Rule ((a, _), _)) wt ri left right fs completions inside) _ 
            = [((Active cr r wt ri left' right' fs completions inside), inside)
            |(left', right')  <- completeKnownTokens word completions left right -- Klammer ist hier nur, damit ich das so mit <- schreiben kann
            , let outside = snd $ iow Map.! a -- Doesn't Change from Prediction
                ]
        app _ _ = []


trace' :: (Show s) => String -> s -> s
trace' prefix s = trace ("\n" ++ prefix ++": "++ (show s) ++ "\n") s

completeKnownTokensWithRI  :: (Eq t)
                    => [t] 
                    -> Function t -- alle Funktionen
                    -> Int -- Current Rx, x number
                    -> [(Range, [VarT t], Int)] -- Zusätzliches Int, da ich Ri mit übergebe, Erste Liste für Ranges, innere für singletons mehrere Ausgaben
completeKnownTokensWithRI _ [] rx = []
completeKnownTokensWithRI word (f:fs) rx = case (completeKnownTokens word IMap.empty Epsilon f) of
  ([], _) -> completeKnownTokensWithRI word fs (rx + 1)
  (lefts, right) -> [(left, right, rx)| left <- lefts] ++ (completeKnownTokensWithRI word fs (rx+1)) -- TODO ++ weg
--  where ri = length (fs) -- Deshalb erstes Ri = R0, wichtig für zuordnung in Consequences, da Vars0 0 auch bei 0 beginnt
 -- Betrachte immer nur die erste Range, 
 -- TODO Ris falschrum -> R0 hätte bei 3stelliger Funktion R2
--completeKnownTokens :: (Eq t)
--                    => [t] 
--                    -> IMap.IntMap (IMap.IntMap Range) -- Variablen, deren Ranges ich kenne
--                    -- -> IMap.IntMap Range -- Fertige Ranges, brauche ich nicht
--                    -> Range -- aktuelle Left,
--                    -> [VarT t]-- aktuelle Right
----                    -> Function t -- Weitere Fkten., aktuelle right steht ganz vorne dran Brauch ich nicht
--                    -> ([Range], [VarT t]) -- Danach bekoannte, mit allen Funktionen außer Epsilon.  -- Maybe, da, falls saveConc failed, ich das gar nicht mehr nutze, da irgendetwas falsch predicted
-- Original aus akt. Parser geht auch über mehrere Funktionen, aber das wird wahrscheinlich zu umständlich, da ich da wieder Unteritems erzeugen würde, je nachdem, welches Ri ich als nächstes besuchen würde
--completeKnownTokens _ _ left [] = ([left], [])
--completeKnownTokens w m left (T t:rights)
 -- = mapMaybe (\ left' -> completeKnownTokens w m left' rights) $ mapMaybe (safeConc left) $ singletons t w -- TODO Weiter Hier kommen schon mehere raus
 -- = (\ts -> (ts >>= fst, snd $ head ts)) $ map (\left'' ->  completeKnownTokens w m left'' rights) 
  --  [ left'
   -- | left' <- mapMaybe (safeConc left) $ singletons t w
    --]
    -- TODO fs am Endealle gleich? oder mach ich da etwas falsch?
    
--completeKnownTokens w m left (Var i j:rights)
--  = case i `IMap.lookup` m of
--         Just xi -> case j `IMap.lookup` xi of
--            Just r -> case safeConc left r of -- Range ist vorhanden
--                         Just left' -> completeKnownTokens w m left' rights
--                         Nothing -> ([], rights)
--            Nothing -> ([left], (Var i j):rights)
--         Nothing -> ([left], (Var i j):rights)


--TODONEW Muss vervoll Item bei update auch speichern, da neue Komp-Range gefunden

vervoll :: forall nt t wt. (Show nt, Show t, Show wt, Hashable nt, Eq nt, Eq t, Eq wt, Weight wt)
        => [t] -- Word
        -> Map.HashMap nt (wt, wt) -- weights
        -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
vervoll word ios = Right app
    where
        app :: Item nt t wt -> Container nt t wt -> [(Item nt t wt, wt)]
        app trigger@(Active cr r w ri left [] [] completions ios) _
            = trace' "Vervoll" [(Active cr' r w ri left' right'' fs' completions ios, ios) -- TODO Fix weight -- ri hat dann keine Aussagekraft mehr, aber nur dafür das passive Item?...Wobei, muss ja für update wissen, ob das Item schon vervoll wurde oder nicht. Brauch ich die Regel überhaupt? Ich glaub fast nicht TODONew alles in Update, dort dann auch cr' berechnen. Dennoch in allItems aufnehmen
                |found <- (findPassiveForAllRules' (trigger:allI) allR)
                , let cr' = IMap.insert ri left cr
                ]
        app trigger@(Active cr r w ri left [] (f:fs) completions ios) _
            = trace' "Skip" [(Active cr' r w ri' left' right'' fs' completions ios, ios) -- TODO Fix weight
                | (ri', right', fs') <- allCombinations 0 [] f fs
                , (left', right'') <- completeKnownTokens' word completions Epsilon right'
                , let cr' = IMap.insert ri left cr
                ]
        app _ _ = []

combineRule :: forall nt t wt. (Show nt, Show t, Show wt, Hashable nt, Eq nt, Eq t, Weight wt)
        => [t] -- Word
        -> Map.HashMap nt (wt, wt) -- weights
        -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
combineRule word ios = Right app
    where
        app :: Item nt t wt -> Container nt t wt -> [(Item nt t wt, wt)]
        app trigger (_, _, _, _, all, _)
         = trace' "Combine" [consequence
           | chartItem <- trace' "all in Combine" all
           , consequence <- consequences trigger chartItem
         ] 
        app trigger _ = trace ("Combine - Not Matched " ++ show trigger) []
    
        consequences :: Item nt t wt -- trigger Item
                        -> Item nt t wt -- chart Item
                        -> [(Item nt t wt, wt)] -- Liste nur, damit ich [] zurückgeben kann
        consequences searcher@(Active phi rule@(Rule ((_, as), _)) wt ri left ((Var i j):rights) completed iws) finished@(Active _ r@(Rule ((a, _), _)) _ ri' left' [] _ iwf)
            = trace' ("Consequences - First Item searches Var" ++ "\nSearch Item:" ++ (show searcher) ++ "\nFinish Item:"  ++ (show finished)) [(Active phi' rule wt ri left'' rights (completed') inside, inside)
            | j == ri' -- Betrachte ich richtiges Ri? 
            , a == (as!!i) -- Betrache ich richtiges NT?
            , isCompatible phi r
            , left'' <- maybeToList $ safeConc left left'
            , let completed' = doubleInsert completed i j left' 
                  phi' = IMap.insert i r phi -- Overwriting doesn't matter
                  inside =  iws <.> (iwf </> fst (ios Map.! a))
                  outside =  snd $ ios Map.! a
                ] 
                where isCompatible phi r = case IMap.lookup i phi of
                        Just r' -> r' == r  -- used X_i with same rule?
                        Nothing -> True -- Not used X_i until now

        consequences  finish@(Active _ r@(Rule ((a, _), _)) _ ri' left' [] _ iwf) searcher@(Active phi rule@(Rule ((_, as), _)) wt ri left ((Var i j):rights) completed iws)
            = trace' ("Consequences - Secound Item searches Var\n Search Item:" ++ (show searcher) ++ "\n Finish Item: " ++(show finish)) [(Active phi' rule wt ri left'' rights (completed') inside, inside <.> outside)
            | j == ri' -- Betrachte ich richtiges Ri? 
            , a == (as!!i)
            , isCompatible phi r
            , left'' <- maybeToList $ safeConc left left'
            , let completed' = doubleInsert completed i j left'
                  phi' = IMap.insert i r phi -- Overwriting doesn't matter
                  inside =  iws <.> (iwf </> fst (ios Map.! a))
                  outside =  snd $ ios Map.! a
                ]
                where isCompatible phi r = case IMap.lookup i phi of
                        Just r' -> r' == r -- used X_i with same rule?
                        Nothing -> True -- Not used X_i until now
        consequences _ _ = trace' "Consequences - Not Matched"[]


doubleInsert :: IMap.IntMap (IMap.IntMap Range) -> Int -> Int -> Range -> IMap.IntMap (IMap.IntMap Range)
doubleInsert map i j r = IMap.insertWith IMap.union i (IMap.singleton j r) map
   
update :: (Show nt, Show t, Show wt, Eq nt, Eq t, Eq wt, Hashable nt, Semiring wt) => Container nt t wt -> Item nt t wt -> (Container nt t wt, Bool)
-- TODO Chart kürzen + Optimieren (Zuerst Rules rausschmeißen, Dann AllItems in eine Map
update (p, a, n, k, all, allRules) item@(Passive _ r _ cr ntr wt) =
    case convert (trace' "Update - Pass Item" item) of
        Just (nt, crv, bt, ios) -> case C.insert p nt crv bt ios of
            (p', isnew) -> ((p', a, n, k, all, allRules), isnew)
        Nothing -> ((p, a, n, k, all, allRules), False)

update (p, a, n, k, all, allRules) item = ((p,a,n, k, trace' ("Update - All Items Without New Passive" ++ (show $ not $ item `elem` all)) (addIfNew item all), allRules), not $ item `elem` all) -- Nicht neu

convert :: (Hashable nt, Eq nt, Semiring wt, Eq t, Show nt, Show t, Show wt)
            => Item nt t wt --Passive Item
            -> Maybe (nt, Rangevector, C.Backtrace nt t wt, wt)
convert (Passive _ rule@(Rule ((nt, _), _)) rw cr nts wt)
    = case getRangevector cr of
        Just crv -> case getBacktrace rule rw nts of
            Just bt -> Just (nt, crv, bt, wt)
            Nothing -> Nothing
        Nothing -> Nothing
    where 
            getRangevector :: IMap.IntMap Range -> Maybe Rangevector
            getRangevector cr = fromList $ map snd $ IMap.toList cr

getBacktrace :: 
    Rule nt t
    -> wt
    -> IMap.IntMap (IMap.IntMap Range) -- Completions
    -> Maybe (C.Backtrace nt t wt)
getBacktrace rule iw completions = 
    case containsANothing rvs of
        Just rvs' -> Just $ C.Backtrace rule iw (trace' "Backtrace" rvs')  -- Rangevectors von jedem NT  - Ist das so richtig?
        Nothing -> Nothing
    where rvs = [rv
                | rangesOfOneNT <- trace' "Backtrace Completions" (IMap.elems completions)
                , let rv = fromList $ IMap.elems rangesOfOneNT
                ]

containsANothing :: [Maybe Rangevector] -> Maybe [Rangevector]
containsANothing xs = case null $ filter isNothing xs of 
    True -> Just $ catMaybes xs--Every RV was succefully calculated
    False -> Nothing

-- Wenn Item noch nicht in Chart Liste, dann rein, sonst nicht
addIfNew :: (Eq nt, Eq t, Eq wt) => Item nt t wt -> [Item nt t wt] -> [Item nt t wt]
addIfNew item chart = if item `elem` chart then chart else item:chart
--    = case C.insert p nt (fromJust $ fromList [r]) (C.Backtrace rule wt ([fromJust $ fromList [r])) wt of --2x fromList r falsch, aber erstmal egal
--        (p', isnew) -> trace "\nworks1" ((p', a, n), isnew)

--update (p, a, n) item@(Active (Rule ((_, as),_)) _ _ ((Var i _:_):_) _ _)
 --   = trace ("\nworks2" ++ (show item)) ((p, MMap.insert (as !! i) item a, (as !! i) `Set.delete` n), True)
--update (p, a, n) _ = trace "\nworks3"((p, a, n), True)
-- TODO Schau, dass init Pred das macht, was es soll


{-convert :: (Item nt t wt, wt) -> Maybe (Item nt t wt, wt)
convert (Active r w rs [] completions inside, heuristic)
  = case fromList $ reverse rs of
         Nothing -> Nothing
         Just rv -> let rvs = IMap.elems completions
                        (Rule ((a, _), _)) = r
                    in Just (Passive a rv (C.Backtrace r w rvs) inside, heuristic)
convert i@(Active _ _ _ rs _ _ _, _)
  | isNonOverlapping rs = Just i
  | otherwise = Nothing
convert _ = Nothing

-- Wenn Item direkt passive ist, dann wird letztes Schritt über aktive Item nicht mehr in Map aufgenommen, vor passive Item weggelassen, da ich das nicht brauche. Falls nicht Konvertiert werden kann, dann einfach dieses Item zurückgeben
predictionRule :: forall nt t wt. (Weight wt, Eq nt, Hashable nt, Eq t) 
               => [t] -- Word
               -> MMap.MultiMap nt (Rule nt t, wt) -- Rules from prepare: NT->Rules Map
               -> Map.HashMap nt (wt, wt) -- IO-Weigths from prepare
               -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
predicitionRule word rs ios = Right app
    where
        app :: Item nt t wt -- Trigger Item
            -> Container nt t wt
            -> [(Item nt t wt, wt)] -- New Items from using Trigger with Container by using prediction Rule
        app (Active _ (Rule ((_, as), _)) w _ ((Var i _:_):_) _ _) (_, _, inits) --Var i -> Betrachte i-te Eingangsvektor Xi
        = [ (Active _ r' w rho'' f'' IMap.empty inside, inside <.> outside) 
        | let a = as !! i -- Nimm den i-ten Einfangsvektor Xi
        , (r'@(Rule ((a', as'), f')), w') <- MMap.lookup a rs -- Baue für jede Regel, die  Xi -> ... ist, neues Item auf
        , (rho'', f'') <- com
        ] 

-- Nimmt gefundene Ranges für ein NT + Aktuelle Ranges + Regel -> Spuckt neue Ranges und Funktionen aus, in denen alles, was möglich ist, eingesetzt wurde
completeKnownTokens :: (Eq t)
                    => [t]  -- Word
                    -> IMap.IntMap Rangevector  -- Map von Ranges von NTs, welche ich schon ersetzt habe A1->... TODO Brauche ich das? Wie nutzt Thomas das?
                    -> [Range] -- Ranges, welche ich hinzufügen will?
                    -> Function t -- Ersetzungfunktion
                    -> [([Range], Function t)] -- Neue Range und Funktion
completeKnownTokens _ _ rs [[]] = [(rs, [])]
completeKnownTokens w m rs ([]:fs) = completeKnownTokens w m (Epsilon:rs) fs
completeKnownTokens w m (r:rs) ((T t:fs):fss) 
  = [ (r':rs, fs:fss)
    | r' <- mapMaybe (safeConc r) $ singletons t w
    ] >>= uncurry (completeKnownTokens w m)
completeKnownTokens w m (r:rs) ((Var i j:fs):fss) 
  = case i `IMap.lookup` m of
         Just rv -> case safeConc r (rv ! j) of
                         Just r' -> completeKnownTokens w m (r':rs) (fs:fss)
                         Nothing -> []
         Nothing -> [(r:rs, (Var i j:fs):fss)]
completeKnownTokens _ _ _ _ = []

-}


-- TODO Das optimieren, erst nur mit 1 Trigger Item + Allen Items + Nur 1 Rule, dann nur mit den entsprechend nützlichen Items aus Chart
findPassiveForAllRules' :: (Eq nt, Eq t ,Eq wt, Show nt, Show t, Show wt, Semiring wt)
    => [Item nt t wt] --All Items
    -> [Rule nt t] -- All Rules
    -> [Item nt t wt] -- All new passive Items that have Range R0...Rn
findPassiveForAllRules' _ [] = []
findPassiveForAllRules' items (rule:rules) = trace' "findPassiveForAllRules" ((findPassiveForOneRule' (filter (\(Active _ ruleItem _ _ _ right _ _) -> rule == ruleItem && right == []) items) (trace' ("fPFAL" ++ show items ++ show rule) rule)) ++ (findPassiveForAllRules' items rules))-- Nur die Items, die auch die aktuelle Rule beinhalten und fertig sind
--TODO ++ weg
findPassiveForOneRule' :: (Eq nt, Eq t, Eq wt, Show nt, Show t, Show wt, Semiring wt)
    => [Item nt t wt] -- All Items with that Rule
    -> Rule nt t -- Current Rule
    -> [Item nt t wt] -- Found new complete passive Items
findPassiveForOneRule' items rule =  trace' ("findPassiveForOne' Rule" ++ show rule ++ show items) [fullConcatItem
            | r0Item@(Active phi r rw _ left _ gamma inside) <- MMap.lookup 0 itemMap -- Liste aller r0-Items TODO schau, dass dieses auch komplett durchlaufen ist
            , fullConcatItem <- {-TODO Rein(filter (\item@(Active (Rule ((_, _), f)) _ completed _ _ _ _ _ _) -> ((length f) ==  ((IMap.size completed) +1)))-} ( glueTogether'' (Passive phi r rw (IMap.singleton 0 left) gamma inside) 1 itemMap) -- Has Item as many finished Rx as Function has Komponentes? If so, it is full, +1, because left is still in Item itself -- Das Passive vor : ist wichtig für 1-komponentige Funktionen, die sonst nicht als Passives Item aufgenommenw erden. TODO Fix
            ]
    where itemMap = MMap.fromList ( map (\(item@(Active _ _ _ ri _ _ _ _)) -> (ri, item)) items) --Map of form Ri->All Items that are finished for Ri

glueTogether'' :: (Show nt, Show t, Show wt, Eq nt, Eq t, Eq wt, Semiring wt)
        => Item nt t wt -- Current Item to complete, Passive
        -> Int -- Ri to view next
        -> MMap.MultiMap Int (Item nt t wt) -- All Items of Rule
        -> [Item nt t wt] -- Can contain Unfinished Items, which where MMap is empty at some point. They will be filtered out in function above
glueTogether'' curr@(Passive phi r rw cr gamma inside) ri itemMap =
    case MMap.lookup ri itemMap of -- Get all Items that have ri completed TODO FIx here weights and compatibility check
        [] -> [curr]
        riItems -> [(Passive phi'' r rw cr' gamma'' inside'')
            | (Active phi' _ _ _ left _ gamma' inside') <- riItems
            , isCompatible phi (IMap.toList phi')
            , let cr' = IMap.insert ri left cr -- Add component range for ri TODO Add Compatibility Check
            , let gamma'' = IMap.unionWith (IMap.union) gamma gamma' -- Füge Tabellen der eingesetzten Komponenten zusammen
            , let phi'' = IMap.union phi phi' -- Dont care if something gets lost, lost rules are always the same
            , let inside'' = inside <.> inside'
             ] >>= (\pass -> glueTogether'' pass (ri+1) itemMap)
    where   isCompatible phi [] = True
            isCompatible phi ((i, r'):xs) = 
                case phi IMap.!? i of -- Was NT also in other component used
                    Just r'' -> if r'' == r' then isCompatible phi xs else False
                    Nothing -> isCompatible phi xs
