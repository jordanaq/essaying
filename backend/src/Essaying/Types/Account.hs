{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}

module Essaying.Types.Account (
  AccountId (..),
  AccountProfile (..),
  CreateAccountRequest (..),
  UpdateAccountRequest (..),
  CreateAccountProfileResult (..),
)
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

{- | Account identifier used as its directory name. The wrapper itself performs
no validation; account creation derives the value from a display-name slug.
-}
newtype AccountId = AccountId
  { unAccountId :: Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Persisted account settings. The ID must match the containing directory;
the optional preferred model is a fallback when effective context selects none.
-}
data AccountProfile = AccountProfile
  { accountId :: AccountId
  , displayName :: Text
  , preferredModel :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Initial account settings. The handler validates the display name and
derives an ID; an omitted or null preferred model leaves no account default.
-}
data CreateAccountRequest = CreateAccountRequest
  { displayName :: Text
  , preferredModel :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Partial profile update. Omitted or null fields preserve existing values.
The account ID stays fixed, and the preferred model cannot be cleared here.
-}
data UpdateAccountRequest = UpdateAccountRequest
  { displayName :: Maybe Text
  , preferredModel :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Outcome of claiming a new account directory.
data CreateAccountProfileResult
  = AccountCreated
  | AccountAlreadyExists
  deriving stock (Eq, Show)
