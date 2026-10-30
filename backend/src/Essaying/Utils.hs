{-# LANGUAGE OverloadedStrings #-}

module Essaying.Utils (
  trimStr,
  lookupEnvClean,
  debug_,
  toSlugChar,
  slugifyText,
  isValidAccountName,
)
where

import Control.Monad (when)
import Data.Char (isAlphaNum, isSpace, toLower)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Environment (lookupEnv)

trimStr :: String -> String
trimStr = f . f
 where
  f = reverse . dropWhile isSpace

debug_ :: String -> Int -> String -> IO ()
debug_ pre level out = do
  dbg <- lookupEnv "HESSAY_DEBUG"
  case dbg of
    Just val -> when (read val >= level) $ putStrLn (pre <> " " <> out)
    Nothing -> return ()

{- | Trim an optional setting, treating missing or blank values as absent.
This only cleans text; callers still validate URLs, numbers, and other types.
-}
lookupEnvClean :: String -> IO (Maybe Text)
lookupEnvClean key = do
  raw <- lookupEnv key
  return $ case Text.strip . Text.pack <$> raw of
    Just value | not (Text.null value) -> Just value
    _ -> Nothing

toSlugChar :: Char -> Char
toSlugChar c
  | isAlphaNum c = c
  | otherwise = '-'

slugifyText :: Text -> Text
slugifyText input =
  let normalized = Text.map toLower (Text.strip input)
      separatorized = Text.map toSlugChar normalized
      pieces = filter (not . Text.null) (Text.splitOn "-" separatorized)
      rebuilt = Text.intercalate "-" pieces
   in if Text.null rebuilt then "account" else rebuilt

isValidAccountName :: Text -> Bool
isValidAccountName name =
  let trimmed = trimStr $ Text.unpack name
   in not (null trimmed) && all isValidChar trimmed
 where
  isValidChar c = isAlphaNum c || c == '-' || c == '_'
