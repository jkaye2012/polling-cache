module Data.Cache.Polling
  ( newPollingCache,
    cachedValues,
    stopPolling,
    CacheMiss (..),
    CacheHit,
    CacheResult,
    FailureMode (..),
    ThreadDelay,
  )
where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad (when)
import Data.Either (isRight)
import Data.Functor ((<&>))
import Data.Time.Clock
import UnliftIO.Exception

-- TODO: a way for different caches to share threads

data CacheMiss
  = NotYetLoaded
  | LoadFailed UTCTime
  deriving (Eq, Show)

type CacheHit a = (a, UTCTime)

type CacheResult a = Either CacheMiss (CacheHit a)

type CachePayload a = TVar (CacheResult a)

data PollingCache a = PollingCache
  { mostRecentValues :: CachePayload a,
    threadId :: ThreadId
  }

type ThreadDelay = Int

data FailureMode
  = Ignore
  | EvictImmediately
  | EvictAfterTime NominalDiffTime
  deriving (Eq, Show)

cacheFailed :: CachePayload a -> UTCTime -> IO ()
cacheFailed payload = atomically . writeTVar payload . Left . LoadFailed

-- TODO: make these somehow testable
handleFailure :: FailureMode -> CachePayload a -> IO ()
handleFailure Ignore _ = return ()
handleFailure EvictImmediately payload = do
  now <- getCurrentTime
  current <- readTVarIO payload
  when (isRight current) $ cacheFailed payload now
handleFailure (EvictAfterTime limit) payload = do
  previousResult <- readTVarIO payload
  now <- getCurrentTime
  let failed = previousResult <&> snd <&> (\prev -> diffUTCTime now prev >= limit)
  case failed of
    Right True -> cacheFailed payload now
    _ -> return ()

newPollingCache :: ThreadDelay -> FailureMode -> IO a -> IO (PollingCache a)
newPollingCache microseconds mode generator = do
  tvar <- newTVarIO $ Left NotYetLoaded
  tid <- forkIO $ cacheThread tvar
  return $ PollingCache tvar tid
  where
    cacheThread tvar = do
      result <- tryAny generator
      case result of
        Left _ -> handleFailure mode tvar
        Right value -> do
          now <- getCurrentTime
          atomically . writeTVar tvar $ Right (value, now)
      threadDelay microseconds

cachedValues :: PollingCache a -> IO (CacheResult a)
cachedValues = readTVarIO . mostRecentValues

stopPolling :: PollingCache a -> IO ()
stopPolling = killThread . threadId
