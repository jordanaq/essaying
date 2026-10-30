{-# LANGUAGE TypeApplications #-}

module ApiClients
  ( AccountsClientRoutes
  , AccountClientRoutes
  , WorkspaceClientRoutes
  , EssayClientRoutes
  , ContextClientRoutes
  , AiClientRoutes
  , healthClient
  , readyClient
  , accountsClient
  , listAccountsClient
  , createAccountClient
  , accountByIdClient
  , workspaceClients
  , essayClients
  , contextClients
  , aiClients
  )
where

import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Essaying.API.V1 (Api, AccountsApi, AccountApi, WorkspaceApi, EssayApi, ContextApi, AiApi)
import Essaying.Types.Account (AccountProfile, CreateAccountRequest)
import Essaying.Types.Health (HealthResponse, ReadyResponse)
import Servant ((:<|>) ((:<|>)))
import Servant.Client (Client, ClientM, client)

healthClient :: ClientM HealthResponse
readyClient :: ClientM ReadyResponse
listAccountsClient :: ClientM [AccountProfile]
createAccountClient :: CreateAccountRequest -> ClientM AccountProfile
-- Derive each client group from its API contract instead of repeating its routes.
type AccountsClientRoutes = Client ClientM AccountsApi
type AccountClientRoutes = Client ClientM AccountApi
type WorkspaceClientRoutes = Client ClientM WorkspaceApi
type EssayClientRoutes = Client ClientM EssayApi
type ContextClientRoutes = Client ClientM ContextApi
type AiClientRoutes = Client ClientM AiApi

accountsClient :: AccountsClientRoutes
accountByIdClient :: Text -> AccountClientRoutes
(healthClient :<|> readyClient :<|> accountsClient) = client (Proxy @Api)
(listAccountsClient :<|> createAccountClient :<|> accountByIdClient) = accountsClient

workspaceClients :: Text -> WorkspaceClientRoutes
workspaceClients accountId =
  let _ :<|> _ :<|> _ :<|> routes = accountByIdClient accountId
  in routes

essayClients :: Text -> [Text] -> EssayClientRoutes
essayClients accountId =
  let _ :<|> routes :<|> _ :<|> _ :<|> _ :<|> _ :<|> _ = workspaceClients accountId
  in routes

contextClients :: Text -> ContextClientRoutes
contextClients accountId =
  let _ :<|> _ :<|> _ :<|> _ :<|> _ :<|> routes :<|> _ = workspaceClients accountId
  in routes

aiClients :: Text -> AiClientRoutes
aiClients accountId =
  let _ :<|> _ :<|> _ :<|> _ :<|> _ :<|> _ :<|> routes = workspaceClients accountId
  in routes
