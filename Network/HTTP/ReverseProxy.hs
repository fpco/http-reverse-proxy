{-# LANGUAGE OverloadedStrings, FlexibleContexts, ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}
module Network.HTTP.ReverseProxy
    ( -- * Types
      ProxyDest (..)
      -- * Raw
    , rawProxyTo
      -- * WAI + http-conduit
    , waiProxyTo
    , defaultOnExc
    , waiProxyToSettings
    , WaiProxyResponse (..)
      -- ** Settings
    , WaiProxySettings
    , def
    , wpsOnExc
    , wpsTimeout
    , wpsSetIpHeader
    , wpsProcessBody
    , wpsUpgradeToRaw
    , SetIpHeader (..)
    {- FIXME
      -- * WAI to Raw
    , waiToRaw
    -}
    ) where

import Data.Conduit
#if MIN_VERSION_conduit(1,1,0)
import Data.Streaming.Network (readLens, AppData)
import Data.Functor.Identity (Identity (..))
import Data.Maybe (fromMaybe)
#else
import Data.Conduit.Network (AppData)
#endif
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Default.Class (def)
import qualified Network.Wai as WAI
import qualified Network.HTTP.Client as HC
import Network.HTTP.Client (BodyReader, brRead)
#if MIN_VERSION_wai(3,0,0)
import Control.Exception (bracket)
#else
import Control.Exception (bracketOnError)
#endif
import Blaze.ByteString.Builder (fromByteString)
import Data.Word8 (isSpace, _colon, _cr)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Network.HTTP.Types as HT
import qualified Data.CaseInsensitive as CI
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.Text.Lazy as TL
import qualified Data.Conduit.Network as DCN
import Control.Concurrent.MVar.Lifted (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Lifted (fork, killThread)
import Data.Default.Class (Default (..))
import Network.Wai.Logger (showSockAddr)
import qualified Data.Set as Set
import Data.IORef
#if MIN_VERSION_wai(2, 1, 0)
import qualified Data.ByteString.Lazy as L
import Control.Concurrent.Async (concurrently)
import Blaze.ByteString.Builder (Builder, toLazyByteString)
#else
import Blaze.ByteString.Builder (Builder)
#endif
import Data.ByteString (ByteString)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad (unless, void)
import Data.Int (Int64)
import Data.Monoid (mappend, (<>), mconcat)
import Control.Exception.Lifted (try, SomeException, finally)
import Control.Applicative ((<$>), (<|>))
import Data.Set (Set)
import qualified Data.Conduit.List as CL

-- | Host\/port combination to which we want to proxy.
data ProxyDest = ProxyDest
    { pdHost :: !ByteString
    , pdPort :: !Int
    }

-- | Set up a reverse proxy server, which will have a minimal overhead.
--
-- This function uses raw sockets, parsing as little of the request as
-- possible. The workflow is:
--
-- 1. Parse the first request headers.
--
-- 2. Ask the supplied function to specify how to reverse proxy.
--
-- 3. Open up a connection to the given host\/port.
--
-- 4. Pass all bytes across the wire unchanged.
--
-- If you need more control, such as modifying the request or response, use 'waiProxyTo'.
#if MIN_VERSION_conduit(1,1,0)
rawProxyTo :: (MonadBaseControl IO m, MonadIO m)
           => (HT.RequestHeaders -> m (Either (DCN.AppData -> m ()) ProxyDest))
           -- ^ How to reverse proxy. A @Left@ result will run the given
           -- 'DCN.Application', whereas a @Right@ will reverse proxy to the
           -- given host\/port.
           -> AppData -> m ()
#else
rawProxyTo :: (MonadBaseControl IO m, MonadIO m)
           => (HT.RequestHeaders -> m (Either (DCN.AppData m -> m ()) ProxyDest))
           -- ^ How to reverse proxy. A @Left@ result will run the given
           -- 'DCN.Application', whereas a @Right@ will reverse proxy to the
           -- given host\/port.
           -> AppData m -> m ()
#endif
rawProxyTo getDest appdata = do
#if MIN_VERSION_conduit(1,1,0)
    (rsrc, headers) <- liftIO $ fromClient $$+ getHeaders
#else
    (rsrc, headers) <- fromClient $$+ getHeaders
#endif
    edest <- getDest headers
    case edest of
        Left app -> do
            -- We know that the socket will be closed by the toClient side, so
            -- we can throw away the finalizer here.
#if MIN_VERSION_conduit(1,1,0)
            irsrc <- liftIO $ newIORef rsrc
            let readData = do
                    rsrc1 <- readIORef irsrc
                    (rsrc2, mbs) <- rsrc1 $$++ await
                    writeIORef irsrc rsrc2
                    return $ fromMaybe "" mbs
            app $ runIdentity (readLens (const (Identity readData)) appdata)
#else
            (fromClient', _) <- unwrapResumable rsrc
            app appdata { DCN.appSource = fromClient' }
#endif


#if MIN_VERSION_conduit(1,1,0)
        Right (ProxyDest host port) -> liftIO $ DCN.runTCPClient (DCN.clientSettings port host) (withServer rsrc)
#else
        Right (ProxyDest host port) -> DCN.runTCPClient (DCN.clientSettings port host) (withServer rsrc)
#endif
  where
    fromClient = DCN.appSource appdata
    toClient = DCN.appSink appdata
    withServer rsrc appdataServer = do
        x <- newEmptyMVar
        tid1 <- fork $ (rsrc $$+- toServer) `finally` putMVar x True
        tid2 <- fork $ (fromServer $$ toClient) `finally` putMVar x False
        y <- takeMVar x
        killThread $ if y then tid2 else tid1
      where
        fromServer = DCN.appSource appdataServer
        toServer = DCN.appSink appdataServer

-- | Sends a simple 502 bad gateway error message with the contents of the
-- exception.
defaultOnExc :: SomeException -> WAI.Application
#if MIN_VERSION_wai(3,0,0)
defaultOnExc exc _ sendResponse = sendResponse $ WAI.responseLBS
#else
defaultOnExc exc _ = return $ WAI.responseLBS
#endif
    HT.status502
    [("content-type", "text/plain")]
    ("Error connecting to gateway:\n\n" <> TLE.encodeUtf8 (TL.pack $ show exc))

-- | The different responses that could be generated by a @waiProxyTo@ lookup
-- function.
--
-- Since 0.2.0
data WaiProxyResponse = WPRResponse WAI.Response
                        -- ^ Respond with the given WAI Response.
                        --
                        -- Since 0.2.0
                      | WPRProxyDest ProxyDest
                        -- ^ Send to the given destination.
                        --
                        -- Since 0.2.0
                      | WPRModifiedRequest WAI.Request ProxyDest
                        -- ^ Send to the given destination, but use the given
                        -- modified Request for computing the reverse-proxied
                        -- request. This can be useful for reverse proxying to
                        -- a different path than the one specified. By the
                        -- user.
                        --
                        -- Since 0.2.0

-- | Creates a WAI 'WAI.Application' which will handle reverse proxies.
--
-- Connections to the proxied server will be provided via http-conduit. As
-- such, all requests and responses will be fully processed in your reverse
-- proxy. This allows you much more control over the data sent over the wire,
-- but also incurs overhead. For a lower-overhead approach, consider
-- 'rawProxyTo'.
--
-- Most likely, the given application should be run with Warp, though in theory
-- other WAI handlers will work as well.
--
-- Note: This function will use chunked request bodies for communicating with
-- the proxied server. Not all servers necessarily support chunked request
-- bodies, so please confirm that yours does (Warp, Snap, and Happstack, for example, do).
waiProxyTo :: (WAI.Request -> IO WaiProxyResponse)
           -- ^ How to reverse proxy. A @Left@ result will be sent verbatim as
           -- the response, whereas @Right@ will cause a reverse proxy.
           -> (SomeException -> WAI.Application)
           -- ^ How to handle exceptions when calling remote server. For a
           -- simple 502 error page, use 'defaultOnExc'.
           -> HC.Manager -- ^ connection manager to utilize
           -> WAI.Application
waiProxyTo getDest onError = waiProxyToSettings getDest def { wpsOnExc = onError }

data WaiProxySettings = WaiProxySettings
    { wpsOnExc :: SomeException -> WAI.Application
    , wpsTimeout :: Maybe Int
    , wpsSetIpHeader :: SetIpHeader
    -- ^ Set the X-Real-IP request header with the client's IP address.
    --
    -- Default: SIHFromSocket
    --
    -- Since 0.2.0
    , wpsProcessBody :: HC.Response () -> Maybe (Conduit ByteString IO (Flush Builder))
    -- ^ Post-process the response body returned from the host.
    --
    -- Since 0.2.1
    , wpsUpgradeToRaw :: WAI.Request -> Bool
    -- ^ Determine if the request should be upgraded to a raw proxy connection,
    -- as is needed for WebSockets. Requires WAI 2.1 or higher and a WAI
    -- handler with raw response support (e.g., Warp) to work.
    --
    -- Default: check if the upgrade header is websocket.
    --
    -- Since 0.3.1
    }

-- | How to set the X-Real-IP request header.
--
-- Since 0.2.0
data SetIpHeader = SIHNone -- ^ Do not set the header
                 | SIHFromSocket -- ^ Set it from the socket's address.
                 | SIHFromHeader -- ^ Set it from either X-Real-IP or X-Forwarded-For, if present

instance Default WaiProxySettings where
    def = WaiProxySettings
        { wpsOnExc = defaultOnExc
        , wpsTimeout = Nothing
        , wpsSetIpHeader = SIHFromSocket
        , wpsProcessBody = const Nothing
        , wpsUpgradeToRaw = \req ->
            (CI.mk <$> lookup "upgrade" (WAI.requestHeaders req)) == Just "websocket"
        }

#if MIN_VERSION_wai(2, 1, 0)
renderHeaders :: WAI.Request -> HT.RequestHeaders -> Builder
renderHeaders req headers
    = fromByteString (WAI.requestMethod req)
   <> fromByteString " "
   <> fromByteString (WAI.rawPathInfo req)
   <> fromByteString (WAI.rawQueryString req)
   <> (if WAI.httpVersion req == HT.http11
           then fromByteString " HTTP/1.1"
           else fromByteString " HTTP/1.0")
   <> mconcat (map goHeader headers)
   <> fromByteString "\r\n\r\n"
  where
    goHeader (x, y)
        = fromByteString "\r\n"
       <> fromByteString (CI.original x)
       <> fromByteString ": "
       <> fromByteString y
#endif

#if MIN_VERSION_wai(3, 0, 0)
tryWebSockets :: WaiProxySettings -> ByteString -> Int -> WAI.Request -> (WAI.Response -> IO b) -> IO b -> IO b
tryWebSockets wps host port req sendResponse fallback
    | wpsUpgradeToRaw wps req =
        sendResponse $ flip WAI.responseRaw backup $ \fromClientBody toClient ->
            DCN.runTCPClient settings $ \server ->
                let toServer = DCN.appSink server
                    fromServer = DCN.appSource server
                    fromClient = do
                        mapM_ yield $ L.toChunks $ toLazyByteString headers
                        let loop = do
                                bs <- liftIO fromClientBody
                                unless (S.null bs) $ do
                                    yield bs
                                    loop
                        loop
                    toClient' = awaitForever $ liftIO . toClient
                    headers = renderHeaders req $ fixReqHeaders wps req
                 in void $ concurrently
                        (fromClient $$ toServer)
                        (fromServer $$ toClient')
    | otherwise = fallback
  where
    backup = WAI.responseLBS HT.status500 [("Content-Type", "text/plain")]
        "http-reverse-proxy detected WebSockets request, but server does not support responseRaw"
    settings = DCN.clientSettings port host

#else

tryWebSockets :: WaiProxySettings -> ByteString -> Int -> WAI.Request -> IO WAI.Response -> IO WAI.Response
#if MIN_VERSION_wai(2, 1, 0)
tryWebSockets wps host port req fallback
    | wpsUpgradeToRaw wps req =
        return $ flip WAI.responseRaw backup $ \fromClientBody toClient ->
            DCN.runTCPClient settings $ \server ->
                let toServer = DCN.appSink server
                    fromServer = DCN.appSource server
                    fromClient = do
                        mapM_ yield $ L.toChunks $ toLazyByteString headers
                        fromClientBody
                    headers = renderHeaders req $ fixReqHeaders wps req
                 in void $ concurrently
                        (fromClient $$ toServer)
                        (fromServer $$ toClient)
    | otherwise = fallback
  where
    backup = WAI.responseLBS HT.status500 [("Content-Type", "text/plain")]
        "http-reverse-proxy detected WebSockets request, but server does not support responseRaw"
    settings = DCN.clientSettings port host
#else
tryWebSockets _ _ _ _ = id
#endif

#endif

strippedHeaders :: Set HT.HeaderName
strippedHeaders = Set.fromList
    ["content-length", "transfer-encoding", "accept-encoding", "content-encoding"]

fixReqHeaders :: WaiProxySettings -> WAI.Request -> HT.RequestHeaders
fixReqHeaders wps req =
    addXRealIP $ filter (\(key, value) -> not $ key `Set.member` strippedHeaders
                                       || (key == "connection" && value == "close"))
               $ WAI.requestHeaders req
  where
    addXRealIP =
        case wpsSetIpHeader wps of
            SIHFromSocket -> (("X-Real-IP", S8.pack $ showSockAddr $ WAI.remoteHost req):)
            SIHFromHeader ->
                case lookup "x-real-ip" (WAI.requestHeaders req) <|> lookup "X-Forwarded-For" (WAI.requestHeaders req) of
                    Nothing -> id
                    Just ip -> (("X-Real-IP", ip):)
            SIHNone -> id

waiProxyToSettings :: (WAI.Request -> IO WaiProxyResponse)
                   -> WaiProxySettings
                   -> HC.Manager
                   -> WAI.Application
#if MIN_VERSION_wai(3,0,0)
waiProxyToSettings getDest wps manager req0 sendResponse = do
    edest' <- getDest req0
    let edest =
            case edest' of
                WPRResponse res -> Left res
                WPRProxyDest pd -> Right (pd, req0)
                WPRModifiedRequest req pd -> Right (pd, req)
    case edest of
        Left response -> sendResponse response
        Right (ProxyDest host port, req) -> tryWebSockets wps host port req sendResponse $ do
            let req' = def
                    { HC.method = WAI.requestMethod req
                    , HC.host = host
                    , HC.port = port
                    , HC.path = WAI.rawPathInfo req
                    , HC.queryString = WAI.rawQueryString req
                    , HC.requestHeaders = fixReqHeaders wps req
                    , HC.requestBody = body
                    , HC.redirectCount = 0
                    , HC.checkStatus = \_ _ _ -> Nothing
                    , HC.responseTimeout = wpsTimeout wps
                    }
                body =
                    case WAI.requestBodyLength req of
                        WAI.KnownLength i -> HC.RequestBodyStream
                            (fromIntegral i)
                            ($ WAI.requestBody req)
                        WAI.ChunkedBody -> HC.RequestBodyStreamChunked ($ WAI.requestBody req)
            bracket
                (try $ HC.responseOpen req' manager)
                (either (const $ return ()) HC.responseClose)
                $ \ex -> do
                case ex of
                    Left e -> wpsOnExc wps e req sendResponse
                    Right res -> do
                        let conduit =
                                case wpsProcessBody wps $ fmap (const ()) res of
                                    Nothing -> awaitForever (\bs -> yield (Chunk $ fromByteString bs) >> yield Flush)
                                    Just conduit' -> conduit'
                            src = bodyReaderSource $ HC.responseBody res
                        sendResponse $ WAI.responseStream
                            (HC.responseStatus res)
                            (filter (\(key, _) -> not $ key `Set.member` strippedHeaders) $ HC.responseHeaders res)
                            (\sendChunk flush -> src $= conduit $$ CL.mapM_ (\mb ->
                                case mb of
                                    Flush -> flush
                                    Chunk b -> sendChunk b))
#else
waiProxyToSettings getDest wps manager req0 = do
    edest' <- getDest req0
    let edest =
            case edest' of
                WPRResponse res -> Left res
                WPRProxyDest pd -> Right (pd, req0)
                WPRModifiedRequest req pd -> Right (pd, req)
    case edest of
        Left response -> return response
        Right (ProxyDest host port, req) -> tryWebSockets wps host port req $ do
            let req' = def
                    { HC.method = WAI.requestMethod req
                    , HC.host = host
                    , HC.port = port
                    , HC.path = WAI.rawPathInfo req
                    , HC.queryString = WAI.rawQueryString req
                    , HC.requestHeaders = fixReqHeaders wps req
                    , HC.requestBody = body
                    , HC.redirectCount = 0
                    , HC.checkStatus = \_ _ _ -> Nothing
                    , HC.responseTimeout = wpsTimeout wps
                    }
                bodyChunked = requestBodySourceChunked $ WAI.requestBody req
                body =
                    case WAI.requestBodyLength req of
                        WAI.KnownLength i -> requestBodySource
                            (fromIntegral i)
                            (WAI.requestBody req)
                        WAI.ChunkedBody -> bodyChunked
            bracketOnError
                (try $ HC.responseOpen req' manager)
                (either (const $ return ()) HC.responseClose)
                $ \ex -> do
                case ex of
                    Left e -> wpsOnExc wps e req
                    Right res -> do
                        let conduit =
                                case wpsProcessBody wps $ fmap (const ()) res of
                                    Nothing -> awaitForever (\bs -> yield (Chunk $ fromByteString bs) >> yield Flush)
                                    Just conduit' -> conduit'
                        WAI.responseSourceBracket
                            (return ())
                            (\() -> HC.responseClose res)
                            $ \() -> do
                                let src = bodyReaderSource $ HC.responseBody res
                                return
                                    ( HC.responseStatus res
                                    , filter (\(key, _) -> not $ key `Set.member` strippedHeaders) $ HC.responseHeaders res
                                    , src $= conduit
                                    )
#endif

-- | Get the HTTP headers for the first request on the stream, returning on
-- consumed bytes as leftovers. Has built-in limits on how many bytes it will
-- consume (specifically, will not ask for another chunked after it receives
-- 1000 bytes).
getHeaders :: Monad m => Sink ByteString m HT.RequestHeaders
getHeaders =
    toHeaders <$> go id
  where
    go front =
        await >>= maybe close push
      where
        close = leftover bs >> return bs
          where
            bs = front S8.empty
        push bs'
            | "\r\n\r\n" `S8.isInfixOf` bs
              || "\n\n" `S8.isInfixOf` bs
              || S8.length bs > 4096 = leftover bs >> return bs
            | otherwise = go $ mappend bs
          where
            bs = front bs'
    toHeaders = map toHeader . takeWhile (not . S8.null) . drop 1 . S8.lines
    toHeader bs =
        (CI.mk key, val)
      where
        (key, bs') = S.break (== _colon) bs
        val = S.takeWhile (/= _cr) $ S.dropWhile isSpace $ S.drop 1 bs'

{- FIXME
-- | Convert a WAI application into a raw application, using Warp.
waiToRaw :: WAI.Application -> DCN.Application IO
waiToRaw app appdata0 =
    loop fromClient0
  where
    fromClient0 = DCN.appSource appdata0
    toClient = DCN.appSink appdata0
    loop fromClient = do
        mfromClient <- runResourceT $ withInternalState $ \internalState -> do
            ex <- try $ parseRequest conn internalState dummyAddr fromClient
            case ex of
                Left (_ :: SomeException) -> return Nothing
                Right (req, fromClient') -> do
                    res <- app req
                    keepAlive <- sendResponse
                        defaultSettings
                        req conn res
                    (fromClient'', _) <- liftIO fromClient' >>= unwrapResumable
                    return $ if keepAlive then Just fromClient'' else Nothing
        maybe (return ()) loop mfromClient

    dummyAddr = SockAddrInet (PortNum 0) 0 -- FIXME
    conn = Connection
        { connSendMany = \bss -> mapM_ yield bss $$ toClient
        , connSendAll = \bs -> yield bs $$ toClient
        , connSendFile = \fp offset len _th headers _cleaner ->
            let src1 = mapM_ yield headers
                src2 = sourceFileRange fp (Just offset) (Just len)
             in runResourceT
                $  (src1 >> src2)
                $$ transPipe lift toClient
        , connClose = return ()
        , connRecv = error "connRecv should not be used"
        }
        -}

requestBodySource :: Int64 -> Source IO ByteString -> HC.RequestBody
requestBodySource size = HC.RequestBodyStream size . srcToPopper

requestBodySourceChunked :: Source IO ByteString -> HC.RequestBody
requestBodySourceChunked = HC.RequestBodyStreamChunked . srcToPopper

srcToPopper :: Source IO ByteString -> HC.GivesPopper ()
srcToPopper src f = do
    (rsrc0, ()) <- src $$+ return ()
    irsrc <- newIORef rsrc0
    let popper :: IO ByteString
        popper = do
            rsrc <- readIORef irsrc
            (rsrc', mres) <- rsrc $$++ await
            writeIORef irsrc rsrc'
            case mres of
                Nothing -> return S.empty
                Just bs
                    | S.null bs -> popper
                    | otherwise -> return bs
    f popper

bodyReaderSource :: MonadIO m => BodyReader -> Source m ByteString
bodyReaderSource br =
    loop
  where
    loop = do
        bs <- liftIO $ brRead br
        unless (S.null bs) $ do
            yield bs
            loop
