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
