{-# LANGUAGE OverloadedStrings, NoImplicitPrelude, FlexibleContexts, ScopedTypeVariables #-}
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
      -- ** Settings
    , WaiProxySettings
    , def
    , wpsOnExc
    , wpsTimeout
      -- * WAI to Raw
    , waiToRaw
    ) where

import ClassyPrelude
import Data.Conduit
import qualified Network.Wai as WAI
import qualified Network.HTTP.Conduit as HC
import Control.Exception.Lifted (try, finally)
import Blaze.ByteString.Builder (fromByteString, flush)
import Data.Word8 (isSpace, _colon, toLower, _cr)
import qualified Data.ByteString.Char8 as S8
import qualified Network.HTTP.Types as HT
import qualified Data.CaseInsensitive as CI
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.Conduit.Network as DCN
import Control.Concurrent.MVar.Lifted (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Lifted (fork, killThread)
import Control.Monad.Trans.Control (MonadBaseControl)
import Network.Wai.Handler.Warp
import Data.Conduit.Binary (sourceFileRange)
import qualified Data.IORef as I
import Network.Socket (PortNumber (PortNum), SockAddr (SockAddrInet))
import Data.Default (Default (def))
import Data.Version (showVersion)
import qualified Paths_http_reverse_proxy

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
rawProxyTo :: (MonadBaseControl IO m, MonadIO m)
           => (HT.RequestHeaders -> m (Either (DCN.Application m) ProxyDest))
           -- ^ How to reverse proxy. A @Left@ result will run the given
           -- 'DCN.Application', whereas a @Right@ will reverse proxy to the
           -- given host\/port.
           -> DCN.Application m
rawProxyTo getDest appdata = do
    (rsrc, headers) <- fromClient $$+ getHeaders
    edest <- getDest headers
    case edest of
        Left app -> do
            -- We know that the socket will be closed by the toClient side, so
            -- we can throw away the finalizer here.
            (fromClient', _) <- unwrapResumable rsrc
            app appdata { DCN.appSource = fromClient' }
        Right (ProxyDest host port) -> DCN.runTCPClient (DCN.clientSettings port host) (withServer rsrc)
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
defaultOnExc exc _ = return $ WAI.responseLBS
    HT.status502
    [("content-type", "text/plain")]
    ("Error connecting to gateway:\n\n" ++ TLE.encodeUtf8 (show exc))

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
waiProxyTo :: (WAI.Request -> ResourceT IO (Either WAI.Response ProxyDest))
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
    }

instance Default WaiProxySettings where
    def = WaiProxySettings
        { wpsOnExc = defaultOnExc
        , wpsTimeout = Nothing
        }

waiProxyToSettings getDest wps manager req = do
    edest <- getDest req
    case edest of
        Left response -> return response
        Right (ProxyDest host port) -> do
            let req' = HC.def
                    { HC.method = WAI.requestMethod req
                    , HC.host = host
                    , HC.port = port
                    , HC.path = WAI.rawPathInfo req
                    , HC.queryString = WAI.rawQueryString req
                    , HC.requestHeaders = filter (\(key, _) -> not $ key `member` strippedHeaders) $ WAI.requestHeaders req
                    , HC.requestBody = body
                    , HC.redirectCount = 0
#if MIN_VERSION_http_conduit(1, 9, 0)
                    , HC.checkStatus = \_ _ _ -> Nothing
#else
                    , HC.checkStatus = \_ _ -> Nothing
#endif
                    , HC.responseTimeout = wpsTimeout wps
                    }
                fbs bs = fromByteString bs <> flush
                bodySrc = mapOutput fbs $ WAI.requestBody req
                bodyChunked = HC.RequestBodySourceChunked bodySrc
#if MIN_VERSION_wai(1, 4, 0)
                body =
                    case WAI.requestBodyLength req of
                        WAI.KnownLength i -> HC.RequestBodySource
                            (fromIntegral i)
                            bodySrc
                        WAI.ChunkedBody -> bodyChunked
#else
                body = bodyChunked
#endif
            ex <- try $ HC.http req' manager
            case ex of
                Left e -> wpsOnExc wps e req
                Right res -> do
                    (src, _) <- unwrapResumable $ HC.responseBody res
                    return $ WAI.ResponseSource
                        (HC.responseStatus res)
                        (filter (\(key, _) -> not $ key `member` strippedHeaders) $ HC.responseHeaders res) $ do
                        yield Flush
                        src =$= awaitForever (\bs -> yield (Chunk $ fromByteString bs) >> yield Flush)
  where
    strippedHeaders = asSet $ fromList ["content-length", "transfer-encoding", "accept-encoding", "content-encoding"]
    asSet :: Set a -> Set a
    asSet = id

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
            bs = front empty
        push bs'
            | "\r\n\r\n" `S8.isInfixOf` bs
              || "\n\n" `S8.isInfixOf` bs
              || length bs > 4096 = leftover bs >> return bs
            | otherwise = go $ append bs
          where
            bs = front bs'
    toHeaders = map toHeader . takeWhile (not . null) . drop 1 . S8.lines
    toHeader bs =
        (CI.mk key, val)
      where
        (key, bs') = break (== _colon) bs
        val = takeWhile (/= _cr) $ dropWhile isSpace $ drop 1 bs'

-- | Convert a WAI application into a raw application, using Warp.
waiToRaw :: WAI.Application -> DCN.Application IO
waiToRaw app appdata0 =
    loop $ transPipe lift fromClient0
  where
    fromClient0 = DCN.appSource appdata0
    toClient = DCN.appSink appdata0
    loop fromClient = do
        mfromClient <- runResourceT $ do
            ex <- try $ parseRequest conn 0 dummyAddr fromClient
            case ex of
                Left (_ :: SomeException) -> return Nothing
                Right (req, fromClient') -> do
                    res <- app req
                    keepAlive <- sendResponse
#if MIN_VERSION_warp(1, 3, 8)
                        defaultSettings
                            { settingsServerName = S8.pack $ concat
                                [ "Warp/"
                                , warpVersion
                                , " + http-reverse-proxy/"
                                , showVersion Paths_http_reverse_proxy.version
                                ]
                            }
#endif
                        dummyCleaner req conn res
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
