-- | Temporary fixtures and reversible process settings shared by AI tests.
-- Environment-mutating tests must run serially within a test process.
module AiTestSupport (readFixture, writeBytes, withCache, withEnvironment) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson (FromJSON, eitherDecode)
import Data.ByteString.Lazy qualified as BL
import System.Directory (createDirectory, createDirectoryIfMissing, getTemporaryDirectory, removeFile, removePathForcibly)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>), takeDirectory)
import System.IO (hClose, openTempFile)
import Test.HUnit (assertFailure)

-- | Decode a repository JSON fixture, failing the test on malformed fixture data.
readFixture :: FromJSON a => FilePath -> IO a
readFixture path = do
  bytes <- BL.readFile path
  case eitherDecode bytes of
    Left err -> assertFailure ("invalid test fixture: " <> err) >> fail "invalid fixture"
    Right value -> pure value

-- | Create fixture parent directories and write the requested bytes.
writeBytes :: FilePath -> BL.ByteString -> IO ()
writeBytes path bytes = do
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path bytes

-- | Allocate a temporary directory and remove it after the test, including on failure.
withCache :: (FilePath -> IO a) -> IO a
withCache = bracket acquire removePathForcibly
  where
    acquire = do
      temporary <- getTemporaryDirectory
      (path, handle) <- openTempFile temporary "essaying-ai-endpoints"
      hClose handle
      removeFile path
      createDirectory path
      pure path

-- Tests run serially. Restore process settings even if an assertion fails;
-- credentials are never logged, and requests use only the literal fake key.
-- | Apply process settings for a serial test and restore them after its action.
withEnvironment :: [(String, Maybe String)] -> IO a -> IO a
withEnvironment settings action = bracket acquire restore (const action)
  where
    acquire = do
      original <- mapM (\(key, _) -> (,) key <$> lookupEnv key) settings
      forM_ settings apply
      pure original
    restore = mapM_ apply
    apply (key, Nothing) = unsetEnv key
    apply (key, Just value) = setEnv key value
