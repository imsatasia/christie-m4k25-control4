# Security policy

## Supported versions

Only the latest release of the Christie M 4K25 RGB Control4 driver receives fixes.

## Reporting a vulnerability

Please report security problems privately, using GitHub's private vulnerability
reporting: open the **Security** tab of this repository and choose **Report a
vulnerability** (or go to <https://github.com/imsatasia/christie-m4k25-control4/security/advisories/new>).
Please do not open a public issue for a vulnerability.

This project is maintained by one person in their spare time, so this is
best-effort: I aim to acknowledge a report within a week and to say what I plan
to do about it shortly after.

## In scope

Bugs in the driver's Lua code, for example in message building and parsing, or in `SendRaw`, the command that lets a Composer Pro program send a raw message (it checks that the text is exactly one message before sending).

## Out of scope

- Vulnerabilities in the projector's own firmware: report those to Christie.
- Vulnerabilities in Control4 or Composer Pro: report those to the Control4 project.
- Advisories in test-only dependencies. Dependabot tracks those publicly and
  none of them ship in a release.

## Deployment note

When this project was tested, the projector's serial API on TCP 3002 accepted commands with no credentials, and nothing here adds authentication or encryption on top. Keep the projector on a trusted network and do not expose port 3002 to the internet.

## Please leave your device details out

Please do not include real IP addresses, serial numbers or MAC addresses of your
devices in reports, issues or pull requests. Placeholders such as `192.0.2.50` are
fine.
