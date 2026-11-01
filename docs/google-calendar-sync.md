# Google calendar synchronization

Mochlet can explicitly synchronize one selected calendar into local storage. In Google → Calendar, expand **Saved calendar records**, then click **Sync calendar records**. **Load saved records** reads the last completed snapshot without requiring a network request. Previously synchronized calendars appear in the picker after relaunch with a “saved” label.

This is separate from **Refresh agenda**, which requests expanded occurrences in a seven-day interval, and **Check selected calendar availability**, which makes a fresh free/busy request. Saved series definitions are not an availability calculation.

## Scope and behavior

- The first sync reads the selected calendar’s history and unexpanded recurring series. Later syncs request changes using Google's `nextSyncToken`.
- The query remains `singleEvents=false`, `showDeleted=true`, `maxResults=250`. It never combines a sync token with time bounds, ordering, search, or other prohibited restrictions.
- Each run is bounded to 40 pages, 5,000 changed identities and 20 MB of active event body text. A saved snapshot is bounded to 5,000 active records plus cancelled occurrences and 25 MB encoded. Oversized calendars fail visibly rather than silently truncating or advancing the cursor.
- The UI filters saved titles/content and shows 100 records at a time. It displays the last successful synchronization time and distinguishes saved records from the live agenda.
- Deleted events are removed. Cancelled recurrence exceptions retain their event ID, parent series ID and original start time separately; they are not active task sources. Selecting the parent shows their count and the first 20 original start times. An empty delta preserves them, restoration removes the cancellation, and deleting the parent removes its children and exceptions.
- Sync does not create tasks, send messages, record meetings, or change Google events. Source capture and summaries still perform their existing fresh-content checks.

## Durability and account isolation

A SQLite migration adds `google_calendar_sync`, keyed by local account and calendar ID. The account's permission generation, immutable snapshot version, complete records and final cursor are committed in one transaction. Every page must succeed before the transaction begins. Repeated page tokens, duplicate event IDs, missing revisions, missing final tokens and malformed responses abort the run.

The commit compares the account and expected snapshot version. Disconnects, permission/binding changes and a competing completed sync prevent stale results from committing. Disconnect cascades to the calendar snapshots. Changed permission generations require a new full sync before offline discovery exposes records.

An incremental HTTP 410 invalidates only that calendar's cursor and cached sources, then attempts one full sync. If replacement fails, no old snapshot is presented as current. Other failures preserve the last completed snapshot, which can be explicitly loaded with its original timestamp. Temporary read failures use [bounded Google GET retries](google-read-recovery.md). Retry attempts retain the same page and cursor; only the completed result can commit. There is no background polling or automatic provider fallback.

Changes/deletions invalidate older cached agenda instances of the affected recurring series. Independent source reads completed after the sync request began are retained for their own subsequent revision/access checks. This is a calendar record cache, not an offline recurrence-expansion engine or a guarantee of current availability.

## Evidence

Five fixture tests cover multi-page full/incremental sync, constant cursor across pages, deletion isolation, partial-page/network failure, invalid/repeated page data, HTTP 410 replacement and replacement failure, optimistic concurrency, disconnected/account-generation rejection, SQLite reopening, and cancelled occurrence restoration/parent deletion. No live Google account or OAuth grant was used for these tests. Native offline browsing is validated with a disposable fictional calendar snapshot; this does not establish live OAuth/API compatibility.

## Primary references

- [Google incremental synchronization](https://developers.google.com/workspace/calendar/api/guides/sync)
- [Events list parameters and token restrictions](https://developers.google.com/workspace/calendar/api/v3/reference/events/list)
- [Event status and cancelled recurrence semantics](https://developers.google.com/workspace/calendar/api/v3/reference/events#status)

Retrieved through Context7 and official Google documentation on 2026-11-01.
