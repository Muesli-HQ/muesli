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

Migration is automatic. Existing config/auth JSON is read, the destination is
written and read back, and only then is the old plaintext removed. A newer valid
Keychain record wins over a stale file. Malformed destination auth data cannot
delete a valid legacy file. If migration fails, the original remains usable and
migration retries on subsequent loads. New saves and refreshes fail instead of
writing new plaintext credentials. Sign-out removes the matching item and any
remaining legacy file; deletion failure is not reported as successful sign-out.
The old shared ChatGPT Keychain service can be claimed only by the production app.

An unsuccessful config credential read is not treated as an empty credential set.
An existing provider-config item must be successfully loaded into the runtime
configuration before a save can replace or clear it. Unlocking Keychain alone
does not make an earlier sanitized snapshot safe to save: reload the configuration
first. A fresh store may save only after confirming that the item is absent.
Malformed or still-inaccessible items remain untouched and saves report failure.

This does not erase historical filesystem backups or guarantee secret zeroization
in Swift memory. Provider requests necessarily hold credentials while in use.
Keys and tokens are never included in chat exports, CloudKit or telemetry by this
change. Automated tests use an injected in-memory vault and synthetic data;
Keychain integration checks must use unique disposable accounts and clean them up.
