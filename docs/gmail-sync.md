# Tracked Gmail threads

Mochlet keeps a small explicit set of email conversations synchronized. Search Gmail, select a thread and click **Track this thread**. The thread is read again with the selected account before it enters the tracked set. **Sync tracked threads** applies Gmail history to those conversations. **Load saved threads** opens their local copies offline. **Stop tracking** removes a conversation from future sync; it does not delete mail, existing memory copies, source cache or task history.

Tracking is limited to 100 conversations. New conversations found in account history are not downloaded or added automatically. The UI explains that reading account history returns change metadata across the mailbox, even though content retrieval is restricted to the tracked set. There is no watch subscription, cloud backend, scheduled polling, outgoing message or mark-as-read action.

## Synchronization contract

A new or changed tracking set requires a full refresh of that set. Mochlet records the mailbox's current profile history ID before fetching those threads, so changes during the reads can be replayed in a later sync. The next run pages `users.history.list` with that fixed `startHistoryId`. It accumulates changed thread IDs from addition, deletion and label changes, intersects them with tracked membership, then reads current thread content. Deleting one message does not imply deleting its thread: only a current thread HTTP 404 removes that tracked conversation.

All history pages and required thread reads must complete before the cursor advances. Partial responses, malformed thread identities, repeated page tokens, network errors and failed thread reads preserve the previous snapshot. History is bounded to 20 pages/2,000 records and 10,000 distinct changed thread IDs. Retrieved text is bounded to 20 MB per run; the saved snapshot is bounded to 25 MB. **Rebuild tracked threads** bypasses an excessively large history interval by reading only the tracked set again.

An HTTP 404 from the history endpoint means the cursor has expired. Mochlet invalidates that account's tracked snapshot and corresponding cached sources, preserves tracked IDs, and attempts one full refresh. A failed replacement leaves an explicit pending state with no old snapshot represented as synchronized. A thread HTTP 404 is handled separately as a missing conversation.

## Persistence and scope

`google_mail_sync` contains one account-keyed snapshot: tracking membership, complete thread records, permission generation, immutable version, history cursor and sync time. The cursor and source updates commit in the same SQLite transaction. Account identity/permissions and the expected version must still match at commit. Tracking changes, disconnects, competing completed syncs and cancellation prevent an old in-flight request from committing.

Snapshots are independent between Google accounts and separate from calendar cursors. Disconnect deletes sync state. Permission-generation changes require rebuilding before old records are shown as a synchronized set. Account/project source guards still apply when capturing tasks, retrieving connected memory or dispatching coding work. Saved mail is local application data; there is no claim of encrypted-at-rest mail storage beyond the user's operating-system protections.

## Verification

Five focused fixture tests cover selected-only retrieval, multi-page cursor reuse, message-deletion versus thread-deletion handling, cross-account isolation, unchanged history, partial history/thread failures, malformed/repeated pages, expired history/rebuild failure, membership and permission changes, cancellation, disconnect and SQLite reopening. A disposable native fixture supplies one fictional tracked conversation without any OAuth credential; offline browsing and stopping tracking can be exercised without external calls. Live Gmail OAuth/API access remains a separate validation gate.

## Primary references

- [Gmail synchronization guide](https://developers.google.com/workspace/gmail/api/guides/sync)
- [History list, pagination and expired cursor behavior](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list)
- [Profile history ID](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users/getProfile)

Retrieved through Context7 and official Google documentation on 2026-11-01. The local tracked-set refresh and transaction design are Mochlet implementation choices.
