-- | Caching implementation internals.
--
-- This module is not part of the Data.Cache public API and should not be directly relied upon by users.
-- Anything meant for external use defined here will be re-exported by a public module.
module Data.Cache.Internal
  ( MonadCache (..),
  )
where

import Control.Concurrent
import Control.Monad (forever)
import Control.Monad.Catch
import Control.Monad.IO.Class
import Data.Time

-- | The top-level 'Monad' in which caching operations are performed.
--
-- This exists primarily for testing purposes. Production uses should drop in 'IO' and forget that this exists.
class (MonadCatch m, MonadIO m) => MonadCache m where
  -- | The current system time.
  currentTime :: m UTCTime

  -- | Delay execution of the current thread for a number of microseconds.
  delay :: Int -> m ()

  -- | Spawn a new thread of execution to run an action.
  newThread :: m () -> m ThreadId

  -- | Run an action forever.
  repeatedly :: m () -> m ()

  -- | Stop a thread of execution. The thread can be assumed to have been started using 'newThread'.
  killCache :: ThreadId -> m ()

instance MonadCache IO where
  currentTime = getCurrentTime
  delay = threadDelay
  newThread = forkIO
  repeatedly = forever
  killCache = killThread
