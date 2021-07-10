{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
    ThreadDelay,

    -- * Functions for creating and interacting with caches
    newPollingCache,
    cachedValues,
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

-- | The supported failure handling modes for a 'PollingCache' instance.
--
-- In the context of the cache action, "failure" means an Exception thrown from
-- the user-supplied action that generates values to populate the cache.
--
-- Because these operations are performed in a background thread, the user must decide how failures are to be handled
-- upon cache creation.
data FailureMode
  = -- | Failures should be ignored entirely; the most relaxed failure handling strategy.
    --
    -- This means that 'LoadFailed' will never be populated as a cache result.
    Ignore
  | -- | If a failure occurs, any previously cached value is immediately evicted from the cache; the strictest failure handling strategy.
    EvictImmediately
  | -- | Failures will be ignored unless they persist beyond the supplied time span.
    --
    -- This is a middle-ground failure handling strategy that probably makes sense to use in most scenarios.
    -- The nature of asynchronous polling implies that somewhat stale values are not an issue to the consumer;
    -- therefore, allowing some level of transient failure can often improve reliability without sacrificing correctness.
    EvictAfterTime NominalDiffTime
  deriving (Eq, Show)

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

-- | Creates a new 'PollingCache'.
--
-- The supplied action is used to generate values that are stored in the cache. The action is executed in the background
-- with a delay of at least 'ThreadDelay' microseconds between invocations.
-- The supplied 'FailureMode' determines how the cache will treat any Exceptions thrown by the supplied action.
newPollingCache :: forall a m. MonadCache m => ThreadDelay -> FailureMode -> m a -> m (PollingCache a)
newPollingCache microseconds mode generator = do
  tvar <- newTVarIO $ Left NotYetLoaded
  tid <- newThread $ cacheThread tvar
  return $ PollingCache tvar tid
  where
    cacheThread :: CachePayload a -> m ()
    cacheThread tvar = repeatedly $ do
      (result :: Either SomeException a) <- Exc.try generator
      case result of
        Left _ -> handleFailure mode tvar
        Right value -> do
          now <- currentTime
          atomically . writeTVar tvar $ Right (value, now)
      delay microseconds

-- | Retrieve the current values from a 'PollingCache'.
cachedValues :: MonadCache m => PollingCache a -> m (CacheResult a)
cachedValues = readTVarIO . mostRecentValues

-- | Stops the background processing thread associated with a 'PollingCache'.
--
-- Calling this function will place the 'Stopped' value into the cache after stopping the processing thread,
-- ensuring that a 'PollingCache' that has been stopped can no longer be used to query stale values.
stopPolling :: MonadCache m => PollingCache a -> m ()
stopPolling PollingCache {..} = do
  killCache threadId
  atomically . writeTVar mostRecentValues $ Left Stopped
