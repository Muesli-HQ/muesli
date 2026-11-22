# Local credential storage

muesli stores provider keys and OAuth tokens in the user's login Keychain.
`AppConfig` remains the hydrated runtime configuration, but its saved JSON has
empty credential fields. Custom request headers and credential commands also live
in Keychain because either can contain secrets. Environment variables retain
their existing precedence and are not imported into persistent storage.

The service name is `com.muesli.credentials.` followed by SHA-256 of the
standardized support-directory path. Accounts are `provider-config`,
`openrouter-auth`, `chatgpt-auth` and `google-calendar-auth`. This keeps stable,
preproduction and fixed development lanes separate. Do not change the namespace
as part of branding cleanup. Moving a support directory changes its namespace.

New items trust the signed app and its signed bundled `muesli-cli`, rather than
all applications. Command-line builds outside the app bundle use their own creator
trust; a separately signed or rebuilt executable may be denied access. Keychain
queries suppress interactive authorization so a background API request never
starts a recurring permission-prompt loop. A locked or inaccessible Keychain
causes an actionable storage/authentication failure. Normal updates with the same
signing identity are intended to preserve access; signing-identity changes must
be validated separately. The ACL uses macOS's legacy login-Keychain API because
local-only development lanes have no provisioned shared access group.
The standalone CLI reads existing OpenRouter credentials without migrating or
deleting the legacy file; only the bundled CLI may perform that migration.

Migration is automatic. Existing config/auth JSON is read, the destination is
written and read back, and only then is the old plaintext removed. A newer valid
Keychain record wins over a stale file. Malformed destination auth data cannot
delete a valid legacy file. If migration fails, the original remains usable and
migration retries on subsequent loads. New saves never write plaintext credentials.
If ChatGPT rotates a refresh token while Keychain persistence fails, the refreshed
session stays in memory and persistence retries on its next use. It is not written
to disk; quitting before persistence succeeds can require signing in again.
Sign-out removes the matching item and any
remaining legacy file; deletion failure is not reported as successful sign-out.
The old shared ChatGPT Keychain service can be claimed only by the production app.

An unsuccessful config credential read is not treated as an empty credential set.
An existing provider-config item must be successfully loaded into the runtime
configuration before a save can replace or clear it. Unlocking Keychain alone
does not make an earlier sanitized snapshot safe to save: reload the configuration
first. Indicator reads use a separate snapshot and cannot authorize saves from
the owner's stale configuration. A fresh store may save only after confirming
that the item is absent.
Malformed or still-inaccessible items remain untouched and saves report failure.

Settings API-key edits commit on Return or focus loss using the shared native
editing coordinator, rather than writing Keychain on each keystroke. Transient
onboarding/manual-key drafts remain live. ChatGPT's displayed sign-in state is
cached; each API request reads and validates one fresh token snapshot. Successful
sign-in/sign-out updates the display state, while failed sign-out preserves it.
App activation and an explicit ChatGPT provider menu selection refresh credential
status outside view rendering, allowing a session blocked at launch to recover
after Keychain unlock without repeating OAuth.

This does not erase historical filesystem backups or guarantee secret zeroization
in Swift memory. Provider requests necessarily hold credentials while in use.
Keys and tokens are never included in chat exports, CloudKit or telemetry by this
change. Automated tests use an injected in-memory vault and synthetic data;
Keychain integration checks must use unique disposable accounts and clean them up.
