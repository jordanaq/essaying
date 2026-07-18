module Essaying.Persistence.Account
  ( CreateAccountProfileResult (..)
  , createAccountProfile
  , deleteAccountProfile
  , saveAccountProfile
  , readAccountProfile
  , getAccountNames
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (decodeFileStrict', encode)
import Data.List (sort)
import Essaying.Storage (profileRoot, workspaceRoot)
import Essaying.Types.Account (AccountProfile)
import Essaying.Types.Storage (AccountRoot (..), UsersRoot (..), WorkspaceRoot (..))
import Essaying.Utils (isValidAccountName)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removePathForcibly)
import System.FilePath (takeDirectory)
import System.IO.Error (isAlreadyExistsError)
import qualified Data.ByteString.Lazy as BL

data CreateAccountProfileResult
  = AccountCreated
  | AccountAlreadyExists
  deriving (Eq, Show)

saveAccountProfile :: AccountRoot -> AccountProfile -> IO ()
saveAccountProfile accountRoot profile = do
  let profilePath = profileRoot accountRoot
      WorkspaceRoot workspacePath = workspaceRoot accountRoot

  createDirectoryIfMissing True workspacePath
  BL.writeFile profilePath (encode profile)

createAccountProfile :: AccountRoot -> AccountProfile -> IO CreateAccountProfileResult
createAccountProfile accountRoot@(AccountRoot accountRootPath) profile = do
  -- Ensure the users root exists before attempting an atomic account-dir claim.
  createDirectoryIfMissing True (takeDirectory accountRootPath)
  dirResult <- try (createDirectory accountRootPath) :: IO (Either IOException ())
  case dirResult of
    Left ioErr
      | isAlreadyExistsError ioErr -> pure AccountAlreadyExists
      | otherwise -> ioError ioErr
    Right () -> do
      saveAccountProfile accountRoot profile
      pure AccountCreated

deleteAccountProfile :: AccountRoot -> IO Bool
deleteAccountProfile (AccountRoot accountRootPath) = do
  dirExists <- doesDirectoryExist accountRootPath
  if dirExists
    then do
      removePathForcibly accountRootPath
      pure True
    else pure False

readAccountProfile :: AccountRoot -> IO (Maybe AccountProfile)
readAccountProfile accountRoot = do
  let profilePath = profileRoot accountRoot

  exists <- doesFileExist profilePath
  if not exists
    then pure Nothing
    else decodeFileStrict' profilePath

getAccountNames :: UsersRoot -> IO [Text]
getAccountNames (UsersRoot usersRootPath) = do
  entries <- map Text.pack <$> listDirectory usersRootPath
  let accountNames = sort $ filter isValidAccountName entries
  pure accountNames