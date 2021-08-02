{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unused-record-wildcards #-}

-- | A cache implementation that periodically (and asynchronously) polls an external action for updated values.
module Data.Cache.Polling
  ( -- * Entry-point types and typeclasses
    MonadCache (..),
    PollingCache,

    -- * Types for working with cached results
    CacheMiss (..),
    CacheHit,
    CacheResult,

    -- * Types for cache creation
    FailureMode (..),
    DelayMode (..),
    ThreadDelay,
    CacheOptions (delayMode, failureMode, delayFuzzing),

    -- * Functions for creating and interacting with caches
    basicOptions,
    newPollingCache,
    cachedValue,
    stopPolling,
  )
where

import Control.Concurrent
import Control.Monad (unless)
import qualified Control.Monad.Catch as Exc
import Data.Cache.Internal
import Data.Functor ((<&>))
import Data.Time.Clock
import UnliftIO

-- | The supported "empty" states for a 'PollingCache'.
--
-- See 'CacheResult' for a more in-depth explanation of why this is necessary.
data CacheMiss
  = -- | A value has never been loaded into the cache.
    NotYetLoaded
  | -- | The external action used to populate the cache threw an exception at some point in time.
    LoadFailed UTCTime
  | -- | The cache has been shut down and can no longer be used.
    Stopped
  deriving (Eq, Show)

-- | A successfully cached value with the time at which it was generated.
type CacheHit a = (a, UTCTime)

-- | The result of reading a value from a 'PollingCache', including the possibility of failure.
--
-- Due to the asynchronous (and likely effectful) nature of executing external actions to populate
-- the cache, it's possible for the cache to be "empty" at any point in time. The possible empty
-- states are controlled by the 'FailureMode' selected by the user when creating the 'PollingCache'
-- instance.
type CacheResult a = Either CacheMiss (CacheHit a)

type CachePayload a = TVar (CacheResult a)

-- | An opaque type containing the internals necessary for background polling and caching.
--
-- Library functions will allow the user to create and interact with a 'PollingCache', but
-- the raw data is not exposed to users so that the library can maintain invariants.
data PollingCache a = PollingCache
  { mostRecentValues :: CachePayload a,
    threadId :: ThreadId
  }

-- | The minimum amount of time (in microseconds) that should pass before a cache reload is attempted.
type ThreadDelay = Int

isFailed :: CacheResult a -> Bool
isFailed (Left (LoadFailed _)) = True
isFailed _ = False

writeCacheFailure :: MonadCache m => CachePayload a -> UTCTime -> m ()
writeCacheFailure payload = atomically . writeTVar payload . Left . LoadFailed

handleFailure :: MonadCache m => FailureMode -> CachePayload a -> m ()
handleFailure Ignore _ = return ()
handleFailure EvictImmediately payload = do
  now <- currentTime
  current <- readTVarIO payload
  unless (isFailed current) $ writeCacheFailure payload now
handleFailure (EvictAfterTime limit) payload = do
  previousResult <- readTVarIO payload
  now <- currentTime
  let failed = previousResult <&> snd <&> (\prev -> diffUTCTime now prev >= limit)
  case failed of
    Right True -> writeCacheFailure payload now
    _ -> return ()

clamp :: Int -> Int -> Int -> Int
clamp mn mx val
  | val < mn = mn
  | val > mx = mx
  | otherwise = val

handleDelay :: MonadCache m => DelayMode a -> Maybe Int -> Either SomeException a -> m ()
handleDelay mode (Just fuzz) res = do
  fuzzDelay <- randomize (0, fuzz)
  delay fuzzDelay
  handleDelay' mode res
handleDelay mode Nothing res = handleDelay' mode res

handleDelay' :: MonadCache m => DelayMode a -> Either SomeException a -> m ()
handleDelay' (DelayForMicroseconds mics) _ = delay mics
handleDelay' (DelayDynamically f) r = delay $ f r
handleDelay' (DelayDynamicallyWithBounds (mn, mx) f) r =
  delay . clamp mn mx $ f r

-- | Create a 'CacheOptions' with basic functionality enabled.
--
-- Record update syntax can be use to further customize options created using this function:
--
-- > basicOpts = basicOptions (DelayForMicroseconds 60000000) EvictImmediately
-- > customOpts = basicOpts { delayFuzzing = Just 100 }
basicOptions :: DelayMode a -> FailureMode -> CacheOptions a
basicOptions d f = CacheOptions d f Nothing

-- | Creates a new 'PollingCache'.
--
-- The supplied action is used to generate values that are stored in the cache. The action is executed in the background
-- with its delay, failure, and fuzzing behavior controlled by the provided 'CacheOptions'.
newPollingCache :: forall a m. MonadCache m => CacheOptions a -> m a -> m (PollingCache a)
newPollingCache CacheOptions {..} generator = do
  tvar <- newTVarIO $ Left NotYetLoaded
  tid <- newThread $ cacheThread tvar
  return $ PollingCache tvar tid
  where
    cacheThread :: CachePayload a -> m ()
    cacheThread tvar = repeatedly $ do
      (result :: Either SomeException a) <- Exc.try generator
      case result of
        Left _ -> handleFailure failureMode tvar
        Right value -> do
          now <- currentTime
          atomically . writeTVar tvar $ Right (value, now)
      handleDelay delayMode delayFuzzing result

-- | Retrieve the current values from a 'PollingCache'.
cachedValue :: MonadCache m => PollingCache a -> m (CacheResult a)
cachedValue = readTVarIO . mostRecentValues

-- | Stops the background processing thread associated with a 'PollingCache'.
--
-- Calling this function will place the 'Stopped' value into the cache after stopping the processing thread,
-- ensuring that a 'PollingCache' that has been stopped can no longer be used to query stale values.
stopPolling :: MonadCache m => PollingCache a -> m ()
stopPolling PollingCache {..} = do
  killCache threadId
  atomically . writeTVar mostRecentValues $ Left Stopped
