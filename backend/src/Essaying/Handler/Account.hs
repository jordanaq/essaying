{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Account
  ( accountHandler
  )
where

import Data.Text (Text)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Essaying.Utils (isValidAccountName, slugifyText)
import Essaying.Persistence.Account
  ( CreateAccountProfileResult (..)
  , createAccountProfile
  , deleteAccountProfile
  , getAccountNames
  , readAccountProfile
  , saveAccountProfile
  )
import Essaying.Storage (accountRoot, resolveCacheRoot, usersRoot)
import Essaying.Types.Account
  ( AccountId (..)
  , AccountProfile (..)
  , CreateAccountRequest (..)
  , UpdateAccountRequest (..)
  )
import Servant (Handler, NoContent (NoContent), err400, err404, err409, throwError, (:<|>) (..))

accountHandler ::
  Handler [AccountProfile]
    :<|> (CreateAccountRequest -> Handler AccountProfile)
    :<|> (Text -> (Handler AccountProfile :<|> (UpdateAccountRequest -> Handler AccountProfile) :<|> Handler NoContent))
accountHandler =
  listAccountsHandler
    :<|> createAccountHandler
    :<|> accountByIdHandler

listAccountsHandler :: Handler [AccountProfile]
listAccountsHandler = do
  cacheRoot <- liftIO resolveCacheRoot
  let usersRootPath = usersRoot cacheRoot
  accountNames <- liftIO $ getAccountNames usersRootPath
  profiles <- mapM getAccountProfileHandler accountNames
  pure profiles

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

deleteAccountHandler :: Text -> Handler NoContent
deleteAccountHandler accountIdText = do
  cacheRoot <- liftIO resolveCacheRoot
  let acctRoot = accountRoot (usersRoot cacheRoot) (AccountId accountIdText)
  deleted <- liftIO $ deleteAccountProfile acctRoot
  if deleted
    then pure NoContent
    else throwError err404

accountByIdHandler :: Text -> Handler AccountProfile :<|> (UpdateAccountRequest -> Handler AccountProfile) :<|> Handler NoContent
accountByIdHandler accountIdText =
  getAccountProfileHandler accountIdText
    :<|> updateAccountProfileHandler accountIdText
    :<|> deleteAccountHandler accountIdText

getAccountProfileHandler :: Text -> Handler AccountProfile
getAccountProfileHandler accountIdText = do
  cacheRoot <- liftIO resolveCacheRoot
  let acctRoot = accountRoot (usersRoot cacheRoot) (AccountId accountIdText)

  decoded <- liftIO $ readAccountProfile acctRoot
  case decoded of
    Nothing -> throwError err404
    Just profile -> pure profile

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
  pure updated

makeAccountId :: Text -> AccountId
makeAccountId = AccountId . slugifyText

