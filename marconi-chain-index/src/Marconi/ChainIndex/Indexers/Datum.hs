{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Marconi.ChainIndex.Indexers.Datum
  ( -- * DatumIndex
    DatumIndex
  , Event
  , Query
  , Result
  , Notification
  , Depth(..)
  , open
  ) where

import Codec.Serialise (Serialise (encode), deserialiseOrFail, serialise)
import Control.Applicative ((<|>))
import Control.Lens.Operators ((^.))
import Data.ByteString.Lazy (toStrict)
import Data.Foldable (find)
import Data.Maybe (fromJust, listToMaybe)
import Database.SQLite.Simple (Only (Only), SQLData (SQLBlob, SQLInteger))
import Database.SQLite.Simple qualified as SQL
import Database.SQLite.Simple.FromField (FromField (fromField), ResultError (ConversionFailed), returnError)
import Database.SQLite.Simple.ToField (ToField (toField))

import Cardano.Api qualified as C
import Cardano.Binary (fromCBOR, toCBOR)
import Codec.Serialise.Class (Serialise (decode))
import Marconi.Core.Index.VSqlite (SqliteIndex)
import Marconi.Core.Index.VSqlite qualified as Ix

type DatumHash    = C.Hash C.ScriptData
type Event        = [(C.SlotNo, (DatumHash, C.ScriptData))]
type Query        = DatumHash
type Result       = Maybe C.ScriptData
type Notification = ()

type DatumIndex = SqliteIndex Event Notification Query Result

newtype Depth = Depth Int

instance FromField DatumHash where
  fromField f = fromField f >>=
    maybe (returnError ConversionFailed f "Cannot deserialise datumhash.")
           pure
    . C.deserialiseFromRawBytes (C.AsHash C.AsScriptData)

instance ToField DatumHash where
  toField = SQLBlob . C.serialiseToRawBytes

instance Serialise C.ScriptData where
  encode = toCBOR
  decode = fromCBOR

instance FromField C.ScriptData where
  fromField f = fromField f >>=
    either (const $ returnError ConversionFailed f "Cannot deserialise datumhash.") pure
    . deserialiseOrFail

instance ToField C.ScriptData where
  toField = SQLBlob . toStrict . serialise

instance FromField C.SlotNo where
  fromField f = C.SlotNo <$> fromField f

instance ToField C.SlotNo where
  toField (C.SlotNo s) = SQLInteger $ fromIntegral s

open
  :: FilePath
  -> Depth
  -> IO DatumIndex
open dbPath (Depth k) = do
  ix <- fromJust <$> Ix.newBoxed query store onInsert k ((k + 1) * 2) dbPath
  let c = ix ^. Ix.handle
  SQL.execute_ c "PRAGMA journal_mode=WAL"
  SQL.execute_ c "CREATE TABLE IF NOT EXISTS kv_datumhsh_datum (datumHash TEXT PRIMARY KEY, datum BLOB, slotNo INT)"
  pure ix

-- | This function is used to query the data stored in the indexer as a whole:
--   data that can still change (through rollbacks), buffered data and stored data.
--
--   Here is a query that takes into account all received events:
--   > getEvents (ix ^. storage) >>= query ix <hash>
--
--   Here is a query that only takes into account stored events:
--   > query ix <hash> []
query
  :: DatumIndex -- ^ The indexer
  -> Query      -- ^ The query is a `DatumHash`
  -> [Event]    -- ^ The list of events that we want to query on top of whatever is settled.
  -> IO Result  -- ^ The result is an optional datum.
query ix hsh es = memoryResult <|> sqliteResult
  where
    -- TODO: Consider buffered events
    memoryResult :: IO Result
    memoryResult = do
      bufferedEvents <- Ix.getBuffer (ix ^. Ix.storage)
      pure $ snd . snd <$> find ((== hsh) . fst . snd) (concat $ es ++ bufferedEvents)
    sqliteResult :: IO Result
    sqliteResult = do
      result <- SQL.query (ix ^. Ix.handle) "SELECT datum from kv_datumhsh_datum WHERE datumHash = ?" (Only hsh)
      pure $ head <$> listToMaybe result

store :: DatumIndex -> IO ()
store ix = do
  let c = ix ^. Ix.handle
  SQL.execute_ c "BEGIN"
  Ix.getBuffer (ix ^. Ix.storage) >>=
    mapM_ ( SQL.execute c "INSERT INTO kv_datumhsh_datum (slotNo, datumHash, datum) VALUES (?,?,?) ON CONFLICT(datumHash) DO UPDATE SET slotNo = ?"
          . unpack)
    . concat
  SQL.execute_ c "COMMIT"
  where
    unpack :: (C.SlotNo, (DatumHash, C.ScriptData)) -> (C.SlotNo, DatumHash, C.ScriptData, C.SlotNo)
    unpack (s, (h, d)) = (s, h, d, s)

onInsert :: DatumIndex -> Event -> IO [Notification]
onInsert _ _ = pure []
