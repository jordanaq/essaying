{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}

module Essaying.Types.Account
  ( AccountId (..)
  , AccountProfile (..)
  , CreateAccountRequest (..)
  , UpdateAccountRequest (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

newtype AccountId = AccountId
  { unAccountId :: Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AccountProfile = AccountProfile
  { accountId :: AccountId
  , displayName :: Text
  , preferredModel :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CreateAccountRequest = CreateAccountRequest
  { displayName :: Text
  , preferredModel :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data UpdateAccountRequest = UpdateAccountRequest
  { displayName :: Maybe Text
  , preferredModel :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
