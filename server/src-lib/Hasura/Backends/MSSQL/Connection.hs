module Hasura.Backends.MSSQL.Connection where

import           Hasura.Prelude

import qualified Data.Pool               as Pool
import qualified Database.ODBC.SQLServer as ODBC

import           Control.Exception
import           Data.Aeson
import           Data.Aeson.Casing
import           Data.Aeson.TH

import           Hasura.Incremental      (Cacheable (..))
import           Hasura.RQL.Types.Error

-- | ODBC connection string for MSSQL server
newtype MSSQLConnectionString
  = MSSQLConnectionString {unMSSQLConnectionString :: Text}
  deriving (Show, Eq, ToJSON, FromJSON, Cacheable, Hashable, NFData, Arbitrary)

data MSSQLPoolSettings
  = MSSQLPoolSettings
  { _mpsMaxConnections :: !Int
  , _mpsIdleTimeout    :: !Int
  } deriving (Show, Eq, Generic)
instance Cacheable MSSQLPoolSettings
instance Hashable MSSQLPoolSettings
instance NFData MSSQLPoolSettings
$(deriveToJSON hasuraJSON ''MSSQLPoolSettings)

instance FromJSON MSSQLPoolSettings where
  parseJSON = withObject "MSSQL pool settings" $ \o ->
    MSSQLPoolSettings
      <$> o .:? "max_connections" .!= _mpsMaxConnections defaultMSSQLPoolSettings
      <*> o .:? "idle_timeout"    .!= _mpsIdleTimeout    defaultMSSQLPoolSettings

instance Arbitrary MSSQLPoolSettings where
  arbitrary = genericArbitrary

defaultMSSQLPoolSettings :: MSSQLPoolSettings
defaultMSSQLPoolSettings =
  MSSQLPoolSettings
  { _mpsMaxConnections = 50
  , _mpsIdleTimeout    = 5
  }

data MSSQLConnectionInfo
  = MSSQLConnectionInfo
  { _mciConnectionString :: !MSSQLConnectionString
  , _mciPoolSettings     :: !MSSQLPoolSettings
  } deriving (Show, Eq, Generic)
instance Cacheable MSSQLConnectionInfo
instance Hashable MSSQLConnectionInfo
instance NFData MSSQLConnectionInfo
$(deriveToJSON hasuraJSON ''MSSQLConnectionInfo)

instance Arbitrary MSSQLConnectionInfo where
  arbitrary = genericArbitrary


instance FromJSON MSSQLConnectionInfo where
  parseJSON = withObject "Object" $ \o ->
    MSSQLConnectionInfo
      <$> ((o .: "database_url") <|> (o .: "connection_string"))
      <*> o .:? "pool_settings" .!= defaultMSSQLPoolSettings

data MSSQLConnConfiguration
  = MSSQLConnConfiguration
  { _mccConnectionInfo :: !MSSQLConnectionInfo
  } deriving (Show, Eq, Generic)
instance Cacheable MSSQLConnConfiguration
instance Hashable MSSQLConnConfiguration
instance NFData MSSQLConnConfiguration
$(deriveJSON hasuraJSON ''MSSQLConnConfiguration)

instance Arbitrary MSSQLConnConfiguration where
  arbitrary = genericArbitrary

newtype MSSQLPool
  = MSSQLPool { unMSSQLPool :: Pool.Pool ODBC.Connection }

createMSSQLPool :: MSSQLConnectionInfo -> IO MSSQLPool
createMSSQLPool (MSSQLConnectionInfo connString MSSQLPoolSettings{..}) =
  MSSQLPool <$>
    Pool.createPool (ODBC.connect $ unMSSQLConnectionString connString)
    ODBC.close 1 (fromIntegral _mpsIdleTimeout) _mpsMaxConnections

drainMSSQLPool :: MSSQLPool -> IO ()
drainMSSQLPool (MSSQLPool pool) =
  Pool.destroyAllResources pool

odbcExceptionToJSONValue :: ODBC.ODBCException -> Value
odbcExceptionToJSONValue =
  $(mkToJSON defaultOptions{constructorTagModifier = snakeCase} ''ODBC.ODBCException)

runJSONPathQuery
  :: (MonadError QErr m, MonadIO m)
  => MSSQLPool -> ODBC.Query -> m Text
runJSONPathQuery pool query = do
  mconcat <$> withMSSQLPool pool (`ODBC.query` query)

withMSSQLPool
  :: (MonadError QErr m, MonadIO m)
  => MSSQLPool -> (ODBC.Connection -> IO a) -> m a
withMSSQLPool (MSSQLPool pool) f = do
  res <- liftIO $ try $ Pool.withResource pool f
  onLeft res $ \e ->
    throw500WithDetail "sql server exception" $ odbcExceptionToJSONValue e

data MSSQLSourceConfig
  = MSSQLSourceConfig
  { _mscConnectionString :: !MSSQLConnectionString
  , _mscConnectionPool   :: !MSSQLPool
  } deriving (Generic)

instance Show MSSQLSourceConfig where
  show = show . _mscConnectionString

instance Eq MSSQLSourceConfig where
  MSSQLSourceConfig connStr1 _ == MSSQLSourceConfig connStr2 _ =
    connStr1 == connStr2

instance Cacheable MSSQLSourceConfig where
  unchanged _ = (==)

instance ToJSON MSSQLSourceConfig where
  toJSON = toJSON . _mscConnectionString
