{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Essaying.Server (app)
import Network.Wai.Handler.Warp (run)

main :: IO ()
main = do
  putStrLn "Starting haskell-essaying backend on http://127.0.0.1:8080"
  run 8080 app
