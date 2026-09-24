# Client IP and proxies

Choose the right client IP strategy for your hosting, and understand what happens if you do not.

## Overview

SwiftlyBotKit uses the client's IP address for three things:

- **IP verification.** A claimed agent is only verified if its address is inside the operator's published ranges.
- **The stored IP hash**, a keyed hash that lets the dashboard count distinct visitors without storing addresses.
- **The sign-in throttle**, which counts failed dashboard sign-ins per client.

All three are only as honest as the address they are given. ``BotKitConfiguration/clientIP`` decides where it comes from.

### Why the last X-Forwarded-For entry

`X-Forwarded-For` is a comma-separated list. Each proxy a request passes through appends the address it received the request from. The client can send the header too, with anything in it:

```
X-Forwarded-For: 20.171.207.1, 203.0.113.9
                 ^ sent by the client   ^ appended by your proxy
```

The leftmost entry is whatever the client chose to write. Reading it would let anyone who sends `X-Forwarded-For: <an OpenAI address>` with `-A ChatGPT-User` earn a verified badge, and would let an attacker rotate the header to reset the sign-in throttle on every attempt.

The entry your own proxy appended is the only one you can trust, and with one proxy that is the last one. So the default is ``ClientIPStrategy/lastForwardedFor``.

### The strategies

- ``ClientIPStrategy/lastForwardedFor``: The last `X-Forwarded-For` entry, or the socket's remote address when the header is absent. Right for exactly one trusted proxy or load balancer that appends to the header: most PaaS routers, a single nginx, a single cloud load balancer. The default.

- ``ClientIPStrategy/forwardedFor(trustedProxies:)``: The entry `trustedProxies` positions from the right, for a chain of that many appending proxies. A CDN in front of a load balancer is two. `1` is the same as `lastForwardedFor`. When the header has fewer entries than that, its first entry is used; when it is absent, or `trustedProxies` is below 1, the socket's remote address is used.

- ``ClientIPStrategy/remoteAddress``: The socket's remote address only, ignoring `X-Forwarded-For`. Right when the app faces the internet directly with no proxy in front.

- ``ClientIPStrategy/custom(_:)``: Your own extraction, for a proxy that puts the client address in another header such as `CF-Connecting-IP` or `Fly-Client-IP`. Return `nil` when the address is unknown.

Several `X-Forwarded-For` headers on one request are treated as one list, in order.

### Matching the strategy to your hosting

| Hosting | Strategy |
|---|---|
| A PaaS router (Heroku, Render and similar) | ``ClientIPStrategy/lastForwardedFor`` |
| One nginx or HAProxy in front of the app | ``ClientIPStrategy/lastForwardedFor`` |
| A CDN in front of a PaaS router or load balancer | ``ClientIPStrategy/forwardedFor(trustedProxies:)`` with `2` |
| No proxy at all | ``ClientIPStrategy/remoteAddress`` |
| A proxy that sets its own client-IP header, with the origin locked to it | ``ClientIPStrategy/custom(_:)`` |

```swift
// A CDN in front of a load balancer.
config.clientIP = .forwardedFor(trustedProxies: 2)

// The app is exposed directly.
config.clientIP = .remoteAddress

// Behind Cloudflare, with the origin reachable only through Cloudflare.
config.clientIP = .custom { req in
    req.headers.first(name: "CF-Connecting-IP")
}
```

### Security consequences of getting it wrong

**Too few proxies counted.** If there are two proxies and you use `lastForwardedFor`, every request appears to come from the first proxy. Verified agents turn into spoofed ones, all visitors share one IP hash, and one bad sign-in attempt from anyone counts against everyone.

**Too many proxies counted, or a direct app reading the header.** If the app faces the internet but uses `lastForwardedFor`, a client that sends its own `X-Forwarded-For` controls the address you read. The same happens with `forwardedFor(trustedProxies: 2)` behind only one proxy. A spoofer can then pick an operator's address and be marked verified, and can bypass the sign-in throttle by changing the header on each attempt.

**A trusted header that anyone can send.** `CF-Connecting-IP` and similar headers are only meaningful if every request really passed through that proxy. If the origin is also reachable directly, for example on its platform hostname, a client can go around the CDN and set the header to anything. The same applies to a `trustedProxies` count that assumes the CDN is always there. Restrict the origin to the CDN's addresses, or use authenticated origin pulls, before trusting what it adds.

When in doubt, log `req.headers[.xForwardedFor]` and `req.remoteAddress` for a request you make yourself, and count the entries your own infrastructure added.
