## 1.0.0

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
