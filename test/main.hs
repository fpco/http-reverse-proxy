{-# LANGUAGE OverloadedStrings #-}
import           Control.Concurrent         (forkIO, threadDelay)
import qualified Data.ByteString.Lazy.Char8 as L8
import           Data.Conduit               (yield, Flush (..), ($$+-), await, runResourceT)
import           Data.Conduit.Network       (serverSettings, runTCPServer)
import qualified Network.HTTP.Conduit       as HC
import           Network.HTTP.ReverseProxy  (ProxyDest (..), defaultOnExc,
                                             rawProxyTo, waiProxyTo, waiToRaw)
import           Network.HTTP.Types         (status200)
import           Network.Wai                (responseLBS, Response (ResponseFile, ResponseSource))
import           Network.Wai.Handler.Warp   (run)
import           Test.Hspec                 (describe, hspec, it, shouldBe)
import           Blaze.ByteString.Builder   (fromByteString)
import           Control.Monad              (forever)
import           Control.Monad.IO.Class     (liftIO)
import           System.Timeout.Lifted      (timeout)

main :: IO ()
main = hspec $ do
    describe "http-reverse-proxy" $ do
        it "works" $ do
            let content = "mainApp"
            manager <- HC.newManager HC.def
            forkIO $ run 15000 $ const $ return $ responseLBS status200 [] content
            forkIO $ run 15001 $ waiProxyTo (const $ return $ Right $ ProxyDest "localhost" 15000) defaultOnExc manager
            forkIO $ runTCPServer (serverSettings 15002 "*") (rawProxyTo (const $ return $ Right $ ProxyDest "localhost" 15001))
            threadDelay 100000
            lbs <- HC.simpleHttp "http://localhost:15002"
            lbs `shouldBe` content
        it "deals with streaming data" $ do
            manager <- HC.newManager HC.def
            forkIO $ run 15003 $ const $ return $ ResponseSource status200 [] $ forever $ do
                yield $ Chunk $ fromByteString "hello"
                yield Flush
                liftIO $ threadDelay 10000000
            forkIO $ run 15004 $ waiProxyTo (const $ return $ Right $ ProxyDest "localhost" 15003) defaultOnExc manager
            threadDelay 100000
            req <- HC.parseUrl "http://localhost:15004"
            mbs <- runResourceT $ timeout 1000000 $ do
                res <- HC.http req manager
                HC.responseBody res $$+- await
            mbs `shouldBe` Just (Just "hello")
    describe "waiToRaw" $ do
        it "works" $ do
            let content = "waiToRaw"
            manager <- HC.newManager HC.def
            let waiApp = const $ return $ responseLBS status200 [] content
                rawApp = waiToRaw waiApp
            forkIO $ runTCPServer (serverSettings 16000 "*") (rawProxyTo (const $ return $ Left rawApp))
            threadDelay 100000
            lbs <- HC.simpleHttp "http://localhost:16000"
            lbs `shouldBe` content
        it "sends files" $ do
            let content = "PONG"
                fp = "pong"
            writeFile fp content
            manager <- HC.newManager HC.def
            let waiApp = const $ return $ ResponseFile status200 [] fp Nothing
                rawApp = waiToRaw waiApp
            forkIO $ runTCPServer (serverSettings 16001 "*") (rawProxyTo (const $ return $ Left rawApp))
            threadDelay 100000
            lbs <- HC.simpleHttp "http://localhost:16001"
            lbs `shouldBe` L8.pack content
