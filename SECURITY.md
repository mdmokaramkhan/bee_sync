# Security policy

## Supported versions

bee_sync is before 1.0. Security fixes go into the latest release only.

| Version | Supported |
|---|---|
| 0.3.x | ✅ |
| < 0.3 | ❌ |

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub instead:
[Report a vulnerability](https://github.com/mdmokaramkhan/bee_sync/security/advisories/new).

Include:
- what an attacker can do, and under which conditions;
- the bee_sync version, platform (Android, iOS) and OS version;
- steps or code to reproduce it.

You'll get a reply within 7 days. Once a fix is released, the advisory is published with credit to you, unless you'd rather stay anonymous.

## Security model

Know these properties before you send sensitive data through bee_sync:

- **Events are stored unencrypted** in a SQLite database in the app's private storage. Other apps can't read it, but it can be read on a rooted or jailbroken device, or from an unencrypted device backup. Don't put secrets or sensitive personal data in event properties. Encryption at rest is planned after 1.0.
- **Transport headers are stored in plaintext in that database too**, so the native background uploader can authenticate. Use a long-lived, ingestion-only key that can only write events, never a user's session token.
- **Use HTTPS.** bee_sync sends to whatever endpoint you configure. The example app allows plain HTTP only so it can reach a local test server.
- **Redirects are never followed**, so a batch can't be re-sent to another host.
- **The background log never records payloads or headers**, only counts and errors.
- **Delivery is at-least-once.** Your server can receive the same event twice; deduplicate on the event `id` (see [doc/server-guide.md](doc/server-guide.md)).
