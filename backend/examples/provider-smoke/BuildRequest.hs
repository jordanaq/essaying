{-# LANGUAGE DisambiguateRecordFields #-}

-- Run from backend/. Generates fixtures only; never reads a key or calls an API.
module Main where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BL
import Data.Text.IO qualified as TextIO
import Essaying.Persistence.Context (loadEffectiveContext)
import Essaying.Provider.OpenAiCompatible (buildPromptRequestBody)
import Essaying.Types.Context (EffectiveContext (..))
import Essaying.Types.Storage (WorkspaceRoot (..))
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath ((</>))

main :: IO ()
main = do
  args <- getArgs
  output <- case args of
    [directory] -> pure directory
    _ -> die "Usage: BuildRequest.hs OUTPUT_DIRECTORY (run from backend/)"
  let sample = "examples/provider-smoke"
  instructions <- TextIO.readFile (sample </> "extra-instructions.txt")
  resolved <- loadEffectiveContext (WorkspaceRoot (sample </> "workspace")) "Religion"
  case resolved of
    Left err -> die ("Context resolution failed: " <> show err)
    Right context -> case context of
      EffectiveContext {model = Nothing} -> die "Sample context must select a model."
      EffectiveContext {model = Just selectedModel} -> do
        createDirectoryIfMissing True output
        BL.writeFile (output </> "effective-context.json") (encode context)
        BL.writeFile (output </> "request.json")
          (encode (buildPromptRequestBody selectedModel context (Just instructions)))
        putStrLn ("Wrote effective-context.json and request.json to " <> output)
