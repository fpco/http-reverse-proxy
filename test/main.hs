{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
import           Blaze.ByteString.Builder     (fromByteString)
import           Control.Concurrent           (forkIO, killThread, newEmptyMVar,
                                               putMVar, takeMVar, threadDelay)
import           Control.Exception            (IOException, bracket,
                                               onException, try)
import           Control.Monad                (forever, unless)
import           Control.Monad.IO.Class       (liftIO)
import           Control.Monad.Trans.Resource (runResourceT)
import           Data.Maybe                   (fromMaybe)
import qualified Data.ByteString              as S
import qualified Data.ByteString.Char8        as S8
import qualified Data.ByteString.Lazy.Char8   as L8
import           Data.Char                    (toUpper)
import           Data.Conduit                 (await, yield, ($$),
                                               ($$+-), (=$), awaitForever)
import qualified Data.Conduit.Binary          as CB
import qualified Data.Conduit.List            as CL
import           Data.Conduit.Network         (ServerSettings,
                                               appSink, appSource,
                                               clientSettings, runTCPClient,
                                               runTCPServer, serverSettings)
import qualified Data.IORef                   as I
import           Data.Streaming.Network       (AppData,
                                               bindPortTCP, setAfterBind)
import qualified Network.HTTP.Conduit         as HC
import           Network.HTTP.ReverseProxy    (ProxyDest (..),
                                               WaiProxyResponse (..),
                                               defaultOnExc, rawProxyTo,
                                               WaiProxySettings (..),
                                               SetIpHeader (..),
                                               def,
                                               waiProxyToSettings,
                                               waiProxyTo)
import           Network.HTTP.Types           (status200, status500)
import           Network.Socket               (sClose)
import           Network.Wai                  (rawPathInfo, responseLBS,
                                               responseStream, requestHeaders)
import qualified Network.Wai
import           Network.Wai.Handler.Warp     (defaultSettings, runSettings,
                                               setBeforeMainLoop, setPort)
import           System.IO.Unsafe             (unsafePerformIO)
import           System.Timeout.Lifted        (timeout)
import           Test.Hspec                   (describe, hspec, it, shouldBe)

nextPort :: I.IORef Int
nextPort = unsafePerformIO $ I.newIORef 15452
{-# NOINLINE nextPort #-}

getPort :: IO Int
getPort = do
    port <- I.atomicModifyIORef nextPort $ \p -> (p + 1, p)
    esocket <- try $ bindPortTCP port "127.0.0.1"
    case esocket of
        Left (_ :: IOException) -> getPort
        Right socket -> do
            sClose socket
            return port

withWApp :: Network.Wai.Application -> (Int -> IO ()) -> IO ()
withWApp app f = do
    port <- getPort
    baton <- newEmptyMVar
    bracket
        (forkIO $ runSettings (settings port baton)
            app `onException` putMVar baton ())
        killThread
        (const $ takeMVar baton >> f port)
  where
    settings port baton
        = setPort port
        $ setBeforeMainLoop (putMVar baton ())
          defaultSettings

withCApp :: (AppData -> IO ()) -> (Int -> IO ()) -> IO ()
withCApp app f = do
    port <- getPort
    baton <- newEmptyMVar
    let start = putMVar baton ()
        settings = setAfterBind (const start) (serverSettings port "*" :: ServerSettings)
    bracket
        (forkIO $ runTCPServer settings app `onException` start)
        killThread
        (const $ takeMVar baton >> f port)

withMan :: (HC.Manager -> IO ()) -> IO ()
withMan = HC.withManager . (liftIO .)

main :: IO ()
main = hspec $ do
    describe "http-reverse-proxy" $ do
        it "works" $
            let content = "mainApp"
             in withMan $ \manager ->
                withWApp (\_ f -> f $ responseLBS status200 [] content) $ \port1 ->
                withWApp (waiProxyTo (const $ return $ WPRProxyDest $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 ->
                withCApp (rawProxyTo (const $ return $ Right $ ProxyDest "127.0.0.1" port2)) $ \port3 -> do
                    lbs <- HC.simpleHttp $ "http://127.0.0.1:" ++ show port3
                    lbs `shouldBe` content
        it "modified path" $
            let content = "/somepath"
                app req f = f $ responseLBS status200 [] $ L8.fromChunks [rawPathInfo req]
                modReq pdest req = return $ WPRModifiedRequest
                    (req { rawPathInfo = content })
                    pdest
             in withMan $ \manager ->
                withWApp app $ \port1 ->
                withWApp (waiProxyTo (modReq $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 ->
                withCApp (rawProxyTo (const $ return $ Right $ ProxyDest "127.0.0.1" port2)) $ \port3 -> do
                    lbs <- HC.simpleHttp $ "http://127.0.0.1:" ++ show port3
                    S8.concat (L8.toChunks lbs) `shouldBe` content
        it "deals with streaming data" $
            let app _ f = f $ responseStream status200 [] $ \sendChunk flush -> forever $ do
                    sendChunk $ fromByteString "hello"
                    flush
                    liftIO $ threadDelay 10000000
             in withMan $ \manager ->
                withWApp app $ \port1 ->
                withWApp (waiProxyTo (const $ return $ WPRProxyDest $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 -> do
                    req <- HC.parseUrl $ "http://127.0.0.1:" ++ show port2
                    mbs <- runResourceT $ timeout 1000000 $ do
                        res <- HC.http req manager
                        HC.responseBody res $$+- await
                    mbs `shouldBe` Just (Just "hello")
        it "passes on body length" $
            let app req f = f $ responseLBS
                    status200
                    [("uplength", show' $ Network.Wai.requestBodyLength req)]
                    ""
                body = "some body"
                show' Network.Wai.ChunkedBody = "chunked"
                show' (Network.Wai.KnownLength i) = S8.pack $ show i
             in withMan $ \manager ->
                withWApp app $ \port1 ->
                withWApp (waiProxyTo (const $ return $ WPRProxyDest $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 -> do
                    req' <- HC.parseUrl $ "http://127.0.0.1:" ++ show port2
                    let req = req'
                            { HC.requestBody = HC.RequestBodyBS body
                            }
                    mlen <- runResourceT $ do
                        res <- HC.http req manager
                        return $ lookup "uplength" $ HC.responseHeaders res
                    mlen `shouldBe` Just (show'
                                            $ Network.Wai.KnownLength
                                            $ fromIntegral
                                            $ S.length body)
        it "upgrade to raw" $
            let app _ f = f $ flip Network.Wai.responseRaw fallback $ \src sink -> do
                    let src' = do
                            bs <- liftIO src
                            unless (S8.null bs) $ yield bs >> src'
                        sink' = awaitForever $ liftIO . sink
                    src' $$ CL.iterM print =$ CL.map (S8.map toUpper) =$ sink'
                fallback = responseLBS status500 [] "fallback used"
             in withMan $ \manager ->
                withWApp app $ \port1 ->
                withWApp (waiProxyTo (const $ return $ WPRProxyDest $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 ->
                    runTCPClient (clientSettings port2 "127.0.0.1") $ \ad -> do
                        yield "GET / HTTP/1.1\r\nUpgrade: websockET\r\n\r\n" $$ appSink ad
                        yield "hello" $$ appSink ad
                        (appSource ad $$ CB.take 5) >>= (`shouldBe` "HELLO")
        it "get real ip" $
            let getRealIp req = L8.fromStrict $ fromMaybe "" $ lookup "x-real-ip" (requestHeaders req)
                httpWithForwardedFor url = liftIO $ do
                  man <- HC.newManager HC.tlsManagerSettings
                  oreq <- liftIO $ HC.parseRequest url
                  let req = oreq { HC.requestHeaders = [("X-Forwarded-For", "127.0.1.1, 127.0.0.1"), ("Connection", "close")] }
                  HC.responseBody <$> HC.httpLbs req man
                waiProxyTo' getDest onError = waiProxyToSettings getDest def { wpsOnExc = onError, wpsSetIpHeader = SIHFromHeader }
             in withMan $ \manager ->
                withWApp (\r f -> f $ responseLBS status200 [] $ getRealIp r ) $ \port1 ->
                withWApp (waiProxyTo' (const $ return $ WPRProxyDest $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 ->
                withCApp (rawProxyTo (const $ return $ Right $ ProxyDest "127.0.0.1" port2)) $ \port3 -> do
                    lbs <- httpWithForwardedFor $ "http://127.0.0.1:" ++ show port3
                    lbs `shouldBe` "127.0.1.1"
        it "get real ip 2" $
            let getRealIp req = L8.fromStrict $ fromMaybe "" $ lookup "x-real-ip" (requestHeaders req)
                httpWithForwardedFor url = liftIO $ do
                  man <- HC.newManager HC.tlsManagerSettings
                  oreq <- liftIO $ HC.parseRequest url
                  let req = oreq { HC.requestHeaders = [("X-Forwarded-For", "127.0.1.1"), ("Connection", "close")] }
                  HC.responseBody <$> HC.httpLbs req man
                waiProxyTo' getDest onError = waiProxyToSettings getDest def { wpsOnExc = onError, wpsSetIpHeader = SIHFromHeader }
             in withMan $ \manager ->
                withWApp (\r f -> f $ responseLBS status200 [] $ getRealIp r ) $ \port1 ->
                withWApp (waiProxyTo' (const $ return $ WPRProxyDest $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 ->
                withCApp (rawProxyTo (const $ return $ Right $ ProxyDest "127.0.0.1" port2)) $ \port3 -> do
                    lbs <- httpWithForwardedFor $ "http://127.0.0.1:" ++ show port3
                    lbs `shouldBe` "127.0.1.1"
        it "get real ip 3" $
            let getRealIp req = L8.fromStrict $ fromMaybe "" $ lookup "x-real-ip" (requestHeaders req)
                httpWithForwardedFor url = liftIO $ do
                  man <- HC.newManager HC.tlsManagerSettings
                  oreq <- liftIO $ HC.parseRequest url
                  let req = oreq { HC.requestHeaders = [("Connection", "close")] }
                  HC.responseBody <$> HC.httpLbs req man
                waiProxyTo' getDest onError = waiProxyToSettings getDest def { wpsOnExc = onError, wpsSetIpHeader = SIHFromHeader }
             in withMan $ \manager ->
                withWApp (\r f -> f $ responseLBS status200 [] $ getRealIp r ) $ \port1 ->
                withWApp (waiProxyTo' (const $ return $ WPRProxyDest $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 ->
                withCApp (rawProxyTo (const $ return $ Right $ ProxyDest "127.0.0.1" port2)) $ \port3 -> do
                    lbs <- httpWithForwardedFor $ "http://127.0.0.1:" ++ show port3
                    lbs `shouldBe` "127.0.0.1"
    {- FIXME
    describe "waiToRaw" $ do
        it "works" $ do
            let content = "waiToRaw"
                waiApp = const $ return $ responseLBS status200 [] content
                rawApp = waiToRaw waiApp
            withCApp (rawProxyTo (const $ return $ Left rawApp)) $ \port -> do
                lbs <- HC.simpleHttp $ "http://127.0.0.1:" ++ show port
                lbs `shouldBe` content
        it "sends files" $ do
            let content = "PONG"
                fp = "pong"
                waiApp = const $ return $ responseFile status200 [] fp Nothing
                rawApp = waiToRaw waiApp
            writeFile fp content
            withCApp (rawProxyTo (const $ return $ Left rawApp)) $ \port -> do
                lbs <- HC.simpleHttp $ "http://127.0.0.1:" ++ show port
                lbs `shouldBe` L8.pack content
    -}
