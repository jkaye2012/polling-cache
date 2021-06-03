{-# LANGUAGE MultiParamTypeClasses #-}

-- | Pre-built typeclass instances.
module Data.Cache.Polling.Instances (StaticCache (..), PollingCacheIO) where

import Data.Cache.Polling.Class
import Data.Time.Clock (NominalDiffTime, UTCTime)

-- | A `PollingCache` that returns a static list of values.
--
-- This is mainly useful for testing purposes.
newtype StaticCache a = StaticCache {unStaticCache :: [a]}

instance PollingCache StaticCache [] where
  cachedValues = return . Right . unStaticCache

data PollingCacheIO a = PollingCacheIO
  { mostRecentValues :: Either String [a],
    -- TODO: replace most recent values and last refresh time with STM
    timeBetweenRefreshes :: NominalDiffTime, -- TODO: might not need this, fire event on interval timer?
    lastRefreshTime :: Maybe UTCTime,
    refresher :: IO [a] -- TODO: might not need this, fire event on interval timer?
  }

instance PollingCache PollingCacheIO [] where
  cachedValues = return . mostRecentValues
