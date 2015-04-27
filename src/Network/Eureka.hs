{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Eureka (
  withEureka,
  EurekaConfig(..),
  InstanceConfig(..),
  def,
  discoverDataCenterAmazon,
  setStatus,
  lookupByAppName,
  lookupAllApplications,
  InstanceInfo(..),
  InstanceStatus(..),
  DataCenterInfo(..),
  AmazonDataCenterInfo(..),
  EurekaConnection,
  AvailabilityZone,
  Region,
  addMetadata,
  lookupMetadata
) where

import           Control.Applicative       ((<$>), (<*>))
import           Control.Concurrent        (ThreadId, forkIO, killThread,
                                            threadDelay)
import           Control.Concurrent.STM    (TVar, atomically, newTVar, readTVar,
                                            writeTVar)
import           Control.Exception         (SomeException, bracket, throw, try)
import           Control.Monad             (foldM, mzero, when)
import           Control.Monad.Fix         (mfix)
import           Data.Aeson                (FromJSON (parseJSON),
                                            Value (Object, Array), eitherDecode,
                                            encode, object, (.:), (.=))
import           Data.Aeson.Types          (parseEither)
import qualified Data.ByteString.Lazy      as LBS
import           Data.Default              (def)
import           Data.List                 (elemIndex, find, nub)
import           Data.Map                  (Map)
import qualified Data.Map                  as Map
import           Data.Maybe                (fromJust, fromMaybe, isNothing)
import qualified Data.Text                 as T
import           Data.Text.Encoding        (decodeUtf8, encodeUtf8)
import qualified Data.Vector               as V
import           Network.BSD               (getHostName)
import           Network.Eureka.Types      (AmazonDataCenterInfo (..),
                                            AvailabilityZone,
                                            DataCenterInfo (..),
                                            EurekaConfig (..),
                                            EurekaConnection (..),
                                            IIRState (..),
                                            InstanceConfig (..),
                                            InstanceInfo (..),
                                            InstanceStatus (..), Region,
                                            toNetworkName)
import           Network.HTTP.Client       (HttpException (HandshakeFailed),
                                            Manager, Request (checkStatus, method, requestBody, requestHeaders),
                                            RequestBody (RequestBodyLBS),
                                            defaultManagerSettings, httpLbs,
                                            parseUrl, queryString, responseBody,
                                            responseStatus, withManager,
                                            withResponse)
import           Network.HTTP.Types.Method (methodDelete, methodPost, methodPut)
import           Network.HTTP.Types.Status (status404)
import           Network.Socket            (AddrInfo (addrAddress, addrFamily),
                                            Family (AF_INET), HostName,
                                            NameInfoFlag (NI_NUMERICHOST),
                                            defaultHints, getAddrInfo,
                                            getNameInfo)
import           System.Log.Logger         (debugM, errorM, infoM)

import Network.Eureka.Request (makeRequest)
import Network.Eureka.Util (parseUrlWithAdded)

-- | Interrogate the magical URL http://169.254.169.254/latest/meta-data to
-- fill in an DataCenterAmazon.
discoverDataCenterAmazon :: Manager -> IO AmazonDataCenterInfo
discoverDataCenterAmazon manager =
    AmazonDataCenterInfo <$>
        getMeta "ami-id" <*>
        (read <$> getMeta "ami-launch-index") <*>
        getMeta "instance-id" <*>
        getMeta "instance-type" <*>
        getMeta "local-ipv4" <*>
        getMeta "placement/availability-zone" <*>
        getMeta "public-hostname" <*>
        getMeta "public-ipv4"
  where
    getMeta :: String -> IO String
    getMeta pathName = fromBS . responseBody <$> httpLbs metaRequest manager
      where
        metaRequest = fromJust . parseUrl $ "http://169.254.169.254/latest/meta-data/" ++ pathName
        fromBS = T.unpack . decodeUtf8 . LBS.toStrict

withEureka :: EurekaConfig -> InstanceConfig -> DataCenterInfo
           -> (EurekaConnection -> IO a) -> IO a
withEureka eConfig iConfig iInfo m =
    withManager defaultManagerSettings $ \manager ->
    bracket (connectEureka manager eConfig iConfig iInfo) disconnectEureka registerAndRun
  where
    registerAndRun eConn = do
        registerInstance eConn
        m eConn

lookupByAppName :: EurekaConnection -> String -> IO [InstanceInfo]
lookupByAppName eConn@EurekaConnection { eConnManager } appName = do
    result <- makeRequest eConn getByAppName
    either error (return . applicationInstanceInfos) result
  where
    getByAppName url = do
        response <- eitherDecode . responseBody <$> httpLbs (request url) eConnManager
        return $ parseEither (.: "application") =<< response
    request url = requestJSON $ parseUrlWithAdded url $ "apps/" ++ appName


{- |
  Returns all instances of all applications that eureka knows about,
  arranged by application name.
-}
lookupAllApplications :: EurekaConnection -> IO (Map String [InstanceInfo])
lookupAllApplications eConn@EurekaConnection {eConnManager} = do
    result <- makeRequest eConn getAllApps
    either error (return . toAppMap) result
  where
    getAllApps :: String -> IO (Either String Applications)
    getAllApps url =
      eitherDecode . responseBody <$> httpLbs request eConnManager
      where
        request = requestJSON (parseUrlWithAdded url "apps")

    toAppMap :: Applications -> Map String [InstanceInfo]
    toAppMap = Map.fromList . fmap appToTuple . applications

    appToTuple :: Application -> (String, [InstanceInfo])
    appToTuple (Application name infos) = (name, infos)


{- |
  Response type from Eureka "apps/" API.
-}
newtype Applications = Applications {applications :: [Application]}
instance FromJSON Applications where
  parseJSON (Object o) = do
    -- The design of the structured data coming out of Eureka is
    -- perplexing, to say the least.
    Object o2 <- o.: "applications"
    Array ary <- o2 .: "application"
    Applications <$> mapM parseJSON (V.toList ary)
  parseJSON v =
    fail (
      "Failed to parse list of all instances registered with \
      \Eureka. Bad value was " ++ show v ++ " when it should \
      \have been an object."
    )


-- | Response type from Eureka "apps/APP_NAME" API.
data Application = Application {
    _applicationName         :: String,
    applicationInstanceInfos :: [InstanceInfo]
    } deriving Show

instance FromJSON Application where
    parseJSON (Object v) = do
        name <- v .: "name"
        instanceOneOrMany <- v .: "instance"
        instanceData <- case instanceOneOrMany of
            (Array ary) -> mapM parseJSON (V.toList ary)
            o@(Object _) -> do
                instanceInfo <- parseJSON o
                return [instanceInfo]
            other -> fail $ "instance data was of a strange format: " ++ show other
        return $ Application name instanceData
    parseJSON _ = mzero

setStatus :: EurekaConnection -> InstanceStatus -> IO ()
setStatus eConn@EurekaConnection { eConnManager, eConnStatus } newStatus = do
    atomically $ writeTVar eConnStatus newStatus
    makeRequest eConn updateStatus
  where
    updateStatus url = withResponse (statusRequest url) eConnManager $ \_ ->
        return ()
    statusRequest url = (parseUrlWithAdded url $ eConnAppPath eConn ++ "/status") {
          method = methodPut
        , queryString = encodeUtf8 . T.pack $ "value=" ++ toNetworkName newStatus
        }

registerInstance :: EurekaConnection -> IO ()
registerInstance eConn@EurekaConnection { eConnManager,
        eConnInstanceConfig = InstanceConfig {instanceAppName}
    } = do
    instanceInfo <- readEConnInstanceInfo eConn
    makeRequest eConn (sendRegister instanceInfo)
  where
    sendRegister instanceInfo url =
        withResponse (registerRequest url instanceInfo) eConnManager $ \_ ->
            return ()
    registerRequest url instanceInfo =
        (parseUrlWithAdded url $ "apps/" ++ instanceAppName) {
          method = methodPost
        , requestHeaders = [("Content-Type", "application/json")]
        , requestBody = RequestBodyLBS $ encode $ object [
            "instance" .= instanceInfo
            ]
        }

-- | Read the instance's status and use it to produce an InstanceInfo.
readEConnInstanceInfo :: EurekaConnection -> IO InstanceInfo
readEConnInstanceInfo eConn = eConnInstanceInfo eConn <$> readStatus eConn

-- | A helper function to read the instance's status.
readStatus :: EurekaConnection -> IO InstanceStatus
readStatus EurekaConnection { eConnStatus } = atomically (readTVar eConnStatus)

-- | Build an InstanceInfo describing this instance using information in a
-- EurekaConnection and the given status.  Reading status is impure, but this
-- function can do the bulk of the pure work.
eConnInstanceInfo :: EurekaConnection -> InstanceStatus -> InstanceInfo
eConnInstanceInfo eConn@EurekaConnection {
      eConnDataCenterInfo
    , eConnInstanceConfig = InstanceConfig {
          instanceAppName
        , instanceNonSecurePort
        , instanceSecurePort
        , instanceMetadata
        }
    } status = InstanceInfo {
      instanceInfoHostName = eConnPublicHostname eConn
    , instanceInfoAppName = instanceAppName
    , instanceInfoIpAddr = eConnPublicIpv4 eConn
    , instanceInfoVipAddr = eConnVirtualHostname eConn
    , instanceInfoSecureVipAddr = eConnSecureVirtualHostname eConn
    , instanceInfoStatus = status
    , instanceInfoPort = instanceNonSecurePort
    , instanceInfoSecurePort = instanceSecurePort
    , instanceInfoHomePageUrl = Just $ eConnHomePageUrl eConn
    , instanceInfoStatusPageUrl = Just $ eConnStatusPageUrl eConn
    , instanceInfoDataCenterInfo = eConnDataCenterInfo
    , instanceInfoMetadata = instanceMetadata
    , instanceInfoIsCoordinatingDiscoveryServer = False
    }

-- | Get the virtual hostname from the Eureka connection, taking the real
-- hostname and instance configuration into account.
eConnVirtualHostname :: EurekaConnection -> String
eConnVirtualHostname eConn@EurekaConnection {
    eConnInstanceConfig = InstanceConfig {
            instanceNonSecurePort,
            instanceVirtualHostname } } =
    fromMaybe
      (eConnPublicHostname eConn ++ ":" ++ show instanceNonSecurePort)
      instanceVirtualHostname

eConnSecureVirtualHostname :: EurekaConnection -> String
eConnSecureVirtualHostname eConn@EurekaConnection {
    eConnInstanceConfig = InstanceConfig {
            instanceSecurePort,
            instanceSecureVirtualHostname } } =
    fromMaybe
      (eConnPublicHostname eConn ++ ":" ++ show instanceSecurePort)
      instanceSecureVirtualHostname

-- | Return the best hostname available.
eConnPublicHostname :: EurekaConnection -> String
eConnPublicHostname EurekaConnection {
    eConnDataCenterInfo = DataCenterAmazon AmazonDataCenterInfo {
            amazonPublicHostname } } = amazonPublicHostname
eConnPublicHostname EurekaConnection { eConnHostname } = eConnHostname

-- | Return the best IP address available.
eConnPublicIpv4 :: EurekaConnection -> String
eConnPublicIpv4 EurekaConnection {
    eConnDataCenterInfo = DataCenterAmazon AmazonDataCenterInfo {
            amazonPublicIpv4 } } = amazonPublicIpv4
eConnPublicIpv4 EurekaConnection { eConnHostIpv4 } = eConnHostIpv4

-- | Return instance's status page URL.
--
-- The full URL should follow the format @http://${eureka.hostname}:8080/@ where
-- the value @${eureka.hostname}@ is replaced at runtime with instance's public
-- hostname.
eConnStatusPageUrl :: EurekaConnection -> String
eConnStatusPageUrl eConn@EurekaConnection {
      eConnInstanceConfig = InstanceConfig { instanceStatusPageUrl }
    } =
  interpolateInstanceUrl eConn (fromMaybe "" instanceStatusPageUrl)

-- | Return instance's home page URL.
--
-- The full URL should follow the format @http://${eureka.hostname}:8080/@ where
-- the value @${eureka.hostname}@ is replaced at runtime with instance's public
-- hostname.
eConnHomePageUrl :: EurekaConnection -> String
eConnHomePageUrl eConn@EurekaConnection {
      eConnInstanceConfig = InstanceConfig { instanceHomePageUrl }
    } =
  interpolateInstanceUrl eConn instanceHomePageUrl

-- | Interpolate instance URL.
--
-- Given a URL that follows the format @http://${eureka.hostname}:8080/@, it
-- replaces the value @${eureka.hostname}@ with instance's public hostname.
interpolateInstanceUrl :: EurekaConnection -> String -> String
interpolateInstanceUrl eConn instanceUrl =
  T.unpack $ T.replace
    (T.pack "${eureka.hostname}")
    (T.pack (eConnPublicHostname eConn))
    (T.pack instanceUrl)



disconnectEureka :: EurekaConnection -> IO ()
disconnectEureka eConn@EurekaConnection {
    eConnHeartbeatThread, eConnInstanceInfoReplicatorThread
    } = do
    killThread eConnHeartbeatThread
    killThread eConnInstanceInfoReplicatorThread
    setStatus eConn Down
    unregister eConn


unregister :: EurekaConnection -> IO ()
unregister eConn@EurekaConnection { eConnManager } = do
    -- N.B. This also catches all exceptions (see above), which the Java version
    -- does, presumably because unregistering could be something that happens as
    -- the instance crashes, and we don't want to mask the legitimate failure
    -- with some other frivolous failure that comes out of our failure to
    -- deregister.
    result <- try reallyUnregister
    case result of
        Right _ -> return ()
        Left err -> let errMsg = show (err :: SomeException) in
            errorM "Eureka.unregister" $
            appPath ++ " - de-registration failed " ++ errMsg
  where
    reallyUnregister = do
        responseStatus <- makeRequest eConn sendUnregister
        -- the two spaces between "deregister" and "status" are copied from the
        -- Java implementation
        infoM "Eureka.unregister" $
                appPath ++ " - deregister  status: " ++ show responseStatus
    appPath = eConnAppPath eConn
    sendUnregister url = withResponse (unregisterRequest url) eConnManager $
                        \resp -> return $ responseStatus resp
    unregisterRequest url = (parseUrlWithAppPath url eConn) {
          method = methodDelete
          }


type HeartbeatState = ()

postHeartbeat :: EurekaConnection -> HeartbeatState -> IO HeartbeatState
postHeartbeat eConn@EurekaConnection {
    eConnInstanceConfig = InstanceConfig { instanceAppName },
    eConnManager
    } () = do
    -- N.B. This is more-or-less what's described by the Control.Exception
    -- documentation under "Catching all exceptions". We use try instead of
    -- catch because we aren't interested in asynchronous exceptions, so
    -- hopefully this won't accidentally catch too many exceptions.
    result <- try reallyPostHeartbeat
    case result of
        Right _ -> return ()
        Left err -> let errMsg = show (err :: SomeException) in
            errorM "Eureka.postHeartbeat" $
            appPath ++ " - was unable to send heartbeat! " ++ errMsg
  where
    reallyPostHeartbeat = do
        responseStatus <- makeRequest eConn sendHeartbeat
        debugM "Eureka.postHeartbeat" $
            appPath ++ " - Heartbeat status: " ++ show responseStatus
        when (responseStatus == status404) $ do
            infoM "Eureka.postHeartbeat" $
                appPath ++ " - Re-registering apps/" ++ instanceAppName
            registerInstance eConn
    appPath = eConnAppPath eConn
    sendHeartbeat url = withResponse (heartbeatRequest url) eConnManager $
                        \resp -> return $ responseStatus resp
    heartbeatRequest url = (parseUrlWithAppPath url eConn) {
          method = methodPut,
          checkStatus = \_ _ _ -> Nothing   -- so we can reregister if we get a 404
          }

updateInstanceInfo :: EurekaConnection -> IIRState -> IO IIRState
updateInstanceInfo eConn oldState@IIRState { iirLastAMIId } = do
    eurekaServer <- getCoordinatingServer
    maybe (return oldState) updateDiscoveryServer eurekaServer
  where
    getCoordinatingServer :: IO (Maybe InstanceInfo)
    getCoordinatingServer = do
        -- N.B. The Java client does an in-memory lookup in a prepopulated hash
        -- rather than issuing the query itself. Failure there means getting a
        -- 'null' response. Here we can hit a 404 and die. Let's just replicate
        -- the silent failure of the Java version.
        eInstances <- try (lookupByAppName eConn discoveryAppId)
                      :: IO (Either HttpException [InstanceInfo])
        return $ case eInstances of
            Left _ -> Nothing
            Right instances -> find coordinator instances

    coordinator = instanceInfoIsCoordinatingDiscoveryServer
    updateDiscoveryServer :: InstanceInfo -> IO IIRState
    updateDiscoveryServer eurekaServer = do
        let mnewAMI = maybeGetAMIId eurekaServer
        maybe
            (return oldState { iirLastAMIId = mnewAMI })
            (checkDiscoveryServerChanged mnewAMI) iirLastAMIId

    checkDiscoveryServerChanged :: Maybe String -> String -> IO IIRState
    checkDiscoveryServerChanged mnewAMI lastAMI =
        if isNothing mnewAMI || mnewAMI == Just lastAMI
            then return oldState
            else do
            infoM "Eureka.updateInstanceInfo" $ "The eureka AMI ID changed from "
                ++ lastAMI ++ " to " ++ fromJust mnewAMI
                ++ ". Pushing the appinfo to eureka"

            status <- readStatus eConn
            -- N.B. The original client does this whenever the instance info is
            -- "dirty" -- its status or its metadata were updated. Additionally,
            -- its status can change as a result of a health check (in this
            -- thread).
            --
            -- We push status changes to Eureka immediately, so we don't do that
            -- here. We don't support mutable metadata yet either. Finally, we
            -- don't support health checks. In other words, this log message is
            -- a little redundant.
            infoM "Eureka.updateInstanceInfo" $ eConnAppPath eConn
                ++ " - retransmit instance info with status "
                ++ show status
            registerInstance eConn
            return oldState { iirLastAMIId = mnewAMI }

    maybeGetAMIId :: InstanceInfo -> Maybe String
    maybeGetAMIId InstanceInfo {
        instanceInfoDataCenterInfo =
          DataCenterAmazon AmazonDataCenterInfo { amazonAmiId }
      } = Just amazonAmiId
    maybeGetAMIId _ = Nothing
    -- FIXME: this is copied straight out of the Eureka source code, but there's
    -- no server on my network called DISCOVERY, so I don't know how it works.
    discoveryAppId = "DISCOVERY"

connectEureka :: Manager
              -> EurekaConfig -> InstanceConfig -> DataCenterInfo
              -> IO EurekaConnection
connectEureka manager
    eConfig@EurekaConfig{
        eurekaInstanceInfoReplicationInterval=instanceInfoInterval
        }
    iConfig@InstanceConfig{
        instanceLeaseRenewalInterval=heartbeatInterval
        , instanceEnabledOnInit
        } dataCenterInfo = mfix $ \econn -> do
    heartbeatThreadId <- forkIO $ heartbeatThread econn ()
    instanceInfoThreadId <- forkIO $ instanceInfoThread econn def
    statusVar <- atomically $ newTVar (if instanceEnabledOnInit then Up else Starting)

    hostname <- getHostName
    hostResolved <- getAddrInfo (Just myHints) (Just hostname) Nothing
    (Just hostIpv4, _) <- getNameInfo [NI_NUMERICHOST] True False
                          . addrAddress . head $ hostResolved
    return EurekaConnection {
          eConnEurekaConfig = eConfig
        , eConnInstanceConfig = iConfig
        , eConnHeartbeatThread = heartbeatThreadId
        , eConnInstanceInfoReplicatorThread = instanceInfoThreadId
        , eConnManager = manager
        , eConnDataCenterInfo = dataCenterInfo
        , eConnHostname = hostname
        , eConnHostIpv4 = hostIpv4
        , eConnStatus = statusVar
        }
  where
    heartbeatThread :: EurekaConnection -> () -> IO ()
    heartbeatThread = repeating heartbeatInterval . postHeartbeat
    instanceInfoThread = repeating instanceInfoInterval . updateInstanceInfo
    myHints = defaultHints { addrFamily = AF_INET }

eConnAppPath :: EurekaConnection -> String
eConnAppPath eConn@EurekaConnection {
    eConnInstanceConfig = InstanceConfig {instanceAppName}
    } =
    "apps/" ++ instanceAppName ++ "/" ++ eConnInstanceId eConn

-- | Produce an ID to use when identifying this instance.  If running in a
-- datacenter, this gets the ID of the machine.  Otherwise, falls back to the
-- hostname.
eConnInstanceId :: EurekaConnection -> String
eConnInstanceId EurekaConnection {
    eConnDataCenterInfo =
      DataCenterAmazon AmazonDataCenterInfo { amazonInstanceId }
  } = amazonInstanceId
eConnInstanceId EurekaConnection { eConnHostname } = eConnHostname

parseUrlWithAppPath :: String -> EurekaConnection -> Request
parseUrlWithAppPath url = parseUrlWithAdded url . eConnAppPath

requestJSON :: Request -> Request
requestJSON r = r {
    requestHeaders = ("Accept", encodeUtf8 "application/json") : requestHeaders r
    }

-- | Perform an action every 'delay' seconds.
-- This action keeps track of its internal state using 'a'.
-- Delays are not exact; we use threadDelay to schedule the repetition.
repeating :: Int -> (a -> IO a) -> a -> IO ()
repeating i f = loop
  where
    loop a0 = do
        result <- f a0
        threadDelay (i * 1000 * 1000)
        loop result

-- | Adds a key-value pair to InstanceConfig's existing metadata.
addMetadata
  :: (String, String)
  -> InstanceConfig
  -> InstanceConfig
addMetadata (key, value) info@InstanceConfig{instanceMetadata = metadata}
  = info {instanceMetadata = Map.insert key value metadata}

-- | Looks up a value corresponding to a given key in InstanceConfig's metadata.
lookupMetadata
  :: String
  -> InstanceInfo
  -> Maybe String
lookupMetadata key InstanceInfo{instanceInfoMetadata = metadata}
  = Map.lookup key metadata
