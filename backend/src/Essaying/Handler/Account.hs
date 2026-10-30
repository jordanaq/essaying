{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Account (
  accountHandler,
)
where

import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Essaying.API.V1 (AccountApi, AccountsApi)
import Essaying.Handler.Workspace (workspaceHandler)
import Essaying.Persistence.Account (
  createAccountProfile,
  deleteAccountProfile,
  getAccountNames,
  readAccountProfile,
  saveAccountProfile,
 )
import Essaying.Storage (accountRoot, resolveCacheRoot, usersRoot)
import Essaying.Types.Account (
  AccountId (..),
  AccountProfile (..),
  CreateAccountProfileResult (..),
  CreateAccountRequest (..),
  UpdateAccountRequest (..),
 )
import Essaying.Utils (debug_, isValidAccountName, slugifyText)
import Servant (Handler, NoContent (NoContent), Server, err400, err404, err409, throwError, (:<|>) (..))

-- | Compose account listing, creation, and account-specific routes.
accountHandler :: Server AccountsApi
accountHandler =
  listAccountsHandler
    :<|> createAccountHandler
    :<|> accountByIdHandler

{- | Load profiles in sorted account-name order. A missing, malformed, or
inconsistent profile causes the whole request to return 404; I/O errors propagate.
-}
listAccountsHandler :: Handler [AccountProfile]
listAccountsHandler = do
  cacheRoot <- liftIO resolveCacheRoot
  let usersRootPath = usersRoot cacheRoot
  accountNames <- liftIO $ getAccountNames usersRootPath
  profiles <- mapM getAccountProfileHandler accountNames
  pure profiles

{- | Validate the display name and claim its slug as a new account directory.
Invalid names return 400; an existing directory returns 409.
-}
createAccountHandler :: CreateAccountRequest -> Handler AccountProfile
createAccountHandler req = do
  let CreateAccountRequest reqDisplayName reqPreferredModel = req

  if not (isValidAccountName reqDisplayName)
    then throwError err400
    else pure ()

  cacheRoot <- liftIO resolveCacheRoot
  let acctId = makeAccountId reqDisplayName
      acctRoot = accountRoot (usersRoot cacheRoot) acctId
      profile = AccountProfile acctId reqDisplayName reqPreferredModel

  createResult <- liftIO $ createAccountProfile acctRoot profile
  case createResult of
    AccountAlreadyExists -> throwError err409
    AccountCreated -> pure ()

  pure profile

{- | Recursively remove the account directory, including its workspace.
Return 404 when the account directory is absent; I/O errors propagate.
-}
deleteAccountHandler :: Text -> Handler NoContent
deleteAccountHandler accountIdText = do
  cacheRoot <- liftIO resolveCacheRoot
  let acctRoot = accountRoot (usersRoot cacheRoot) (AccountId accountIdText)
  deleted <- liftIO $ deleteAccountProfile acctRoot
  if deleted
    then pure NoContent
    else throwError err404

-- | Bind profile, deletion, and workspace routes to the captured account ID.
accountByIdHandler :: Text -> Server AccountApi
accountByIdHandler accountIdText =
  getAccountProfileHandler accountIdText
    :<|> updateAccountProfileHandler accountIdText
    :<|> deleteAccountHandler accountIdText
    :<|> workspaceHandler accountIdText

-- | Read a profile, returning 404 for missing, malformed, or mismatched data.
getAccountProfileHandler :: Text -> Handler AccountProfile
getAccountProfileHandler accountIdText = do
  cacheRoot <- liftIO resolveCacheRoot
  let acctRoot = accountRoot (usersRoot cacheRoot) (AccountId accountIdText)

  decoded <- liftIO $ readAccountProfile acctRoot
  case decoded of
    Nothing -> throwError err404
    Just profile -> pure profile

{- | Update supplied profile fields while preserving the account ID.
Omitted or null fields retain their current values, so this request cannot
clear the preferred model. Invalid names return 400; missing profiles return 404.
-}
updateAccountProfileHandler :: Text -> UpdateAccountRequest -> Handler AccountProfile
updateAccountProfileHandler accountIdText req = do
  existing <- getAccountProfileHandler accountIdText
  let AccountProfile _ existingDisplayName existingPreferredModel = existing
  let UpdateAccountRequest reqDisplayName reqPreferredModel = req
      nextDisplayName = fromMaybe existingDisplayName reqDisplayName
      nextPreferredModel =
        case reqPreferredModel of
          Nothing -> existingPreferredModel
          Just modelText -> Just modelText

  if not (isValidAccountName nextDisplayName)
    then throwError err400
    else pure ()

  cacheRoot <- liftIO resolveCacheRoot
  let acctRoot = accountRoot (usersRoot cacheRoot) (AccountId accountIdText)
      updated = AccountProfile (AccountId accountIdText) nextDisplayName nextPreferredModel

  liftIO $ saveAccountProfile acctRoot updated
  liftIO $ debug_ "[Account]" 2 $ "Updated profile account=" <> show accountIdText
  pure updated

-- | Derive the stable directory ID from the display name using slug normalization.
makeAccountId :: Text -> AccountId
makeAccountId = AccountId . slugifyText
