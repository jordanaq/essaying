{-# LANGUAGE OverloadedStrings #-}

module ContextErrors (tests) where

import Control.Exception (bracket, finally)
import Control.Monad (forM_)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Essaying.Persistence.Account (createAccountProfile)
import Essaying.Server (app)
import Essaying.Storage (accountRoot, usersRoot, workspaceRoot)
import Essaying.Types.Account (AccountId (..), AccountProfile (..))
import Essaying.Types.Storage (CacheRoot (..), WorkspaceRoot (..))
import Network.HTTP.Types (statusCode)
import Network.Wai (defaultRequest, requestMethod, requestHeaders)
import Network.Wai.Test (SRequest (..), SResponse (..), runSession, setPath, srequest)
import System.Directory (createDirectory, createFileLink, getTemporaryDirectory, removeFile, removePathForcibly)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.HUnit

withWorkspace :: (FilePath -> IO a) -> IO a
withWorkspace action = bracket acquire removePathForcibly $ \cache -> do
  previous <- lookupEnv "HESSAY_CACHE"
  let root = accountRoot (usersRoot (CacheRoot cache)) (AccountId "alice")
  _ <- createAccountProfile root (AccountProfile (AccountId "alice") "Alice" Nothing)
  setEnv "HESSAY_CACHE" cache
  finally (action (unWorkspaceRoot (workspaceRoot root)))
    (maybe (unsetEnv "HESSAY_CACHE") (setEnv "HESSAY_CACHE") previous)
  where
    acquire = do
      tmp <- getTemporaryDirectory
      (path, handle) <- openTempFile tmp "essaying-context-errors"
      hClose handle
      removeFile path
      createDirectory path
      pure path

base :: ByteString
base = "/api/v1/accounts/alice/workspace/context"

call :: ByteString -> ByteString -> BL.ByteString -> IO SResponse
call method url body = runSession (srequest (SRequest request body)) app
  where request = (setPath defaultRequest url)
          { requestMethod = method, requestHeaders = [("Content-Type", "application/json")] }

member :: [Key] -> Value -> Maybe Value
member [] value = Just value
member (key : keys) (Object value) = KeyMap.lookup key value >>= member keys
member _ _ = Nothing

assertError :: Int -> Text -> SResponse -> IO Value
assertError status code response = do
  assertEqual "HTTP status" status (statusCode (simpleStatus response))
  assertEqual "JSON error" (Just "application/json") (lookup "Content-Type" (simpleHeaders response))
  case decode (simpleBody response) of
    Nothing -> assertFailure "error response must be JSON" >> pure Null
    Just value -> do
      assertEqual "stable code" (Just (String code)) (member ["error", "code"] value)
      pure value

writeBody :: ByteString -> BL.ByteString -> BL.ByteString
writeBody path layer = "{\"path\":" <> encode (BS.unpack path) <> ",\"contextLayer\":" <> layer <> "}"

tests :: Test
tests = TestList
  [ TestLabel "stored and submitted validation retain exact field paths" $ TestCase $ withWorkspace $ \root -> do
      createDirectory (root </> "Essay")
      writeFile (root </> "Essay/essay.md") "# Essay"
      forM_
        [ ("{\"title\":{\"tag\":\"SetScalar\",\"contents\":\" \"}}", "title.contents")
        , ("{\"instructions\":{\"tag\":\"AppendList\",\"contents\":[\"ok\",\" \"]}}", "instructions.contents[1]")
        , ("{\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"use.of.sources\":{\"weight\":-1}}}}", "rubric.contents[\"use.of.sources\"].weight")
        , ("{\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"evidence\":{\"weight\":\"private-value\"}}}}", "rubric.contents.evidence.weight")
        , ("{\"unexpected\":true}", "unexpected")
        ] $ \(source, field) -> do
          BL.writeFile (root </> "context.json") source
          stored <- call "GET" (base <> "/effective?path=Essay") "" >>= assertError 422 "INVALID_CONTEXT"
          assertEqual "source path" (Just (String "context.json")) (member ["error", "details", "path"] stored)
          assertEqual "stored field" (Just (String field)) (member ["error", "details", "field"] stored)
          submitted <- call "PUT" base (writeBody "context.json" source) >>= assertError 422 "INVALID_CONTEXT"
          assertEqual "submitted field" (Just (String field)) (member ["error", "details", "field"] submitted)
          assertEqual "layer input" (Just (String "contextLayer")) (member ["error", "details", "parameter"] submitted)
          assertBool "no raw values" (not (BS.isInfixOf "private-value" (BL.toStrict (encode submitted))))
  , TestLabel "broken ancestors block context while essay saving works" $ TestCase $ withWorkspace $ \root -> do
      createDirectory (root </> "Child")
      writeFile (root </> "Child/essay.md") "# Essay"
      writeFile (root </> "context.json") "{\"title\":{\"tag\":\"SetScalar\",\"contents\":\" \"}}"
      writeFile (root </> "Child/context.json") "{\"title\":{\"tag\":\"SetScalar\",\"contents\":\"Replacement\"}}"
      value <- call "GET" (base <> "/effective?path=Child") "" >>= assertError 422 "INVALID_CONTEXT"
      assertEqual "parent file" (Just (String "context.json")) (member ["error", "details", "path"] value)
      saved <- call "PUT" "/api/v1/accounts/alice/workspace/essays/Child" "{\"markdown\":\"Saved despite invalid context\"}"
      assertEqual "essay save remains independent" 200 (statusCode (simpleStatus saved))
      assertEqual "essay persisted" "Saved despite invalid context" =<< readFile (root </> "Child/essay.md")
  , TestLabel "essay updates independently save optional prompt or markdown" $ TestCase $ withWorkspace $ \root -> do
      createDirectory (root </> "Essay")
      writeFile (root </> "Essay/essay.md") "Original draft"
      let url = "/api/v1/accounts/alice/workspace/essays/Essay"
          save body expectedPrompt expectedDraft = do
            response <- call "PUT" url body
            assertEqual "save status" 200 (statusCode (simpleStatus response))
            let value = decode (simpleBody response)
            assertEqual "returned prompt" (Just (String expectedPrompt)) (value >>= member ["prompt"])
            assertEqual "returned draft" (Just (String expectedDraft)) (value >>= member ["markdown"])
      save "{\"prompt\":\"Assignment\"}" "Assignment" "Original draft"
      save "{\"markdown\":\"Updated draft\"}" "Assignment" "Updated draft"
      forM_ ["{}", "{\"prompt\":\"Bad\",\"markdown\":\"Bad\"}",
        "{\"prompt\":null}", "{\"markdown\":null}", "{\"markdown\":12}",
        "{\"markdown\":\"Bad\",\"extra\":true}"] $ \body -> do
          rejected <- call "PUT" url body
          assertEqual "invalid save request is rejected" 400 (statusCode (simpleStatus rejected))
      assertEqual "invalid updates preserve saved prompt" "Assignment"
        =<< readFile (root </> "Essay/prompt.md")
      assertEqual "invalid updates preserve saved draft" "Updated draft"
        =<< readFile (root </> "Essay/essay.md")
      save "{\"markdown\":\"\"}" "Assignment" ""
      save "{\"prompt\":\"\"}" "" ""
  , TestLabel "nested essay and folder deletion return HTTP 400" $ TestCase $ withWorkspace $ \root -> do
      createDirectory (root </> "Outer")
      writeFile (root </> "Outer/essay.md") "Keep outer"
      createDirectory (root </> "Outer/Inner")
      writeFile (root </> "Outer/Inner/essay.md") "Keep inner"
      createDirectory (root </> "Outer/References")
      writeFile (root </> "Outer/References/source.md") "Keep reference"
      forM_ ["/api/v1/accounts/alice/workspace/essays/Outer/Inner",
        "/api/v1/accounts/alice/workspace/directories/Outer/References"] $ \url -> do
          response <- call "DELETE" url ""
          assertEqual "nested target maps to bad request" 400 (statusCode (simpleStatus response))
      assertEqual "nested essay survives" "Keep inner" =<< readFile (root </> "Outer/Inner/essay.md")
      assertEqual "nested folder survives" "Keep reference" =<< readFile (root </> "Outer/References/source.md")
  , TestLabel "request decoding failures use a JSON envelope" $ TestCase $ withWorkspace $ \_ -> do
      forM_ [("GET", base, ""), ("GET", base <> "/effective", ""), ("POST", base, "{"),
        ("GET", "/api/v1/accounts/alice/workspace/%63ontext", ""), ("POST", base, "{}"), ("POST", base, "{\"path\":\"context.json\",\"contextLayer\":{},\"extra\":true}"),
        ("DELETE", base, "{\"path\":false}")] $ \(method, url, body) -> do
          _ <- call method url body >>= assertError 400 "INVALID_REQUEST"
          pure ()
  , TestLabel "rejected paths never appear in responses" $ TestCase $ withWorkspace $ \_ -> do
      forM_ ["/home/private/context.json", "../other/context.json"] $ \path -> do
        forM_ ["POST", "PUT", "DELETE"] $ \method -> do
          let body = if method == "DELETE" then encode (object ["path" .= BS.unpack path]) else writeBody path "{}"
          response <- call method base body
          value <- assertError 400 "INVALID_CONTEXT_PATH" response
          assertEqual "rejected path omitted" Nothing (member ["error", "details", "path"] value)
          assertBool "input is not echoed" (not (BS.isInfixOf path (BL.toStrict (simpleBody response))))
      _ <- call "GET" (base <> "?path=%2Fhome%2Fprivate%2Fcontext.json") "" >>= assertError 400 "INVALID_CONTEXT_PATH"
      _ <- call "GET" (base <> "/effective?path=..%2FPrivate") "" >>= assertError 400 "INVALID_ESSAY_PATH"
      pure ()
  , TestLabel "missing resources and absent effective layers are distinct" $ TestCase $ withWorkspace $ \root -> do
      _ <- call "GET" "/api/v1/accounts/missing/workspace/context?path=context.json" "" >>= assertError 404 "ACCOUNT_NOT_FOUND"
      _ <- call "GET" (base <> "?path=context.json") "" >>= assertError 404 "CONTEXT_NOT_FOUND"
      _ <- call "GET" (base <> "/effective?path=Missing") "" >>= assertError 404 "ESSAY_NOT_FOUND"
      createDirectory (root </> "Essay")
      writeFile (root </> "Essay/essay.md") "# Essay"
      response <- call "GET" (base <> "/effective?path=Essay") ""
      assertEqual "no context is valid" 200 (statusCode (simpleStatus response))
  , TestLabel "essay-local context mutations affect directory effective context" $ TestCase $ withWorkspace $ \root -> do
      createDirectory (root </> "My Essay")
      writeFile (root </> "My Essay/essay.md") ""
      writeFile (root </> "context.json")
        "{\"title\":{\"tag\":\"SetScalar\",\"contents\":\"Inherited\"}}"
      let localPath = "My Essay/context.json"
          effectiveUrl = base <> "/effective?path=My%20Essay"
          assertTitle expected = do
            response <- call "GET" effectiveUrl ""
            assertEqual "effective response" 200 (statusCode (simpleStatus response))
            assertEqual "effective title" (Just (String expected))
              (decode (simpleBody response) >>= member ["title"])
      assertTitle "Inherited"
      created <- call "POST" base (writeBody localPath
        "{\"title\":{\"tag\":\"SetScalar\",\"contents\":\"Local\"}}")
      assertEqual "local layer created" 201 (statusCode (simpleStatus created))
      assertTitle "Local"
      updated <- call "PUT" base (writeBody localPath
        "{\"title\":{\"tag\":\"ClearScalar\"}}")
      assertEqual "local layer updated" 200 (statusCode (simpleStatus updated))
      cleared <- call "GET" effectiveUrl ""
      assertEqual "local clear overrides inherited title" (Just Null)
        (decode (simpleBody cleared) >>= member ["title"])
      deleted <- call "DELETE" base (encode (object ["path" .= ("My Essay/context.json" :: Text)]))
      assertEqual "local layer deleted" 204 (statusCode (simpleStatus deleted))
      assertTitle "Inherited"
  , TestLabel "syntax errors omit raw parser excerpts" $ TestCase $ withWorkspace $ \root -> do
      forM_ ["{private-value", "{} {}", "{\"title\":null,\"title\":null}"] $ \source -> do
        writeFile (root </> "context.json") source
        response <- call "GET" (base <> "?path=context.json") ""
        value <- assertError 422 "INVALID_CONTEXT" response
        assertEqual "no invented field" Nothing (member ["error", "details", "field"] value)
        assertBool "no parser excerpt" (not (BS.isInfixOf "private-value" (BL.toStrict (simpleBody response))))
  , TestLabel "symlinks and I/O errors suppress destinations and OS messages" $ TestCase $ withWorkspace $ \root -> do
      let outside = root </> "private-outside.json"
      writeFile outside "{}"
      createFileLink outside (root </> "context.json")
      response <- call "GET" (base <> "?path=context.json") ""
      value <- assertError 403 "CONTEXT_SYMBOLIC_LINK" response
      assertEqual "link location" (Just (String "context.json")) (member ["error", "details", "path"] value)
      assertBool "no destination" (not (BS.isInfixOf (BS.pack outside) (BL.toStrict (simpleBody response))))
      removeFile (root </> "context.json")
      createDirectory (root </> "context.json")
      failed <- call "GET" (base <> "?path=context.json") ""
      _ <- assertError 500 "CONTEXT_IO_ERROR" failed
      assertBool "no root path" (not (BS.isInfixOf (BS.pack root) (BL.toStrict (simpleBody failed))))
  , TestLabel "collisions and malformed-layer repair preserve mutation behavior" $ TestCase $ withWorkspace $ \root -> do
      writeFile (root </> "context.json") "broken"
      _ <- call "POST" base (writeBody "context.json" "{}") >>= assertError 409 "CONTEXT_EXISTS"
      repaired <- call "PUT" base (writeBody "context.json" "{}")
      assertEqual "repair succeeds" 200 (statusCode (simpleStatus repaired))
      layer <- call "GET" (base <> "?path=context.json") ""
      assertEqual "repaired layer reads" 200 (statusCode (simpleStatus layer))
  ]
