module Essaying.Utils
  ( trimStr
  , debug_
  )
where

import Control.Monad (when)
import System.Environment (lookupEnv)
import Data.Char (isSpace)


trimStr :: String -> String
trimStr = f . f
  where f = reverse . dropWhile isSpace

debug_ :: String -> Int -> String -> IO ()
debug_ pre level out = do
  dbg <- lookupEnv "HESSAY_DEBUG"
  when (dbg == Just (show level)) $ putStrLn (pre <> " " <> out)