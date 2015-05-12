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
