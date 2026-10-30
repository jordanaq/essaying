module Essaying.Persistence.Utils (
  PathCheckError (..),
  checkPathEntries,
) where

import Control.Exception (IOException, try)
import System.Directory (pathIsSymbolicLink)
import System.FilePath (makeRelative)
import System.IO.Error (isDoesNotExistError)

-- | Filesystem failures with labels relative to the caller's root.
data PathCheckError
  = PathSymbolicLink FilePath
  | PathMissingParent FilePath IOException
  | PathIoError FilePath IOException
  deriving (Show)

{- | Inspect ordered path prefixes, stopping before following a symbolic link.
Missing final entries return False; missing parents and other IO failures are
errors. The caller supplies validated prefixes including its root and target.
This checks links, not file types, and is not atomic with later filesystem IO.
-}
checkPathEntries :: FilePath -> [FilePath] -> IO (Either PathCheckError Bool)
checkPathEntries _ [] = pure (Right True)
checkPathEntries root (fullPath : remaining) = do
  let label = makeRelative root fullPath
  checked <- try (pathIsSymbolicLink fullPath)
  case checked of
    Right True -> pure (Left (PathSymbolicLink label))
    Right False -> checkPathEntries root remaining
    Left err
      | isDoesNotExistError err && null remaining -> pure (Right False)
      | isDoesNotExistError err -> pure (Left (PathMissingParent label err))
      | otherwise -> pure (Left (PathIoError label err))
