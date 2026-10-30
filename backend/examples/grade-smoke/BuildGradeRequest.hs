{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Run from backend/. Uses production loaders and the request-body builder.
-- Does not load provider credentials or make network requests.
module Main where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BL
import Essaying.Persistence.Context (loadEffectiveContext)
import Essaying.Persistence.Workspace (loadWorkspaceEssay)
import Essaying.Provider.OpenAiCompatible (buildGradeRequestBody)
import Essaying.Types.Context (EffectiveContext (..))
import Essaying.Types.Storage (WorkspaceRoot (..))
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath ((</>))

-- | Resolve the saved sample inputs and write the production-built JSON request.
-- This helper neither loads credentials nor sends the request.
main :: IO ()
main = do
  args <- getArgs
  output <- case args of
    [directory] -> pure directory
    _ -> die "Usage: BuildGradeRequest.hs OUTPUT_DIRECTORY (run from backend/)"
  let root = WorkspaceRoot "examples/grade-smoke/workspace"
  resolved <- loadEffectiveContext root "Religion"
  context <- either (die . ("Context resolution failed: " <>) . show) pure resolved
  loaded <- loadWorkspaceEssay root ["Religion"]
  essay <- maybe (die "Sample essay could not be loaded.") pure loaded
  case context of
    EffectiveContext{model = Nothing} -> die "Sample context must select a model."
    EffectiveContext{model = Just selectedModel} -> do
      createDirectoryIfMissing True output
      BL.writeFile (output </> "effective-context.json") (encode context)
      BL.writeFile (output </> "saved-essay.json") (encode essay)
      BL.writeFile (output </> "request.json")
        (encode (buildGradeRequestBody selectedModel context essay))
      putStrLn ("Wrote effective-context.json, saved-essay.json, and request.json to " <> output)
