module Essaying.Storage
  ( resolveCacheRoot
  , usersRoot
  , accountRoot
  , workspaceRoot
  , profileRoot
  , defaultCachePath
  )
where

import System.Directory (createDirectoryIfMissing, getHomeDirectory, makeAbsolute)
import System.FilePath ((</>), normalise)
import Data.List (isPrefixOf)
import qualified Data.Text as Text

import Essaying.Utils (lookupEnvClean, debug_)
import Essaying.Types.Storage (CacheRoot (..), UsersRoot (..), AccountRoot (..), WorkspaceRoot (..), relativeUsersRoot)
import Essaying.Types.Account (AccountId (..))


debug :: Int -> String -> IO ()
debug = debug_ "[Storage]"


defaultCachePath :: FilePath
defaultCachePath = "~/.cache/hessaying"

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


expandTilde :: FilePath -> IO FilePath
expandTilde "~" = getHomeDirectory
expandTilde p
  | "~/" `isPrefixOf` p = do
      home <- getHomeDirectory
      pure (home </> drop 2 p)
  | otherwise = pure p


usersRoot :: CacheRoot -> UsersRoot
usersRoot (CacheRoot cacheRootPath) = UsersRoot (cacheRootPath </> relativeUsersRoot)


accountRoot :: UsersRoot -> AccountId -> AccountRoot
accountRoot (UsersRoot usersRootPath) (AccountId accountIdText) =
  AccountRoot (usersRootPath </> Text.unpack accountIdText)


workspaceRoot :: AccountRoot -> WorkspaceRoot
workspaceRoot (AccountRoot accountRootPath) = WorkspaceRoot (accountRootPath </> "workspace")


profileRoot :: AccountRoot -> FilePath
profileRoot (AccountRoot accountRootPath) = accountRootPath </> "profile.json"
