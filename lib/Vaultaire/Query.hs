{-# LANGUAGE
    FlexibleContexts
  , TypeOperators
  , ParallelListComp
  , MonadComprehensions
  , TupleSections
  #-}
-- | Analytics queries on Vaultaire data.
module Vaultaire.Query
       ( Query
       , module Vaultaire.Query.Combinators
       , module Vaultaire.Query.Connection
         -- * Analytics Queries
       , addresses, addressesAny, addressesAll, addressesWith
       , metrics, eventMetrics, lookupQ, sumPoints
       , fitWith , fitSimple, aggregateCumulativePoints
       , align
         -- * Helpful Predicates for Transforming Queries
       , fuzzy, fuzzyAny, fuzzyAll
         -- * Low-level operations
       , readSimplePoints, enumerateOrigin
       )
where

import           Control.Monad
import           Control.Monad.Logger
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.State.Strict
import           Control.Lens (view)
import           Data.Word
import           Data.Binary.IEEE754
import           Data.Either
import qualified Data.Text                  as T
import           Data.Text.Encoding         (encodeUtf8)
import           Pipes
import           Pipes.Lift
import qualified Pipes.Prelude              as P
import qualified Pipes.Parse                as P
import           Pipes.Safe
import           Data.Maybe
import           Network.URI
import qualified System.ZMQ4                as Z
import           Prelude hiding (sum, last)

import           Vaultaire.Types
import           Marquise.Types
import qualified Marquise.Types             as M
import qualified Marquise.Client            as M
import qualified Chevalier.Util             as C
import qualified Chevalier.Types            as C

import           Vaultaire.Query.Base
import           Vaultaire.Query.Combinators
import           Vaultaire.Query.Connection
import           Vaultaire.Control.Lift

-- Ranges ----------------------------------------------------------------------

spanPoints :: Monad m
           => ((b, b) -> a -> Bool)
           -> (b, b)                     -- ^ range that we are allowed to interpolate over
           -> Producer a m ()            -- ^ source of times that needs interpolating
           -> Producer a                 --   points from the above source that can be interpolated in this range
                       m
                       (Producer a m ()) --   the rest of the points (that cannot be interpolated in this range)
spanPoints interpolateable r = view $ P.span (interpolateable r)

inRange :: Monad m
        => ((b, b) -> a -> Bool)
        -> Pipe (b, b)                     -- ^ range for which we will yield interpolateable times
                ((b, b), a)                -- ^ range and a time from the underlying producer
                (StateT (Producer a m ())  -- ^ the underlying producer of points
                        m)
                ()
inRange f = forever $ do
  range   <- await
  points  <- lift get
  points' <- runEffect (for (hoist   (lift . lift)              -- lift the underlying monad @m@ of the spanPoints producer
                                   $ spanPoints f range points) --   into pipe over stateT land
                            (lift . yield . (range,)))          -- then yield all the points from the outer spanPoints producer
                                                                --   into the underlying monad (now a pipe stateT instead of `m`
                                                                --   because we have lifted)
  lift $ put points'                                            -- we get the "leftover" times (not interpolateable for this range)
                                                                --   back, so put that in the state.

-- | Given time series, e.g. @s1 = [ 0, 1, 2, 4, ... ]@ and @s2 = [ 0, 2, 5, ... ]@
--   assign for every time point in @s1@ a range from @s2@,
--   such that the point can be interpolated in that range.
--   e.g. @[ (0, (0,2)), (1, (0,2)), (2, (0,2)), (4, (2,5)) ... ]@
fitWith :: Monad m
        => ((b, b) -> a -> Bool)
        -> Query m a           -- ^ times at which we want to interpolate
        -> Query m b           -- ^ times on which we want to interpolate
        -> Query m ((b, b), a) -- ^ pair of a range from the second series
                               --   and a point from the first series that fits in said range
fitWith f points ranges = Select (enumerate (rangify ranges) >-> evalStateP (enumerate points) (inRange f))
  where rangify :: (Monad m) => Query m x -> Query m (x, x)
        rangify series = [ (x,y) | x <- series
                                 | y <- Select $ enumerate series >-> P.drop 1 ]

fitSimple :: Monad m
          => Query m SimplePoint
          -> Query m SimplePoint
          -> Query m ((SimplePoint, SimplePoint), SimplePoint)
