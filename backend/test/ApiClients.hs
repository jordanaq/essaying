{-# LANGUAGE TypeApplications #-}

-- | Test clients derived from the real API sections, preserving mounted URL paths.
module ApiClients (
  AccountsClientRoutes,
  AccountClientRoutes,
  WorkspaceClientRoutes,
  EssayClientRoutes,
  ContextClientRoutes,
  AiClientRoutes,
  healthClient,
  readyClient,
  accountsClient,
  listAccountsClient,
  createAccountClient,
  accountByIdClient,
  workspaceClients,
  essayClients,
  contextClients,
  aiClients,
)
where

import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Essaying.API.V1 (AccountApi, AccountsApi, AiApi, Api, ContextApi, EssayApi, WorkspaceApi)
import Essaying.Types.Account (AccountProfile, CreateAccountRequest)
import Essaying.Types.Health (HealthResponse, ReadyResponse)
import Servant ((:<|>) ((:<|>)))
import Servant.Client (Client, ClientM, client)

-- | Call the mounted health endpoint.
healthClient :: ClientM HealthResponse

-- | Call the mounted readiness endpoint.
readyClient :: ClientM ReadyResponse

-- | List profiles through the account collection route.
listAccountsClient :: ClientM [AccountProfile]

-- | Create an account through the collection route.
createAccountClient :: CreateAccountRequest -> ClientM AccountProfile

-- Derive each client group from its API contract instead of repeating its routes.

-- | Generated client group for account collection operations.
type AccountsClientRoutes = Client ClientM AccountsApi

-- | Generated client group for one account and its workspace.
type AccountClientRoutes = Client ClientM AccountApi

-- | Generated client group composing workspace, context, and AI operations.
type WorkspaceClientRoutes = Client ClientM WorkspaceApi

-- | Generated client group for reading, saving, and deleting one essay.
type EssayClientRoutes = Client ClientM EssayApi

-- | Generated client group for context layer operations and effective preview.
type ContextClientRoutes = Client ClientM ContextApi

-- | Generated prompt/grade clients; their result types follow the shared API contract.
type AiClientRoutes = Client ClientM AiApi

-- | Account collection clients extracted from the full mounted API.
accountsClient :: AccountsClientRoutes

-- | Select the account before accessing any child client group.
accountByIdClient :: Text -> AccountClientRoutes

(healthClient :<|> readyClient :<|> accountsClient) = client (Proxy @Api)
(listAccountsClient :<|> createAccountClient :<|> accountByIdClient) = accountsClient

-- | Extract the selected account's mounted workspace clients.
workspaceClients :: Text -> WorkspaceClientRoutes
workspaceClients accountId =
  let _ :<|> _ :<|> _ :<|> routes = accountByIdClient accountId
   in routes

-- | Select an essay using its workspace-relative directory path segments.
essayClients :: Text -> [Text] -> EssayClientRoutes
essayClients accountId =
  let _ :<|> routes :<|> _ :<|> _ :<|> _ :<|> _ :<|> _ = workspaceClients accountId
   in routes

-- | Extract mounted context clients without repeating the parent route pattern in tests.
contextClients :: Text -> ContextClientRoutes
contextClients accountId =
  let _ :<|> _ :<|> _ :<|> _ :<|> _ :<|> routes :<|> _ = workspaceClients accountId
   in routes

-- | Extract mounted prompt and grade clients for a selected account.
aiClients :: Text -> AiClientRoutes
aiClients accountId =
  let _ :<|> _ :<|> _ :<|> _ :<|> _ :<|> _ :<|> routes = workspaceClients accountId
   in routes
