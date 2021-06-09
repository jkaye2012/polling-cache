import Control.Concurrent
import Data.Cache.Polling

gen :: IO Int
gen = return 3

main :: IO ()
main = do
  cache <- newPollingCache 5000 Ignore gen
  threadDelay 1000
  val <- cachedValues cache
  print val
