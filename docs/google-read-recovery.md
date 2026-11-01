# Google read recovery

Gmail, Calendar and Drive GET requests now retry temporary service failures within a small bounded operation. This includes paged synchronization and source revalidation; each retry sends the exact same URL, query, account token and headers. Source revisions and account-generation checks still control whether results can be committed or used for coding.

## Policy

- At most four transport attempts: the initial request and three retries.
- Retry HTTP 429, 500, 502, 503 and 504, and HTTP 403 only when every returned legacy error reason is `rateLimitExceeded` or `userRateLimitExceeded`.
- Retry connection loss and request timeout. Offline, cancelled, authentication, permission, missing-source, invalid-input and malformed-result failures propagate immediately.
- Delays are 1, 2 and 4 seconds plus up to one second of fresh random jitter. Valid `Retry-After` seconds or HTTP dates can increase a delay. Total scheduled waiting is limited to 15 seconds per GET; a server-requested delay that exceeds the remaining budget stops the operation instead of retrying early. Existing network timeouts apply separately to each attempt.
- Cancellation is checked before each request and after its response. Waiting uses cancellable Swift concurrency suspension, without blocking the UI.
- Only body-free HTTPS GETs to the known Google API hosts can enter this path. Shared connector transport, free/busy POST, Gmail sends/drafts, Calendar mutations and team connectors retain their single-attempt behavior. A cancelled or uncertain outbound action still uses its existing delivery ledger and reconciliation rules.

Retries do not advance synchronization cursors, change project bindings, refresh credentials, switch providers or add background polling. HTTP 404/410 still reach the mail/calendar synchronization layers for their endpoint-specific expiry and deletion handling. Cancel remains available through the existing Google operation control.

## Evidence

Five added test declarations cover exact-request replay, exhaustion, transient network errors, permanent/mixed permission errors, server dates and wait budgets, cancellation during sleep and late transport completion, forbidden methods/hosts/body, and calendar page recovery without premature cursor advancement. Existing sync outage fixtures now explicitly return a 60-second service wait, so their rollback tests represent an outage longer than the interactive budget.

Core fixtures do not establish live Google OAuth/API behavior. Live account, revocation and sleep/network validation remain open.

## Reference

Google recommends exponential backoff for temporary rate/service errors: [Gmail error handling](https://developers.google.com/workspace/gmail/api/guides/handle-errors) and [quota backoff](https://developers.google.com/workspace/gmail/api/reference/quota), retrieved through Context7 on 2026-11-02. The read-only scope, attempt/wait caps and preservation of one-attempt delivery are Mochlet design choices.
