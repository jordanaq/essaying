{-# LANGUAGE DerivingStrategies #-}

module Essaying.Types.Storage (
  CacheRoot (..),
  UsersRoot (..),
  AccountRoot (..),
  WorkspaceRoot (..),
  relativeUsersRoot,
)
where

{- | Root of the application cache. Normal runtime resolution makes it absolute
and creates it; constructing this wrapper alone provides no such guarantee.
-}
newtype CacheRoot = CacheRoot
  { unCacheRoot :: FilePath
  }
  deriving stock (Eq, Ord, Show)

-- | Path containing account directories beneath the cache root.
newtype UsersRoot = UsersRoot
  { unUsersRoot :: FilePath
  }
  deriving stock (Eq, Ord, Show)

-- | Path containing one account's @profile.json@ and @workspace@ directory.
newtype AccountRoot = AccountRoot
  { unAccountRoot :: FilePath
  }
  deriving stock (Eq, Ord, Show)

{- | Trusted filesystem root for account workspace operations. The wrapper
alone does not validate, canonicalize, or create the supplied path.
-}
newtype WorkspaceRoot = WorkspaceRoot
  { unWorkspaceRoot :: FilePath
  }
  deriving stock (Eq, Ord, Show)

-- | Users directory name relative to the application cache root.
relativeUsersRoot :: FilePath
relativeUsersRoot = "users"
