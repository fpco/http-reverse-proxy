
## 0.7.0.0

* Support HTTP 103 Early Hints responses in `waiProxyTo`.
  * This requires `http-client >= 0.7.16`.
  * It also necessitates a change in the `wpsOnExc` handler. Now it is passed a raw callback for writing bytes to the client, rather than a `WAI.Application`. You can see an example of how to use this in the new `defaultOnExc`.

## 0.6.0.2

* Fix docker registry reverse proxying by preserving the 'Content-Length' response header to HTTP/2 and HEAD requests. [#45](https://github.com/fpco/http-reverse-proxy/pull/45)

## 0.6.0.1

* Introduce a "semi cached body" to let the beginning of a request body be retried [#34](https://github.com/fpco/http-reverse-proxy/issues/34)
* Add `wpsLogRequest` function which provides the ability to log the
  constructed `Request`.

## 0.6.0

* Switch over to `unliftio` and conduit 1.3
* Drop dependency on `data-default-class`, drop `Default` instances

## 0.5.0.1

* Support http-conduit 2.3 in test suite [#26](https://github.com/fpco/http-reverse-proxy/issues/26)

## 0.5.0

* update `wpsProcessBody` to accept response's initial request

## 0.4.5

* add `Eq, Ord, Show, Read` instances to `ProxyDest`

## 0.4.4

* add `rawTcpProxyTo` which can handle proxying connections without http headers
  [#21](https://github.com/fpco/http-reverse-proxy/issues/21)

## 0.4.3.3

* `fixReqHeaders` may create weird `x-real-ip` header [#19](https://github.com/fpco/http-reverse-proxy/issues/19)

## 0.4.3.2

* Minor doc cleanup

## 0.4.3.1

* Use CPP so we can work with `http-client` pre and post 0.5 [#17](https://github.com/fpco/http-reverse-proxy/pull/17)

## 0.4.3

* Allow proxying to HTTPS servers. [#15](https://github.com/fpco/http-reverse-proxy/pull/15)

## 0.4.2

*  Add configurable timeouts [#8](https://github.com/fpco/http-reverse-proxy/pull/8)

## 0.4.1.3

* Include README.md and ChangeLog.md
