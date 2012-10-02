{-# LANGUAGE OverloadedStrings #-}
import           Control.Concurrent        (forkIO, threadDelay)
import           Data.Conduit.Network      (ServerSettings (ServerSettings), runTCPServer)
import qualified Network.HTTP.Conduit      as HC
import           Network.HTTP.ReverseProxy (ProxyDest (..), defaultOnExc,
                                            rawProxyTo, waiProxyTo)
import           Network.HTTP.Types        (status200)
import           Network.Wai               (responseLBS)
import           Network.Wai.Handler.Warp  (run)
import           Test.Hspec                (describe, hspec, it, shouldBe)

main :: IO ()
main = hspec $ do
    describe "http-reverse-proxy" $ do
        it "works" $ do
            let content = "mainApp"
            manager <- HC.newManager HC.def
            forkIO $ run 5000 $ const $ return $ responseLBS status200 [] content
            forkIO $ run 5001 $ waiProxyTo (const $ return $ Right $ ProxyDest "localhost" 5000) defaultOnExc manager
            forkIO $ runTCPServer (ServerSettings 5002 "*") (rawProxyTo (const $ return $ Right $ ProxyDest "localhost" 5001))
            threadDelay 100000
            lbs <- HC.simpleHttp "http://localhost:5002"
            lbs `shouldBe` content
