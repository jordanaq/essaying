{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Essaying.Types.Context (
  -- * Resolved and source context
  EffectiveContext (..),
  ContextLayer (..),

  -- * Layer operations
  ScalarOverride (..),
  ListOverride (..),
  RubricOverride (..),
  RubricCriterion (..),

  -- * Loading errors
  ContextDiagnostic (..),
  contextDiagnostic,
  decodeContextLayer,
  parseContextLayer,
  ContextWriteRequest (..),
  ContextLayerError (..),
  EffectiveContextError (..),

  -- * Context mutation requests (workspace root is supplied by the server)
  CreateContextRequest (..),
  UpdateContextRequest (..),
  DeleteContextRequest (..),
)
where

import Data.Aeson (
  FromJSON (..),
  ToJSON (..),
  defaultOptions,
  encode,
  genericParseJSON,
  object,
  rejectUnknownFields,
  withObject,
  (.:),
  (.=),
 )
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Parser (eitherDecodeStrictWith, jsonNoDup')
import Data.Aeson.Types (JSONPath, JSONPathElement (..), Parser, Value (..), ifromJSON, iparseEither, (<?>))
import Data.Attoparsec.ByteString (endOfInput, skipWhile)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAlphaNum, isAscii, isLetter)
import Data.List (findIndex)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import GHC.Generics (Generic)

{- | Context available to an essay after all ancestor layers have been applied.
Unset scalars are 'Nothing'; collections contain their resolved values.
-}
data EffectiveContext = EffectiveContext
  { title :: Maybe Text
  , audience :: Maybe Text
  , model :: Maybe Text
  , tags :: [Text]
  , instructions :: [Text]
  , grading_directions :: [Text]
  , rubric :: Map Text RubricCriterion
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | One directory's optional context settings. An omitted or @null@ field
inherits its parent's value; supplied fields carry explicit operations.
-}
data ContextLayer = ContextLayer
  { title :: Maybe (ScalarOverride Text)
  , audience :: Maybe (ScalarOverride Text)
  , model :: Maybe (ScalarOverride Text)
  , tags :: Maybe (ListOverride Text)
  , instructions :: Maybe (ListOverride Text)
  , grading_directions :: Maybe (ListOverride Text)
  , rubric :: Maybe RubricOverride
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Set a scalar value or explicitly clear an inherited one.
data ScalarOverride a
  = SetScalar a
  | ClearScalar
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | Append to an inherited list or replace it entirely. Replacing with an
empty list clears the field.
-}
data ListOverride a
  = AppendList [a]
  | ReplaceList [a]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | Merge named rubric criteria with inherited ones or replace the rubric.
A criterion in the child replaces its entire parent definition.
-}
data RubricOverride
  = MergeRubric (Map Text RubricCriterion)
  | ReplaceRubric (Map Text RubricCriterion)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | One named rubric criterion. Its weight must be finite and nonnegative;
a supplied description must contain non-whitespace text.
-}
data RubricCriterion = RubricCriterion
  { weight :: Double
  , description :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | Reason a single context file could not be loaded.
Filesystem errors use workspace-relative paths; invalid-path errors retain
the supplied path.
-}
data ContextLayerError
  = ContextLayerInvalidPath FilePath
  | ContextLayerSymbolicLink FilePath
  | ContextLayerIoError FilePath String
  | ContextLayerJsonError FilePath ContextDiagnostic
  deriving stock (Eq, Show)

{- | Reason context could not be resolved for an essay.
Errors from an ancestor @context.json@ retain their 'ContextLayerError'.
-}
data EffectiveContextError
  = EffectiveContextInvalidPath FilePath
  | EffectiveContextEssayNotFound FilePath
  | EffectiveContextSymbolicLink FilePath
  | EffectiveContextIoError FilePath String
  | EffectiveContextJsonError FilePath ContextDiagnostic
  | EffectiveContextLayerError ContextLayerError
  deriving stock (Eq, Show)

