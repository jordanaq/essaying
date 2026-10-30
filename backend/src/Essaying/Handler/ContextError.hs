{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.ContextError (contextError, contextValidationError, invalidRequestError) where

import Data.Aeson (encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import Data.Text qualified as Text
import Essaying.Persistence.Workspace (isSafeSegment)
import Essaying.Types.Context (ContextDiagnostic (..))
import Servant (Handler, ServerError (..), err400, err422, throwError)
import System.FilePath (isAbsolute)

{- | Accept only workspace-relative labels. Invalid input and root labels are
omitted rather than echoed, normalized, or interpreted as host paths.
-}
safePath :: FilePath -> Maybe FilePath
safePath path
  | isAbsolute path = Nothing
  | all isSafeSegment (Text.splitOn "/" (Text.pack path)) = Just path
  | otherwise = Nothing

{- | Throw a structured context error with a safe workspace-relative path label.
Invalid-path errors omit the supplied path and identify the @path@ parameter.
-}
contextError :: ServerError -> Text -> FilePath -> Text -> Handler a
contextError status code path message =
  throwError $
    response status code message $
      maybe
        []
        (\label -> ["path" .= label])
        (if code `elem` ["INVALID_CONTEXT_PATH", "INVALID_ESSAY_PATH"] then Nothing else safePath path)
        <> if code `elem` ["INVALID_CONTEXT_PATH", "INVALID_ESSAY_PATH"]
          then ["parameter" .= ("path" :: Text)]
          else []

{- | Return 422 with a sanitized diagnostic, optional parameter, and safe path.
The diagnostic field identifies the invalid location within the layer.
-}
contextValidationError :: FilePath -> Maybe Text -> ContextDiagnostic -> Handler a
contextValidationError path parameter (ContextDiagnostic field message) =
  throwError $
    response err422 "INVALID_CONTEXT" message $
      maybe [] (\label -> ["path" .= label]) (safePath path)
        <> maybe [] (\value -> ["field" .= value]) field
        <> maybe [] (\value -> ["parameter" .= value]) parameter

{- | Generic structured 400 response for context envelope or URL decoding failures.
Decoder messages and submitted values are omitted.
-}
invalidRequestError :: ServerError
invalidRequestError =
  response
    err400
    "INVALID_REQUEST"
    "Provide a valid request with the required path and context layer."
    []

{- | Build the JSON error envelope with the supplied status, code, message,
and detail fields, replacing the response headers with the JSON content type.
-}
response :: ServerError -> Text -> Text -> [Pair] -> ServerError
response status code message details =
  status
    { errBody =
        encode $
          object
            [ "error"
                .= object
                  ["code" .= code, "message" .= message, "details" .= object details]
            ]
    , errHeaders = [("Content-Type", "application/json")]
    }
