{-# LANGUAGE CPP                 #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
import           Blaze.ByteString.Builder   (fromByteString)
import           Control.Concurrent         (forkIO, killThread, newEmptyMVar,
                                             putMVar, takeMVar, threadDelay)
import           Control.Exception          (IOException, bracket, onException,
                                             try)
import           Control.Monad              (forever)
import           Control.Monad.IO.Class     (liftIO)
import qualified Data.ByteString            as S
import qualified Data.ByteString.Char8      as S8
import qualified Data.ByteString.Lazy.Char8 as L8
import           Data.Conduit               (Flush (..), await, runResourceT,
                                             yield, ($$+-))
import           Data.Conduit.Network       (HostPreference (HostIPv4, HostAny),
                                             ServerSettings, bindPort,
                                             runTCPServer, serverAfterBind,
                                             serverSettings)
import qualified Data.Conduit.Network
import qualified Data.IORef                 as I
import qualified Network.HTTP.Conduit       as HC
import           Network.HTTP.ReverseProxy  (ProxyDest (..), defaultOnExc,
                                             rawProxyTo, waiProxyTo, waiToRaw)
import           Network.HTTP.Types         (status200)
import           Network.Socket             (sClose)
import           Network.Wai                (Response (ResponseFile, ResponseSource),
                                             responseLBS)
import qualified Network.Wai
import           Network.Wai.Handler.Warp   (defaultSettings, run, runSettings,
                                             settingsBeforeMainLoop,
                                             settingsPort)
import           System.IO.Unsafe           (unsafePerformIO)
import           System.Timeout.Lifted      (timeout)
import           Test.Hspec                 (describe, hspec, it, shouldBe)

nextPort :: I.IORef Int
nextPort = unsafePerformIO $ I.newIORef 15452

getPort :: IO Int
getPort = do
    port <- I.atomicModifyIORef nextPort $ \p -> (p + 1, p)
    esocket <- try $ bindPort port HostIPv4
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
        (forkIO $ runSettings defaultSettings
            { settingsPort = port
            , settingsBeforeMainLoop = putMVar baton ()
            } app `onException` putMVar baton ())
        killThread
        (const $ takeMVar baton >> f port)

withCApp :: Data.Conduit.Network.Application IO -> (Int -> IO ()) -> IO ()
withCApp app f = do
    port <- getPort
    baton <- newEmptyMVar
    let start = putMVar baton ()
        settings :: ServerSettings IO
        settings = (serverSettings port HostAny :: ServerSettings IO) { serverAfterBind = const start }
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
                withWApp (const $ return $ responseLBS status200 [] content) $ \port1 ->
                withWApp (waiProxyTo (const $ return $ Right $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 ->
                withCApp (rawProxyTo (const $ return $ Right $ ProxyDest "127.0.0.1" port2)) $ \port3 -> do
                    lbs <- HC.simpleHttp $ "http://127.0.0.1:" ++ show port3
                    lbs `shouldBe` content
        it "deals with streaming data" $
            let app _ = return $ ResponseSource status200 [] $ forever $ do
                    yield $ Chunk $ fromByteString "hello"
                    yield Flush
                    liftIO $ threadDelay 10000000
             in withMan $ \manager ->
                withWApp app $ \port1 ->
                withWApp (waiProxyTo (const $ return $ Right $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 -> do
                    req <- HC.parseUrl $ "http://127.0.0.1:" ++ show port2
                    mbs <- runResourceT $ timeout 1000000 $ do
                        res <- HC.http req manager
                        HC.responseBody res $$+- await
                    mbs `shouldBe` Just (Just "hello")
#if MIN_VERSION_wai(1, 4, 0)
        it "passes on body length" $
            let app req = return $ responseLBS
                    status200
                    [("uplength", show' $ Network.Wai.requestBodyLength req)]
                    ""
                body = "some body"
                show' Network.Wai.ChunkedBody = "chunked"
                show' (Network.Wai.KnownLength i) = S8.pack $ show i
             in withMan $ \manager ->
                withWApp app $ \port1 ->
                withWApp (waiProxyTo (const $ return $ Right $ ProxyDest "127.0.0.1" port1) defaultOnExc manager) $ \port2 -> do
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
#endif
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
                waiApp = const $ return $ ResponseFile status200 [] fp Nothing
                rawApp = waiToRaw waiApp
            writeFile fp content
            withCApp (rawProxyTo (const $ return $ Left rawApp)) $ \port -> do
                lbs <- HC.simpleHttp $ "http://127.0.0.1:" ++ show port
                lbs `shouldBe` L8.pack content
