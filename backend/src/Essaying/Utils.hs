{-# LANGUAGE OverloadedStrings #-}

module Essaying.Utils
  ( trimStr
  , debug_
  , toSlugChar
  , slugifyText
  , isValidAccountName
  )
where

import Control.Monad (when)
import System.Environment (lookupEnv)
import Data.Char (isAlphaNum, isSpace, toLower)
import Data.Text (Text)
import qualified Data.Text as Text


trimStr :: String -> String
trimStr = f . f
  where f = reverse . dropWhile isSpace

debug_ :: String -> Int -> String -> IO ()
debug_ pre level out = do
  dbg <- lookupEnv "HESSAY_DEBUG"
  when (dbg == Just (show level)) $ putStrLn (pre <> " " <> out)

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