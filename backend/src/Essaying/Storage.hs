module Essaying.Storage (
  resolveCacheRoot,
  usersRoot,
  accountRoot,
  workspaceRoot,
  profileRoot,
  defaultCachePath,
)
where

import Data.List (isPrefixOf)
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing, getHomeDirectory, makeAbsolute)
import System.FilePath (normalise, (</>))

import Essaying.Types.Account (AccountId (..))
import Essaying.Types.Storage (AccountRoot (..), CacheRoot (..), UsersRoot (..), WorkspaceRoot (..), relativeUsersRoot)
import Essaying.Utils (debug_, lookupEnvClean)

-- | Emit storage messages at the requested @HESSAY_DEBUG@ level.
debug :: Int -> String -> IO ()
debug = debug_ "[Storage]"

-- | Default cache location before home-directory expansion.
defaultCachePath :: FilePath
defaultCachePath = "~/.cache/hessaying"

{- | Use trimmed, nonblank @HESSAY_CACHE@ or fall back to @~/.cache/hessaying@.
Expand the current-user tilde, make the path absolute, normalize it, and
create the cache directory. Filesystem exceptions propagate.
-}
resolveCacheRoot :: IO CacheRoot
resolveCacheRoot = do
  hessayCacheEnv <- lookupEnvClean "HESSAY_CACHE"

  let raw = case hessayCacheEnv of
        Just s -> Text.unpack s
        Nothing -> defaultCachePath

  expanded <- expandTilde raw
  absPath <- makeAbsolute expanded

  let normalized = normalise absPath

  debug 3 $ "Resolved cache root: " <> normalized

  createDirectoryIfMissing True normalized

  pure (CacheRoot normalized)

{- | Expand @~@ and the @~/@ prefix using the current user's home directory.
Other paths, including named-user tilde forms, are returned unchanged.
-}
expandTilde :: FilePath -> IO FilePath
expandTilde "~" = getHomeDirectory
expandTilde p
  | "~/" `isPrefixOf` p = do
      home <- getHomeDirectory
      pure (home </> drop 2 p)
  | otherwise = pure p

-- | Construct the users directory path without creating it.
usersRoot :: CacheRoot -> UsersRoot
usersRoot (CacheRoot cacheRootPath) = UsersRoot (cacheRootPath </> relativeUsersRoot)

{- | Append the supplied account ID to the users root. This only constructs
a path; it neither validates the ID nor creates or checks the directory.
-}
accountRoot :: UsersRoot -> AccountId -> AccountRoot
accountRoot (UsersRoot usersRootPath) (AccountId accountIdText) =
  AccountRoot (usersRootPath </> Text.unpack accountIdText)

-- | Construct the account's @workspace@ path without filesystem access.
workspaceRoot :: AccountRoot -> WorkspaceRoot
workspaceRoot (AccountRoot accountRootPath) = WorkspaceRoot (accountRootPath </> "workspace")

-- | Construct the account's @profile.json@ path without filesystem access.
profileRoot :: AccountRoot -> FilePath
profileRoot (AccountRoot accountRootPath) = accountRootPath </> "profile.json"