{- | Typed layer creation input used after validation. The path identifies a
workspace-relative @context.json@ file; the trusted root is supplied separately.
-}
data CreateContextRequest = CreateContextRequest
  { path :: FilePath
  , contextLayer :: ContextLayer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Typed replacement layer used after validation. The path identifies an
existing workspace-relative @context.json@ file, including one with invalid JSON.
-}
data UpdateContextRequest = UpdateContextRequest
  { path :: FilePath
  , contextLayer :: ContextLayer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Delete a workspace-relative @context.json@ file. The HTTP decoder requires
exactly the @path@ field; filesystem validation happens during persistence.
-}
data DeleteContextRequest = DeleteContextRequest
  { path :: FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON DeleteContextRequest where
  parseJSON value = do
    checkShape "DeleteContextRequest" ["path"] value
    withObject "DeleteContextRequest" (\o -> DeleteContextRequest <$> o .: "path") value

instance (FromJSON a) => FromJSON (ScalarOverride a) where
  parseJSON value = do
    case value of
      Object members
        | KeyMap.lookup "tag" members == Just (String "ClearScalar") ->
            checkShape "ScalarOverride" ["tag"] value
      Object members
        | KeyMap.lookup "tag" members == Just (String "SetScalar") ->
            checkShape "ScalarOverride" ["tag", "contents"] value
      _ -> fail "Invalid ScalarOverride tag"

    genericParseJSON defaultOptions{rejectUnknownFields = True} value

instance (FromJSON a) => FromJSON (ListOverride a) where
  parseJSON value = do
    checkShape "ListOverride" ["tag", "contents"] value

    genericParseJSON defaultOptions{rejectUnknownFields = True} value

instance FromJSON RubricOverride where
  parseJSON value = do
    checkShape "RubricOverride" ["tag", "contents"] value

    override <- genericParseJSON defaultOptions{rejectUnknownFields = True} value

    let criteria = case override of
          MergeRubric m -> m
          ReplaceRubric m -> m

    if any (Text.null . Text.strip) (Map.keys criteria)
      then fail "Rubric criterion names must not be blank." <?> Key "contents"
      else pure override

instance FromJSON RubricCriterion where
  parseJSON value = do
    rejectUnknown ["weight", "description"] value
    criterion <- genericParseJSON defaultOptions{rejectUnknownFields = True} value
    case criterion of
      RubricCriterion{weight = w}
        | w < 0 || isNaN w || isInfinite w ->
            fail "Rubric weight must be a finite, nonnegative number." <?> Key "weight"
      RubricCriterion{description = Just desc}
        | Text.null (Text.strip desc) ->
            fail "Rubric description must not be blank." <?> Key "description"
      _ -> pure criterion

instance FromJSON ContextLayer where
  parseJSON value = do
    rejectUnknown ["title", "audience", "model", "tags", "instructions", "grading_directions", "rubric"] value
    layer <- genericParseJSON defaultOptions{rejectUnknownFields = True} value
    let ContextLayer
          { title = titleOverride
          , audience = audienceOverride
          , model = modelOverride
          , tags = tagsOverride
          , instructions = instructionsOverride
          , grading_directions = gradingDirectionsOverride
          } = layer

    mapM_
      (uncurry validateScalar)
      [ ("title", titleOverride)
      , ("audience", audienceOverride)
      , ("model", modelOverride)
      ]

    mapM_
      (uncurry validateList)
      [ ("tags", tagsOverride)
      , ("instructions", instructionsOverride)
      , ("grading_directions", gradingDirectionsOverride)
      ]
    pure layer

{- | Require exactly the listed keys in a tagged operation object.
Non-object values are left to the operation's decoder.
-}
checkShape :: String -> [Key] -> Value -> Parser ()
checkShape _ requiredKeys value@(Object members) = do
  rejectUnknown requiredKeys value
  case filter (\key -> not (KeyMap.member key members)) requiredKeys of
    missing : _ -> fail "Required context field is missing." <?> Key missing
    [] -> pure ()
checkShape _ _ _ = pure ()

{- | Reject the first unexpected object key and retain its diagnostic path.
Leave non-object values to the enclosing type decoder.
-}
rejectUnknown :: [Key] -> Value -> Parser ()
rejectUnknown allowed (Object members) =
  case filter (`notElem` allowed) (KeyMap.keys members) of
    unknown : _ -> fail "Unknown context field." <?> Key unknown
    [] -> pure ()
rejectUnknown _ _ = pure ()

-- | Reject a blank supplied scalar while allowing inheritance and clearing.
validateScalar :: String -> Maybe (ScalarOverride Text) -> Parser ()
validateScalar field (Just (SetScalar text))
  | Text.null (Text.strip text) = fail "Context values must not be blank." <?> Key "contents" <?> Key (fromStringKey field)
validateScalar _ _ = pure ()

-- | Check every supplied item for either list operation.
validateList :: String -> Maybe (ListOverride Text) -> Parser ()
validateList field (Just (AppendList items)) = validateItems field items
validateList field (Just (ReplaceList items)) = validateItems field items
validateList _ Nothing = pure ()

-- | Reject whitespace-only list items without changing valid text.
validateItems :: String -> [Text] -> Parser ()
validateItems field items =
  case findIndex (Text.null . Text.strip) items of
    Just index -> fail "Context list items must not be blank." <?> Index index <?> Key "contents" <?> Key (fromStringKey field)
    Nothing -> pure ()

-- | A public diagnostic contains no decoder excerpts or supplied values.
data ContextDiagnostic = ContextDiagnostic
  { diagnosticField :: Maybe Text
  , diagnosticMessage :: Text
  }
  deriving stock (Eq, Show)

-- | Convert an application-owned field name to an Aeson object key.
fromStringKey :: String -> Key
fromStringKey = Key.fromString

-- | Preserve the decoder path, allowing only application-owned messages.
contextDiagnostic :: (JSONPath, String) -> ContextDiagnostic
contextDiagnostic (location, message) =
  ContextDiagnostic
    (if null location then Nothing else Just (renderField location))
    (if message `elem` safeMessages then Text.pack message else "Context field has an invalid type, shape, or value.")
 where
  safeMessages =
    [ "Required context field is missing."
    , "Unknown context field."
    , "Rubric weight must be a finite, nonnegative number."
    , "Rubric description must not be blank."
    , "Rubric criterion names must not be blank."
    , "Context values must not be blank."
    , "Context list items must not be blank."
    ]

{- | Render a decoder path with dotted identifiers and bracketed indices or
JSON-quoted keys, preserving names that cannot use identifier notation.
-}
renderField :: JSONPath -> Text
renderField = foldl step ""
 where
  step prefix (Index index) = prefix <> "[" <> Text.pack (show index) <> "]"
  step prefix (Key key)
    | identifier name = prefix <> (if Text.null prefix then "" else ".") <> name
    | otherwise = prefix <> "[" <> Encoding.decodeUtf8 (BL.toStrict (encode name)) <> "]"
   where
    name = Key.toText key
  identifier name = case Text.uncons name of
    Just (first, rest) ->
      isAscii first
        && (isLetter first || first == '_')
        && Text.all (\c -> isAscii c && (isAlphaNum c || c == '_')) rest
    Nothing -> False

{- | Validate a decoded JSON value as a context layer, returning sanitized
field diagnostics. Byte-level syntax and duplicate-key checks belong to
'decodeContextLayer', before the value is constructed.
-}
parseContextLayer :: Value -> Either ContextDiagnostic ContextLayer
parseContextLayer = either (Left . contextDiagnostic) Right . iparseEither parseJSON

{- | Decode once with duplicate-key and trailing-input rejection. Syntax errors
have no reliable field/coordinate; never forward raw parser messages.
-}
decodeContextLayer :: BS.ByteString -> Either ContextDiagnostic ContextLayer
decodeContextLayer bytes =
  case eitherDecodeStrictWith (jsonNoDup' <* skipWhile isSpaceByte <* endOfInput) ifromJSON bytes of
    Left _ -> Left (ContextDiagnostic Nothing "Context must contain one valid JSON document with unique object keys.")
    Right value -> parseContextLayer value
 where
  isSpaceByte byte = byte == 32 || byte == 10 || byte == 13 || byte == 9

{- | Decode the envelope at the HTTP boundary; validate the layer in the handler
so a syntactically valid invalid layer returns 422, not Servant's default 400.
-}
data ContextWriteRequest = ContextWriteRequest FilePath Value
  deriving stock (Eq, Show)

instance FromJSON ContextWriteRequest where
  parseJSON value = do
    checkShape "ContextWriteRequest" ["path", "contextLayer"] value
    withObject "ContextWriteRequest" (\o -> ContextWriteRequest <$> o .: "path" <*> o .: "contextLayer") value

instance ToJSON ContextWriteRequest where
  toJSON (ContextWriteRequest path layer) = object ["path" .= path, "contextLayer" .= layer]
