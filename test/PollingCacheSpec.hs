{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}

module FailureSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.State.Strict
import Data.Cache.Polling
import Data.Either (isRight)
import Data.Time
import Data.Time.Calendar.OrdinalDate
import Test.Hspec

data TestState = TestState
  { now :: UTCTime,
    numIterations :: Int,
    maxIterations :: Int
  }
  deriving (Show)

type TestCache a = StateT TestState IO a

instance MonadCache (StateT TestState IO) where
  currentTime = gets now
  delay us = do
    let diff = realToFrac us
    st@TestState {..} <- get
    put $ st {now = addUTCTime diff now}
  newThread act = go
    where
      step st@TestState {..} = st {numIterations = numIterations + 1}
      go = do
        withStateT step act
        TestState {..} <- get
        if numIterations >= maxIterations
          then lift myThreadId
          else go
  killCache _ = return ()

testDay :: Day
testDay = fromOrdinalDate 0 0

testTime :: DiffTime -> UTCTime
testTime = UTCTime testDay

testState :: Int -> TestState
testState = TestState (testTime 0) 0

data TestException = TestException deriving (Show)

instance Exception TestException

alwaysSucceeds :: TestCache Int
alwaysSucceeds = return 123

alwaysSucceedsIO :: IO Int
alwaysSucceedsIO = return 123

alwaysFails :: TestCache Int
alwaysFails = throw TestException

secondPassFails :: TestCache Int
secondPassFails = do
  TestState {..} <- get
  when (numIterations == 2) $ throw TestException
  return 234

secondPassSucceeds :: TestCache Int
secondPassSucceeds = do
  iteration <- gets numIterations
  if iteration == 2
    then return 12190
    else throw TestException

transientFailure :: Int -> Int -> TestCache Int
transientFailure startFailing stopFailing = do
  iteration <- gets numIterations
  if iteration >= startFailing && iteration <= stopFailing
    then throw TestException
    else return 81590

spec :: Spec
spec = do
  basicFunctionalitySpec
  ignoreSpec
  evictImmediatelySpec
  evictAfterTimeSpec

basicFunctionalitySpec :: Spec
basicFunctionalitySpec =
  context "Basic functionality" $ do
    describe "background processing thread" $ do
      let testCache = newPollingCache 100 Ignore alwaysSucceeds
      it "will suspend background execution for the time span specified by the user" $ do
        cache <- evalStateT testCache $ testState 4
        val <- cachedValues cache
        val `shouldBe` Right (123, testTime 300)

    describe "after stopping cache" $ do
      it "will no longer return valid values" $ do
        cache <- newPollingCache 100 Ignore alwaysSucceedsIO
        stopPolling cache
        val <- cachedValues cache
        val `shouldBe` Left Stopped

    describe "IO actions" $ do
      it "will be executed in a background thread" $ do
        cache <- newPollingCache 1 Ignore alwaysSucceedsIO
        threadDelay 10
        val <- cachedValues cache
        val `shouldSatisfy` isRight
        stopPolling cache

ignoreSpec :: Spec
ignoreSpec =
  context "Ignoring faliure" $ do
    describe "without succeeding" $ do
      let testCache = newPollingCache 10 Ignore alwaysFails
      it "will never load a value" $ do
        cache <- evalStateT testCache $ testState 10
        val <- cachedValues cache
        val `shouldBe` Left NotYetLoaded

    describe "after succeeding once" $ do
      let testCache = newPollingCache 10 Ignore secondPassSucceeds
      it "will always return the successful result" $ do
        cache <- evalStateT testCache $ testState 10
        val <- cachedValues cache
        val `shouldBe` Right (12190, testTime 10)

evictImmediatelySpec :: Spec
evictImmediatelySpec =
  context "Evicting immediately upon failure" $ do
    describe "with a constant generator" $ do
      let testCache = newPollingCache 10 EvictImmediately alwaysSucceeds
      it "will continually return the generated value" $ do
        (cache, st) <- runStateT testCache $ testState 1
        val <- cachedValues cache
        val `shouldBe` Right (123, testTime 0)
        nextCache <- evalStateT testCache st
        nextVal <- cachedValues nextCache
        nextVal `shouldBe` Right (123, testTime 10)

    describe "with a sporadic failure" $ do
      let testCache = newPollingCache 10 EvictImmediately secondPassFails
      it "will report the failure" $ do
        cache <- evalStateT testCache $ testState 2
        val <- cachedValues cache
        val `shouldBe` (Left . LoadFailed $ testTime 10)

      it "will succeed after failure" $ do
        cache <- evalStateT testCache $ testState 10
        val <- cachedValues cache
        val `shouldBe` Right (234, testTime 90)

    describe "with a persistent failure" $ do
      let testCache = newPollingCache 10 EvictImmediately alwaysFails
      it "will not update the original failure time" $ do
        cache <- evalStateT testCache $ testState 10
        val <- cachedValues cache
        val `shouldBe` (Left . LoadFailed $ testTime 0)

evictAfterTimeSpec :: Spec
evictAfterTimeSpec =
  context "Evicting after a time interval" $ do
    describe "with a transient failure" $ do
      let testCache = newPollingCache 10 (EvictAfterTime 30) (transientFailure 3 8)
      it "will not report the failure before the cut-off period" $ do
        cache <- evalStateT testCache $ testState 2
        val <- cachedValues cache
        val `shouldBe` Right (81590, testTime 10)

      it "will report the failure after the cut-off period" $ do
        cache <- evalStateT testCache $ testState 5
        val <- cachedValues cache
        val `shouldBe` (Left . LoadFailed $ testTime 40)

      it "will not overwrite the failure time for successive failures" $ do
        cache <- evalStateT testCache $ testState 7
        val <- cachedValues cache
        val `shouldBe` (Left . LoadFailed $ testTime 40)

      it "will report success after the failure subsides" $ do
        cache <- evalStateT testCache $ testState 10
        val <- cachedValues cache
        val `shouldBe` Right (81590, testTime 90)
