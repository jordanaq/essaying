module Essaying.Persistence.Account (
  createAccountProfile,
  deleteAccountProfile,
  saveAccountProfile,
  readAccountProfile,
  getAccountNames,
)
where

import Control.Exception (IOException, try)
import Data.Aeson (decodeFileStrict', encode)
import Data.ByteString.Lazy qualified as BL
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Essaying.Storage (profileRoot, workspaceRoot)
import Essaying.Types.Account (AccountId (..), AccountProfile (..), CreateAccountProfileResult (..))
import Essaying.Types.Storage (AccountRoot (..), UsersRoot (..), WorkspaceRoot (..), unAccountRoot)
import Essaying.Utils (debug_, isValidAccountName)
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removePathForcibly)
import System.FilePath (takeDirectory, takeFileName)
import System.IO.Error (isAlreadyExistsError)

debug :: Int -> String -> IO ()
debug = debug_ "[Account]"

expectedAccountIdText :: AccountRoot -> Text
expectedAccountIdText accountRoot = Text.pack (takeFileName (unAccountRoot accountRoot))

accountProfileMatchesRoot :: AccountRoot -> AccountProfile -> Bool
accountProfileMatchesRoot accountRoot (AccountProfile (AccountId accountIdText) _ _) =
  accountIdText == expectedAccountIdText accountRoot

saveAccountProfile :: AccountRoot -> AccountProfile -> IO ()
saveAccountProfile accountRoot profile = do
  if accountProfileMatchesRoot accountRoot profile
    then pure ()
    else ioError $ userError "AccountId mismatch: profile accountId does not match account directory"

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
      debug 1 $ "Created account root=" <> show accountRootPath
      pure AccountCreated

deleteAccountProfile :: AccountRoot -> IO Bool
deleteAccountProfile (AccountRoot accountRootPath) = do
  dirExists <- doesDirectoryExist accountRootPath
  if dirExists
    then do
      removePathForcibly accountRootPath
      debug 1 $ "Deleted account root=" <> show accountRootPath
      pure True
    else pure False

readAccountProfile :: AccountRoot -> IO (Maybe AccountProfile)
readAccountProfile accountRoot = do
  let profilePath = profileRoot accountRoot

  -- Read profile if it exists; treat malformed or inconsistent data as missing.
  exists <- doesFileExist profilePath
  profile <-
    if exists
      then decodeFileStrict' profilePath
      else pure Nothing

  case profile of
    Just decodedProfile
      | accountProfileMatchesRoot accountRoot decodedProfile -> pure profile
      | otherwise -> do
          let AccountProfile (AccountId accountIdText) _ _ = decodedProfile
              expectedId = expectedAccountIdText accountRoot
          debug 1 $
            "Ignoring profile with mismatched AccountId in "
              <> profilePath
              <> ": found="
              <> Text.unpack accountIdText
              <> ", expected="
              <> Text.unpack expectedId
          pure Nothing
    Nothing -> pure Nothing

getAccountNames :: UsersRoot -> IO [Text]
getAccountNames (UsersRoot usersRootPath) = do
  entries <- map Text.pack <$> listDirectory usersRootPath
  let accountNames = sort $ filter isValidAccountName entries
  pure accountNames
