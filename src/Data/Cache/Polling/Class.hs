{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Typeclass definitions for `PollingCache`.
module Data.Cache.Polling.Class (PollingCache (..)) where

import UnliftIO (MonadUnliftIO)

-- | Caches can retrieve the most recent values for a type with the possibililty for failure.
class Functor f => PollingCache (c :: * -> *) f | c -> f where
  cachedValues :: MonadUnliftIO m => c a -> m (Either String (f a)) -- TODO: better error type?
