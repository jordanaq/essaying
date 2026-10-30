{-# LANGUAGE DerivingStrategies #-}

module Essaying.Types.Storage (
  CacheRoot (..),
  UsersRoot (..),
  AccountRoot (..),
  WorkspaceRoot (..),
  relativeUsersRoot,
)
where

newtype CacheRoot = CacheRoot
  { unCacheRoot :: FilePath
  }
  deriving stock (Eq, Ord, Show)

newtype UsersRoot = UsersRoot
  { unUsersRoot :: FilePath
  }
  deriving stock (Eq, Ord, Show)

newtype AccountRoot = AccountRoot
  { unAccountRoot :: FilePath
  }
  deriving stock (Eq, Ord, Show)

newtype WorkspaceRoot = WorkspaceRoot
  { unWorkspaceRoot :: FilePath
  }
  deriving stock (Eq, Ord, Show)

relativeUsersRoot :: FilePath
relativeUsersRoot = "users"