fitSimple = fitWith interpolateable
  where interpolateable (p1, p2) p =  simpleTime p1 <= simpleTime p
                                   && simpleTime p  <= simpleTime p2


-- Alignment -------------------------------------------------------------------

barrier :: Monad m
        => (SimplePoint -> SimplePoint -> TimeStamp -> SimplePoint) -- ^ interpolation function
        -> Pipe SimplePoint
                SimplePoint
                (StateT ( Maybe SimplePoint
                        , Producer SimplePoint m ())
                        m)
                ()
barrier interp = forever $ do
  x <- await
  y <- lift $ get
  z <- go x y
  lift $ put z
  where go x (prev, barriers) = do
          lift (lift $ next barriers) >>= \b -> case b of
            -- no more times to interpolate, yield the rest of the series
            Left   _      -> yield x >> return (Just x, barriers)
            Right (y, p') -> case compare (simpleTime y) (simpleTime x) of
              -- missing some times, interpolate
              LT -> let prev'        = maybe x id prev
                        interpolated = interp prev' x (simpleTime y)
                    in  yield interpolated >> go x (prev, p')
              -- not missing these times
              GT -> yield x >> return (Just x, barriers)
              EQ -> yield x >> return (Just x, barriers)

-- | Align the first series to the times in the second series, e.g.
--   s1 = [     (2,a)     (5,b) ]
--   s2 = [ 0 1 2   4 5 ]
--   result would be [ (0,a) (1,a) (2,a) (4,b) (5,b) ]
--
align :: Monad m
      => (SourceDict, Query m SimplePoint) -- interpolate this series
      ->              Query m SimplePoint  -- with times from this one
      ->              Query m SimplePoint
align (sd, Select s1) (Select s2)
  = Select $ s1 >-> evalStateP (Nothing, s2) (barrier fun)

  where interpolate decode encode division x1 x2 t
          | simpleTime x1 == simpleTime x2 = SimplePoint (simpleAddress x1) t (simplePayload x1)
          | otherwise = let val1  = decode $ simplePayload x1
                            val2  = decode $ simplePayload x2
                            t1    = decode $ unTimeStamp $ simpleTime x1
                            t2    = decode $ unTimeStamp $ simpleTime x2
                            t'    = decode $ unTimeStamp t
                            val   = encode $ val1 + ((division (t' - t1) (t2 - t1) ) * (val2 - val1))
                        in  SimplePoint (simpleAddress x1) t val

        fun = case fmap T.unpack (lookupSource (T.pack "_float") sd) of
          Just "1" -> interpolate wordToDouble doubleToWord (/)
          _        -> interpolate fromIntegral id           div

-- Aggregation -----------------------------------------------------------------

-- | Sum the value (payload) of a series of simple data points.
sumPoints :: Monad m => Query m SimplePoint -> Query m Word64
sumPoints = aggregateQ (\p -> P.sum (p >-> P.map simplePayload))

-- | Openstack cumulative data is from last startup.
--   So when we process cumulative data we need to account for this.
--   Since (excluding restarts) each point is strictly non-decreasing,
--   we simply use a modified fold to deal with the case where the latest point
--   is less than the second latest point (indicating a restart)
aggregateCumulativePoints :: Monad m => Query m SimplePoint -> m Word64
aggregateCumulativePoints (Select points) = do
    res <- next points
    case res of
        Left _ -> return 0
        Right (p, points') -> do
            let v = simplePayload p
            P.fold helper (0, v) (\(a, b) -> a + b - v) points'
  where
    helper (sum, last) (SimplePoint _ _ v) =
        if v < last
            then (sum+last, v)
            else (sum, v)

-- | Lookup a metadata key.
lookupQ :: Monad m
        => String         -- ^ key
        -> SourceDict     -- ^ metadata map
        -> Query m String -- ^ result as a query
lookupQ s d = [ T.unpack x | x <- maybeQ $ lookupSource (T.pack s) d ]


-- Primimtives -----------------------------------------------------------------

-- | All addresses (and their metadata) from an origin.
addresses :: (MonadLogger m, MonadSafe m)
          => URI
          -> Origin
          -> Query m (Address, SourceDict) -- ^ result address and its metadata map
addresses uri origin = Select $ enumerateOrigin M.NoRetry uri origin

-- | Addresses whose metadata match (fuzzily) any in a set of metadata key-values.
--   e.g. @addressesAny origin [("nginx", "error-rates"), ("metric", "cpu")]@
addressesAny :: (MonadLogger m, MonadSafe m)
             => URI
             -> Origin
             -> [(String, String)]            -- ^ metadata key-value constraints (fuzzy on values)
             -> Query m (Address, SourceDict) -- ^ result address and its metadata map
addressesAny uri origin mds
 = [ (addr, sd)
   | (addr, sd) <- addresses uri origin
   , any (fuzzy sd) mds
   ]

-- | Addresses whose metadata match (fuzzily) all in a set of metadata key-values.
addressesAll :: (MonadLogger m, MonadSafe m)
             => URI
             -> Origin
             -> [(String, String)]            -- ^ metadata key-value constraints (fuzzy on values)
             -> Query m (Address, SourceDict) -- ^ result address and its metadata map
addressesAll uri origin mds
 = [ (addr, sd)
   | (addr, sd) <- addresses uri origin
   , all (fuzzy sd) mds
   ]

-- | Data points for an address over some period of time.
metrics :: (MonadSafe m, MonadLogger m)
        => URI
        -> Origin
        -> Address
        -> TimeStamp           -- ^ start
        -> TimeStamp           -- ^ end
        -> Query m SimplePoint -- ^ result data point
metrics uri origin addr start end
  = Select $ readSimplePoints M.NoRetry uri addr start end origin

-- | To construct event based data correctly we need to query over all time
eventMetrics :: (MonadLogger m, MonadSafe m)
             => URI
             -> Origin
             -> Address
             -> Query m SimplePoint -- ^ result data point
eventMetrics uri origin addr = Select $ do
  let start = TimeStamp 0
  end <- liftIO getCurrentTimeNanoseconds
  readSimplePoints M.NoRetry uri addr start end origin

-- Raw Marquise queries -------------------------------------------------------

readSimplePoints :: (MonadLogger m, MonadSafe m)
           => M.Policy
           -> URI -> Address -> TimeStamp -> TimeStamp -> Origin
           -> Producer SimplePoint m ()
readSimplePoints pol uri a s e o = runMarquiseReader uri $ do
  (MarquiseReader c) <- lift ask
  hoist liftIO $  catchMarquiseAll (M.readSimplePoints pol a s e o c)
                                   (\x -> lift $ M.logError $ show x)
               >> return ()

enumerateOrigin :: (MonadLogger m, MonadSafe m)
                => M.Policy
                -> URI -> Origin
                -> Producer (Address, SourceDict) m ()
enumerateOrigin pol uri o = runMarquiseContents uri $ do
  (MarquiseContents c) <- liftT ask
  hoist liftIO $  catchMarquiseAll (M.enumerateOrigin pol o c)
                                   (\e -> lift $ M.logError $ show e)
               >> return ()

-- Built-in Chevalier Queries --------------------------------------------------

addressesWith :: MonadSafe m
              => URI
              -> Origin
              -> C.SourceRequest
              -> Query m (Address, SourceDict)
addressesWith chev org request = runChevalier chev $ Select $ do
  c <- liftT ask
  hoist liftIO $ chevalier c org request

chevalier :: Chevalier -> Origin -> C.SourceRequest
          -> Producer (Address, SourceDict) IO ()
chevalier (Chevalier sock) origin request = do
  resp <- liftIO sendrecv
  -- this doesn't actually stream because chevalier doesn't
  each $ either (error . show) (rights . map C.convertSource) (C.decodeResponse resp)
  where sendrecv = do
          Z.send sock [Z.SendMore] $ encodeOrigin origin
          Z.send sock []           $ C.encodeRequest request
          Z.receive sock
        encodeOrigin (Origin x) = encodeUtf8 $ T.pack $ show x

-- Helpers ---------------------------------------------------------------------

fuzzy :: SourceDict -> (String, String) -> Bool
fuzzy sd (k,v) = case lookupSource (T.pack k) sd of
  Just a  -> T.pack v `T.isInfixOf` a
  Nothing -> False

fuzzyAny :: SourceDict -> [(String, String)] -> Bool
fuzzyAny sd = any (fuzzy sd)

fuzzyAll :: SourceDict -> [(String, String)] -> Bool
fuzzyAll sd = all (fuzzy sd)
