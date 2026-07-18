{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Workspace
  ( workspaceHandler
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import Essaying.Types.Workspace
  ( CreateWorkspaceDirectoryRequest (..)
  , CreateWorkspaceEssayRequest (..)
  , WorkspaceEssayContent (..)
  , WorkspaceNode (..)
  , WorkspaceNodeType (..)
  , WorkspaceTreeResponse (..)
  )
import Servant (Handler, (:<|>) (..))

workspaceHandler ::
  Text ->
  Handler WorkspaceTreeResponse
    :<|> ([Text] -> Handler WorkspaceEssayContent)
    :<|> (CreateWorkspaceDirectoryRequest -> Handler WorkspaceNode)
    :<|> (CreateWorkspaceEssayRequest -> Handler WorkspaceEssayContent)
workspaceHandler accountIdText =
  listWorkspaceTreeHandler accountIdText
    :<|> loadWorkspaceEssayHandler accountIdText
    :<|> createWorkspaceDirectoryHandler accountIdText
    :<|> createWorkspaceEssayHandler accountIdText

listWorkspaceTreeHandler :: Text -> Handler WorkspaceTreeResponse
listWorkspaceTreeHandler accountIdText =
  pure $ WorkspaceTreeResponse [sampleDirectoryNode accountIdText]

loadWorkspaceEssayHandler :: Text -> [Text] -> Handler WorkspaceEssayContent
loadWorkspaceEssayHandler accountIdText essayPath =
  pure $ WorkspaceEssayContent essayPath (titleFromPath essayPath) (stubEssayMarkdown accountIdText essayPath)

createWorkspaceDirectoryHandler :: Text -> CreateWorkspaceDirectoryRequest -> Handler WorkspaceNode
createWorkspaceDirectoryHandler _ (CreateWorkspaceDirectoryRequest reqParentPath reqDirectoryName) =
  pure $ WorkspaceNode reqDirectoryName (reqParentPath <> [reqDirectoryName]) WorkspaceDirectoryNode []

createWorkspaceEssayHandler :: Text -> CreateWorkspaceEssayRequest -> Handler WorkspaceEssayContent
createWorkspaceEssayHandler accountIdText (CreateWorkspaceEssayRequest reqParentPath reqEssayName reqMarkdown) =
  let essayPath = reqParentPath <> [reqEssayName]
      essayMarkdown = maybe (stubEssayMarkdown accountIdText essayPath) id reqMarkdown
   in pure $ WorkspaceEssayContent essayPath reqEssayName essayMarkdown

sampleDirectoryNode :: Text -> WorkspaceNode
sampleDirectoryNode accountIdText =
  WorkspaceNode
    "History"
    ["History"]
    WorkspaceDirectoryNode
    [ WorkspaceNode
        "French-Revolution.md"
        ["History", "French-Revolution.md"]
        WorkspaceEssayNode
        []
    , WorkspaceNode
        "Notes"
        ["History", "Notes"]
        WorkspaceDirectoryNode
        [ WorkspaceNode
            (accountIdText <> "-outline.md")
            ["History", "Notes", accountIdText <> "-outline.md"]
            WorkspaceEssayNode
            []
        ]
    ]

titleFromPath :: [Text] -> Text
titleFromPath [] = "Untitled Essay"
titleFromPath segments = last segments

stubEssayMarkdown :: Text -> [Text] -> Text
stubEssayMarkdown accountIdText essayPath =
  Text.unlines
    [ "# Stub Essay"
    , ""
    , "Account: " <> accountIdText
    , "Path: " <> Text.intercalate "/" essayPath
    , ""
    , "Replace this stub with persistence-backed workspace loading."
    ]