{-# LANGUAGE ScopedTypeVariables #-}

module Vanda.Grammar.XRS.LCFRS.IncrementalParser
  ( testParse,
    parse,
    exampleGrammar,
    Container
  ) where

import Data.Hashable (Hashable(hashWithSalt))
import Data.Converging (Converging)
import Data.Maybe (mapMaybe, maybeToList, fromJust)
import Data.Range
import Data.Semiring
import Control.Monad(join)
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

data Item nt t wt = Active (Rule nt t) wt (IMap.IntMap Range) Int Range [VarT t] (Function t) (IMap.IntMap (IMap.IntMap Range)) wt deriving (Show)
-- erste IMap sind fertige Ranges, Int ist Ri, Range ist jetzige Range, die schon fertig ist, [VarT t] ist das, was bei Ri gerade noch nicht fertig ist, zweite IMap ist quasi x_i,j , wobei äußere IMAp i darstellt, innere das j

instance (Eq nt, Eq t) => Eq (Item nt t wt) where
  (Active r _ rhos ri left right fs completions _) == (Active r' _ rhos' ri' left' right' fs' completions' _) 
    =  r           == r' 
    && rhos        == rhos' 
    && ri          == ri'
    && left        == left'
    && right       == right'
    && completions == completions'
    && fs          == fs'


instance (Hashable nt, Hashable t) => Hashable (Item nt t wt) where
  salt `hashWithSalt` (Active r _ _ _ left _ _ _ _) 
    = salt `hashWithSalt` r `hashWithSalt` left


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
  $ (\ (e, _, _, _, _) -> (trace' "Passive Items" e)) -- parse Trees just needs passive Items from Container
   $ (\container@(_,_,_,_,all) -> (trace ("\nAll Items End: " ++ ( show all) ++ "\n") container))
  $ C.chartify (C.empty, MMap.empty, nset, MMap.empty, []) update rules bw tops)
    where
      nset = Set.fromList $ filter (not . (`elem` s')) $ Map.keys rmap
      
      rules = (initialPrediction w (s' >>= (`MMap.lookup` rmap)) iow)
            : predictionRule w (trace' "All Rules" (map snd $ MMap.toList rmap)) iow -- Mache aus Rule Map eine Liste aller Rules
            : [combineRule w iow]

-- | Prediction rule for rules of initial nonterminals.
-- Predicted alles, bei dem Terminale am Anfang stehen und Startsymbol auf lhs hat
initialPrediction :: forall nt t wt. (Hashable nt, Eq nt, Semiring wt, Eq t, Show nt, Show t, Show wt) 
                  => [t]
                  -> [(Rule nt t, wt)]
                  -> Map.HashMap nt (wt, wt)
                  -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
initialPrediction word srules ios 
  = Left 
      (trace' "initPred" [ (Active r w IMap.empty ri left right [] IMap.empty inside, inside)  --TODO Darf fs theoretisch nicht durch [] ersetzen, aber da es sowieso bald wegkommt, ist das egal
      | (r@(Rule ((_, as), fs)), w) <- (trace' "Rules" srules) -- TODO, was ist, wenn Rule nicht f:fs ist, sondern nur 1 ELement ist. Geht das überhaupt?
      , (left, right,ri) <- completeKnownTokensWithRI word fs -- Jede Funktion einmal komplete known Tokens übegeben -> 1 Item für jedes Ri
      , let inside = w <.> foldl (<.>) one (map (fst . (ios Map.!)) as)
      ] )

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
      (trace' "Pred" [ (Active r w IMap.empty ri left right [] IMap.empty inside, inside)  --TODO Darf fs theoretisch nicht durch [] ersetzen, aber da es sowieso bald wegkommt, ist das egal
      | (r@(Rule ((_, as), fs)), w) <- (trace' "Rules" rules) -- TODO, was ist, wenn Rule nicht f:fs ist, sondern nur 1 ELement ist. Geht das überhaupt?
      , (left, right,ri) <- completeKnownTokensWithRI word fs -- Jede Funktion einmal komplete known Tokens übegeben -> 1 Item für jedes Ri
      , let inside = w <.> foldl (<.>) one (map (fst . (ios Map.!)) as)
      ] )

trace' :: (Show s) => String -> s -> s
trace' prefix s = trace ("\n" ++ prefix ++": "++ (show s) ++ "\n") s

-- 
completeKnownTokensWithRI  :: (Eq t)
                    => [t] 
                    -> Function t -- alle Funktionen
                    -> [(Range, [VarT t], Int)] -- Zusätzliches Int, da ich Ri mit übergebe, Erste Liste für Ranges, innere für singletons mehrere Ausgaben
completeKnownTokensWithRI _ [] = []
completeKnownTokensWithRI word (f:fs) = case (completeKnownTokens word IMap.empty Epsilon f) of
  ([], _) -> completeKnownTokensWithRI word fs
  (lefts, right) -> [(left, right, ri)| left <- lefts] ++ (completeKnownTokensWithRI word fs) -- TODO ++ weg
  where ri = length (fs) -- Deshalb erstes Ri = R0, wichtig für zuordnung in Consequences, da Var 0 0 auch bei 0 beginnt
 -- Betrachte immer nur die erste Range, 
completeKnownTokens :: (Eq t)
                    => [t] 
                    -> IMap.IntMap (IMap.IntMap Range) -- Variablen, deren Ranges ich kenne
                    -- -> IMap.IntMap Range -- Fertige Ranges, brauche ich nicht
                    -> Range -- aktuelle Left,
                    -> [VarT t]-- aktuelle Right
--                    -> Function t -- Weitere Fkten., aktuelle right steht ganz vorne dran Brauch ich nicht
                    -> ([Range], [VarT t]) -- Danach bekoannte, mit allen Funktionen außer Epsilon.  -- Maybe, da, falls saveConc failed, ich das gar nicht mehr nutze, da irgendetwas falsch predicted
-- Original aus akt. Parser geht auch über mehrere Funktionen, aber das wird wahrscheinlich zu umständlich, da ich da wieder Unteritems erzeugen würde, je nachdem, welches Ri ich als nächstes besuchen würde
completeKnownTokens _ _ left [] = ([left], [])
completeKnownTokens w m left (T t:rights)
 -- = mapMaybe (\ left' -> completeKnownTokens w m left' rights) $ mapMaybe (safeConc left) $ singletons t w -- TODO Weiter Hier kommen schon mehere raus
  = (\ts -> (join $ map fst ts, snd $ head ts)) $ map (\left'' ->  completeKnownTokens w m left'' rights) 
    [ left'
    | left' <- mapMaybe (safeConc left) $ singletons t w
    ]
    -- TODO fs am Endealle gleich? oder mach ich da etwas falsch?
    
completeKnownTokens w m left (Var i j:rights)
  = case i `IMap.lookup` m of
         Just xi -> case j `IMap.lookup` xi of
            Just r -> case safeConc left r of -- Range ist vorhanden
                         Just left' -> completeKnownTokens w m left' rights
                         Nothing -> ([], rights)
            Nothing -> ([left], (Var i j):rights)
         Nothing -> ([left], (Var i j):rights)


combineRule :: forall nt t wt. (Show nt, Show t, Show wt, Hashable nt, Eq nt, Eq t, Weight wt)
        => [t] -- Word
        -> Map.HashMap nt (wt, wt) -- weights
        -> C.ChartRule (Item nt t wt) wt (Container nt t wt)
combineRule word ios = Right app
    where
        app :: Item nt t wt -> Container nt t wt -> [(Item nt t wt, wt)]
    --    app trigger@(Active _ _ _ _ _ ((Var _ _):_) _ _ _) (p, _, _, _, all)
        app trigger (_, _, _, _, all)
         = trace' "Combine" [consequence
--           | hasFinishedVar <- MMap.lookup ((as !! i), j) k --Find all Items, that have Ai_j finished TODO Andersrum auch betrachten? TODO Für Optimierung später interessant
           | chartItem <- trace' "all in Combine" all
           , consequence <- consequences trigger chartItem
         ] 
        app trigger _ = trace ("Combine - Not Matched " ++ show trigger) []
    
        -- In akt. Parser wird danach gleich auch wieder scan gemacht
        -- TODO Muss in beide Richtungen betrachten. Zur Zeit werden zwar beide richtungen betrachtet, aber nicht gleichzeitig. Nur eine von beiden
        consequences :: Item nt t wt -- trigger Item
                        -> Item nt t wt -- chart Item
                        -> [(Item nt t wt, wt)] --resulting Items TODO Warum Liste und nicht nur ein Item? Damit ich [] zurückgeben kann?
        consequences searcher@(Active rule wt rho ri left ((Var i j):rights) fs completed inside) (Active (Rule ((a, _), _)) _ _ ri' left' [] _ _ _)
            = trace' ("Consequences - First Item searches Var" ++ "\nSearch Item:" ++ (show searcher)) [(Active rule wt rho ri left' rights fs (completed') inside, inside)
            | i == ri' -- Betrachte ich richtiges Ri? 
             -- TODO Schau, dass Compatibel. Macht das evnt. completeKnownTokens?
            , left'' <- maybeToList $ safeConc left left'
            , let completed' = doubleInsert completed i j left' -- TODO Hier Double Insert
                ] --TODO Fix Weights

        consequences  (Active (Rule ((a, _), _)) _ _ ri' left' [] _ _ _) (Active rule wt rho ri left ((Var i j):rights) fs completed inside)
            = trace' "Consequences - Secound Item searches Var"[(Active rule wt rho ri left' rights fs (completed') inside, inside)
            | i == ri' -- Betrachte ich richtiges Ri? 
             -- TODO Schau, dass Compatibel. Macht das evnt. completeKnownTokens?
            , left'' <- maybeToList $ safeConc left left'
            , let completed' = doubleInsert completed i j left' -- TODO Hier Double Insert
                ] --TODO Fix Weights
        consequences _ _ = trace' "Consequences - Not Matched"[]

-- make it easiert to insert inside the inner IMap for completed Variable ranges
-- doubleInsert :: IMap.IntMap (IMap.IntMap Range) -> Int -> Int -> Range -> IMap.IntMap (IMap.IntMap Range)
-- doubleInsert map i j r = IMap.insert i mapWithRange map
--    where mapWithRange = case IMap.lookup j map of
--            Just map' -> IMap.insert j r map' -- Füge neuen Wert ein
--            Nothing -> IMap.empty

doubleInsert :: IMap.IntMap (IMap.IntMap Range) -> Int -> Int -> Range -> IMap.IntMap (IMap.IntMap Range)
doubleInsert map i j r = IMap.insertWith IMap.union i (IMap.singleton j r) map
   

--completeKnownTokens _ _ _ fs = ([], fs) -- Kann nichts machen

-- TODO  nitVerstehen
{-completeKnownTokens :: (Eq t)
                    => [t] 
                    -> IMap.IntMap Rangevector 
                    -> [(Int, Range)]
                    -> Function t 
                    -> [([(Int, Range)], Function t)]
completeKnownTokens _ _ rs [[]] = [(rs, [])]
completeKnownTokens w m rs ([]:fs) = completeKnownTokens w m (Epsilon:rs) fs
completeKnownTokens w m ((ii:r),rs) ((T t:fs):fss)  -- ii = Ri
  = [ (((ii,r):rs), fs:fss) 
    | r' <- mapMaybe (safeConc r) $ singletons t w
    ] >>= uncurry (completeKnownTokens w m)
completeKnownTokens w m ((ii,r):rs) ((Var i j:fs):fss) 
  = case i `IMap.lookup` m of
         Just rv -> case safeConc r (rv ! j) of
                         Just r' -> completeKnownTokens w m ((ii,r'):rs) (fs:fss)
                         Nothing -> []
         Nothing -> [(((ii,r):rs), (Var i j:fs):fss)]
completeKnownTokens _ _ _ _ = [] -}


-- True beudetet "Ist schon da gewesen"
-- TODO Problem: Wird erst noch kompletten 1x durchlauf der Regeln ausgeführt -> 
update :: (Show nt, Show t, Show wt, Eq nt, Eq t, Eq wt, Hashable nt) => Container nt t wt -> Item nt t wt -> (Container nt t wt, Bool)
-- TODO Trotzdem noch Items in ActiveMap aufnehmen, da ich nur diese Nutz
-- TODO Nimm Item nur auf, wenn es lhs hat, welches ein Start nt ist. Oder wird das schon in C.insert geschaut. Oder brauch ich das überhaupt nicht, da ich ja in chartify nur nach den Items suche, die mit einem NT aus s' beginnen?
update (p, a, n, k, all) item@(Active rule@(Rule ((nt, _), _)) iw _ _ left [] [] completions inside) = -- Sind alle Ris berechnet? -> Item fertig, also in p Chart aufnehmen
                case C.insert p nt {-rv aus rhos berechnen-} (singleton left) backtrace inside of -- TODO Backtrace + Rangevector neu, TODO Überprüfe beim Einfügen der Variablen in doppel IMap, ob sich das alles verträgt, wahrscheinlich in completeKnownTokens zu erledigen
                    (p', isnew) -> trace ("\np':" ++ show p' ++ "\n" ++ "addIfNew:" ++ (show (addIfNew item all)) ++ "\nisnew" ++ (show isnew) ++"backtrace2:" ++(show backtrace)) ((p', a, n, k, trace' ("Update - All Items With New Passive"++(show isnew)) (addIfNew item all)), isnew) -- TODO Auch in aktives Board mit aufnehmen? Oder nicht mehr nötig?
    where 
        backtrace = C.Backtrace rule iw (trace' "Backtrace" rvs)  -- Rangevectors von jedem NT  - Ist das so richtig?
        rvs = [rv
              | rangesOfOneNT <- trace' "Backtrace Completions" (IMap.elems completions)
              , let rv = fromJust $ fromList $ IMap.elems rangesOfOneNT
              ]
--update (p, a, n, k) item@(Active (Rule ((_, as), _)) _ _ _ _ (Var i j: _) _ _ _) = ((p, MMap.insert ((as !! i), j) item a, (as !! i) `Set.delete` n, k), True) -- Schmeiß aus neuen Items raus, packe in aktive Items
update (p, a, n, k, all) item = ((p,a,n, k, trace' ("Update - All Items Without New Passive" ++ (show $ not $ item `elem` all)) (addIfNew item all)), not $ item `elem` all) -- Nicht neu

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
convert i@(Active _ _ rs _ _ _, _)
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
        app (Active (Rule ((_, as), _)) w _ ((Var i _:_):_) _ _) (_, _, inits) --Var i -> Betrachte i-te Eingangsvektor Xi
        = [ (Active r' w rho'' f'' IMap.empty inside, inside <.> outside) 
        | let a = as !! i -- Nimm den i-ten Einfangsvektor Xi
        , (r'@(Rule ((a', as'), f')), w') <- MMap.lookup a rs -- Baue für jede Regel, die  Xi -> ... ist, neues Item auf
        , (rho'', f'') <- com
        ] 

-- Nimmt gefundene Ranges für ein NT + Aktuelle Ranges + Regel -> Spuckt neue Ranges und Funktionen aus, in denen alles, was möglich ist, eingesetzt wurde
completeKnownTokens :: (Eq t)
                    => [t]  -- Word
                    -> IMap.IntMap Rangevector  -- Map von Ranges von NTs, welche ich schon ersetzt habe A1->...
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


-- TODO convert active Item noch überall rein, sobald ich weiß, dass mein aktive Item richtig ist und ich daraus passive Item ableiten kann
--


