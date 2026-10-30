{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Essaying.Types.Workspace (
  WorkspaceNodeType (..),
  WorkspaceNode (..),
  WorkspaceTreeResponse (..),
  WorkspaceEssayContent (..),
  CreateWorkspaceDirectoryRequest (..),
  CreateWorkspaceEssayRequest (..),
  SaveWorkspaceEssayRequest (..),
  CreateWorkspaceDirectoryResult (..),
  CreateWorkspaceEssayResult (..),
  WorkspacePathError (..),
  WorkspaceDeleteResult (..),
)
where

import Control.Monad (unless, when)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (Null), defaultOptions, genericToJSON, omitNothingFields, withObject, (.:?))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Maybe (isJust)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Distinguish ordinary directories from essay directories containing @essay.md@.
data WorkspaceNodeType
  = WorkspaceDirectoryNode
  | WorkspaceEssayNode
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Discovered workspace entry with a workspace-relative segment path.
Ordinary directories expose children; essays are leaf nodes.
-}
data WorkspaceNode = WorkspaceNode
  { name :: Text
  , path :: [Text]
  , nodeType :: WorkspaceNodeType
  , children :: [WorkspaceNode]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Top-level entries of the selected account's workspace tree.
newtype WorkspaceTreeResponse = WorkspaceTreeResponse
  { tree :: [WorkspaceNode]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Saved essay data. The path identifies its directory, the title is its
final path segment, and an absent @prompt.md@ is represented by empty text.
-}
data WorkspaceEssayContent = WorkspaceEssayContent
  { path :: [Text]
  , title :: Text
  , prompt :: Text
  , markdown :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Create a named directory beneath an existing parent. An empty @parentPath@
selects the workspace root; the name must be one safe path segment.
-}
data CreateWorkspaceDirectoryRequest = CreateWorkspaceDirectoryRequest
  { parentPath :: [Text]
  , directoryName :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Create a named essay directory beneath an existing parent. An empty
@parentPath@ selects the workspace root. Omitted or null content defaults
to empty text; creation always writes the @essay.md@ draft marker.
-}
data CreateWorkspaceEssayRequest = CreateWorkspaceEssayRequest
  { parentPath :: [Text]
  , essayName :: Text
  , prompt :: Maybe Text
  , markdown :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Update exactly one saved content field. JSON must supply either @prompt@
or @markdown@ as a string, allowing empty text. Both fields, neither field,
null values, and unknown fields are rejected; the omitted field is preserved.
-}
data SaveWorkspaceEssayRequest = SaveWorkspaceEssayRequest
  { prompt :: Maybe Text
  , markdown :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SaveWorkspaceEssayRequest where
  toJSON = genericToJSON defaultOptions{omitNothingFields = True}

instance FromJSON SaveWorkspaceEssayRequest where
  parseJSON = withObject "SaveWorkspaceEssayRequest" $ \o -> do
    unless (all (`elem` ["prompt", "markdown"]) (KeyMap.keys o)) $
      fail "Unknown essay save field."
    when (any (== Null) (KeyMap.elems o)) $
      fail "Essay save fields must be strings."
    newPrompt <- o .:? "prompt"
    newMarkdown <- o .:? "markdown"
    unless (isJust newPrompt /= isJust newMarkdown) $
      fail "Provide exactly one of prompt or markdown."
    pure (SaveWorkspaceEssayRequest newPrompt newMarkdown)

-- | Result of attempting to create a directory in the workspace.
data CreateWorkspaceDirectoryResult
  = WorkspaceDirectoryCreated WorkspaceNode
  | WorkspaceDirectoryAlreadyExists
  | WorkspaceDirectoryCreationFailed Text
  deriving stock (Eq, Show)

-- | Result of attempting to create an essay in the workspace.
data CreateWorkspaceEssayResult
  = WorkspaceEssayCreated WorkspaceEssayContent
  | WorkspaceEssayAlreadyExists
  | WorkspaceEssayClobbersDirectory
  | WorkspaceEssayCreationFailed Text
  deriving stock (Eq, Show)

-- | Reason a workspace path or target cannot be used by an operation.
data WorkspacePathError
  = WorkspacePathInvalidPath [Text]
  | WorkspacePathNestedEssay [Text]
  | WorkspacePathRootDenied
  | WorkspacePathTargetNotFound [Text]
  | WorkspacePathWrongTargetType [Text]
  | WorkspacePathSymbolicLink [Text]
  deriving stock (Eq, Show)

-- | Outcome of deleting a workspace essay or directory.
data WorkspaceDeleteResult
  = WorkspaceDeleteSucceeded
  | WorkspaceDeleteFailed WorkspacePathError
  deriving stock (Eq, Show)
