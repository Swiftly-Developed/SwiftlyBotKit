# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's security advisories for this
repository:

https://github.com/Swiftly-Developed/SwiftlyBotKit/security/advisories/new

Do not open a public issue for a security problem. Include the version or
commit, your `BotKitConfiguration` (with secrets removed), how the app is
deployed (which proxies sit in front of it), and steps to reproduce.

You should get a first response within a week. Once a fix is released, the
advisory is published and you are credited unless you prefer not to be.

## Supported versions

Security fixes go into the latest release only. Before 1.0.0, that is the
latest `0.x` minor version.

## Scope

In scope:

- **Dashboard authentication bypass.** Reaching dashboard data without valid
  credentials, forging or replaying a session cookie, getting around the
  failed sign-in limit, or the dashboard being mounted when it should not be.
- **IP spoofing that produces a false `verified`.** Any request that is stored
  as `verified` without coming from the operator's published ranges, under a
  `ClientIPStrategy` that correctly matches the deployment.
- **Cross-site scripting in the dashboard.** Recorded values (paths, user
  agents, agent names, referrer data) or query parameters that end up as
  unescaped markup.
- Recovering client IP addresses from stored hashes when a signing secret is
  configured.
- Anything that lets a request make recording delay or crash the app.

Out of scope:

- `spoofed` or `verified` counts being wrong because the configured
  `ClientIPStrategy` does not match the deployment's proxies. That is a
  configuration issue; see the Security section of the README.
- Weak or leaked dashboard passwords or signing secrets.
- Agents that are unrecognised or misclassified. Report those with the
  "New AI agent" issue template.
- Denial of service through request volume alone.

## How the dashboard is protected

- **Credentials** are compared as HMACs, username and password both on every
  attempt, so neither timing nor an early return reveals which half was wrong.
  Blank or whitespace-only credentials count as unset, and the dashboard is
  then not mounted.
- **Sign-in throttling** is in memory, per process, and has two limits over
  the same window (`dashboard.loginLimit`, fifteen minutes by default):
  - per client: `maximumFailures` (five by default), keyed on a hash of the
    client address, with IPv6 addresses grouped by their /64;
  - process-wide: 50 failures from all clients together (or
    `maximumFailures`, if higher). When that ceiling is reached, **every**
    sign-in is refused until the window passes, the owner's included, and a
    `critical` line is logged. This is deliberate: it bounds the number of
    guesses even when the client address can be forged (see the Client IP
    section of the README), at the price of a temporary lockout during an
    attack.

  Each attempt is counted before the password is checked, in the same step as
  the limit check, so a burst of concurrent requests cannot exceed the limit.
- **Sessions** are stateless signed cookies (`<expiry>.<HMAC>`). The HMAC
  covers the expiry and a fingerprint of the username and password, so a
  session ends at its expiry, or as soon as the password, the username or the
  signing secret changes. Only the exact encoding the server issues is
  accepted. The cookie is `HttpOnly`, `SameSite=Lax`, scoped with `Path` to
  the dashboard path, and `Secure` according to `dashboard.secureCookies`.
- **Cross-site requests.** `POST .../login` and `POST .../logout` answer 403
  when `Sec-Fetch-Site` is `cross-site`, or when an `Origin` header is present
  and does not match the request's `Host` (or `X-Forwarded-Host`). Clients
  that send neither header, such as `curl`, are unaffected.
- **Response headers.** Every dashboard, sign-in and sign-out response sends
  `Cache-Control: no-store`, `X-Frame-Options: DENY`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`,
  `X-Robots-Tag: noindex, nofollow` and
  `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`
  (plus the origin of any absolute `logoPath` URL in `img-src`). The pages use
  no JavaScript.
- **Audit trail.** Successful sign-ins are logged at `info` and rejected ones
  at `warning`, each with the keyed hash of the client address, never the
  address itself, the submitted values or the configured ones.
- **Signing secret.** A secret shorter than 32 bytes is accepted but logged as
  a warning: one captured cookie is enough to brute-force a short key offline.

## Known limitations

- **Sign-out does not revoke a copied cookie.** Sessions are stateless, so
  sign-out only tells the browser to drop its cookie. A copy of the cookie
  taken before sign-out stays valid until it expires (twelve hours by
  default), or until the dashboard password or the signing secret changes.
  If a cookie may have leaked, change the password: that ends every session.
- **Throttling is per process.** With several app instances, each keeps its
  own counts, so the allowances multiply by the number of instances.
- A process-wide lockout can be triggered on purpose by anyone who can reach
  the sign-in endpoint, as described above. It lifts on its own when the
  window passes.

## Data protection

For each recorded AI agent visit or AI assistant referral, the `ai_bot_visits`
table stores the request method and path, the user agent, the matched agent and its
purpose, the verification result, the referring assistant's platform (for
referrals, not the full referrer URL), the site key, the status code, a
timestamp, and a keyed hash of the client IP address. Raw IP addresses are
never stored, and ordinary human traffic is not recorded.

The IP hash is an HMAC under the signing secret. Without the secret it cannot
be reversed by hashing the address space, but with it anyone can, so under
the GDPR and similar laws it is **pseudonymous personal data**, not anonymous
data. Use a long random secret (for example `openssl rand -hex 32`), keep it
out of source control, and treat it with the same care as the database.

There is no built-in retention. The dashboard reads at most 90 days back;
delete older rows on a schedule to match your retention policy, for example:

```sql
DELETE FROM ai_bot_visits WHERE created_at < now() - interval '90 days';
```
