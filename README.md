http-reverse-proxy
==================

Provides a simple means of reverse-proxying HTTP requests. The raw approach
uses the same technique as leveraged by keter, whereas the WAI approach
performs full request/response parsing via WAI and http-conduit.

## Raw example

The following sets up raw reverse proxying from local port 3000 to
www.example.com, port 80.

```haskell
{-# LANGUAGE OverloadedStrings #-}
import Network.HTTP.ReverseProxy
import Data.Conduit.Network

main :: IO ()
main = runTCPServer (serverSettings 3000 "*") $ \appData ->
    rawProxyTo
        (\_headers -> return $ Right $ ProxyDest "www.example.com" 80)
        appData
```

## HTTPS example to proxy bing.com

The following example sets up reverse proxying froming to www.bing.com
from localhost port 3000:

``` haskell
import Network.HTTP.Client.TLS
import Network.HTTP.ReverseProxy
import Network.Wai
import Network.Wai.Handler.Warp (run)

main :: IO ()
main = bingExample >>= run 3000

bingExample :: IO Application
bingExample = do
  manager <- newTlsManager
  pure $
    waiProxyToSettings
      ( \request ->
          return $
            WPRModifiedRequestSecure
              ( request
                  { requestHeaders = [("Host", "www.bing.com")]
                  }
              )
              (ProxyDest "www.bing.com" 443)
      )
      defaultWaiProxySettings {wpsLogRequest = print}
      manager
```

After running it, you can visit [http://localhost:3000](http://localhost:3000) to visit
the search engine's page.
