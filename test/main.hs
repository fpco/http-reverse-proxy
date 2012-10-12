{-# LANGUAGE OverloadedStrings #-}
import           Control.Concurrent         (forkIO, threadDelay)
import qualified Data.ByteString.Lazy.Char8 as L8
import           Data.Conduit.Network       (serverSettings, runTCPServer)
import qualified Network.HTTP.Conduit       as HC
import           Network.HTTP.ReverseProxy  (ProxyDest (..), defaultOnExc,
                                             rawProxyTo, waiProxyTo, waiToRaw)
import           Network.HTTP.Types         (status200)
import           Network.Wai                (responseLBS, Response (ResponseFile))
import           Network.Wai.Handler.Warp   (run)
import           Test.Hspec                 (describe, hspec, it, shouldBe)

main :: IO ()
main = hspec $ do
    describe "http-reverse-proxy" $ do
        it "works" $ do
            let content = "mainApp"
            manager <- HC.newManager HC.def
            forkIO $ run 5000 $ const $ return $ responseLBS status200 [] content
            forkIO $ run 5001 $ waiProxyTo (const $ return $ Right $ ProxyDest "localhost" 5000) defaultOnExc manager
            forkIO $ runTCPServer (serverSettings 5002 "*") (rawProxyTo (const $ return $ Right $ ProxyDest "localhost" 5001))
            threadDelay 100000
            lbs <- HC.simpleHttp "http://localhost:5002"
            lbs `shouldBe` content
    describe "waiToRaw" $ do
        it "works" $ do
            let content = "waiToRaw"
            manager <- HC.newManager HC.def
            let waiApp = const $ return $ responseLBS status200 [] content
                rawApp = waiToRaw waiApp
            forkIO $ runTCPServer (serverSettings 6000 "*") (rawProxyTo (const $ return $ Left rawApp))
            threadDelay 100000
            lbs <- HC.simpleHttp "http://localhost:6000"
            lbs `shouldBe` content
        it "sends files" $ do
            let content = "PONG"
                fp = "pong"
            writeFile fp content
            manager <- HC.newManager HC.def
            let waiApp = const $ return $ ResponseFile status200 [] fp Nothing
                rawApp = waiToRaw waiApp
            forkIO $ runTCPServer (serverSettings 6001 "*") (rawProxyTo (const $ return $ Left rawApp))
            threadDelay 100000
            lbs <- HC.simpleHttp "http://localhost:6001"
            lbs `shouldBe` L8.pack content
