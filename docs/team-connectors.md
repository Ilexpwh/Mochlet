# Team connectors

Mochlet reads a deliberately selected Slack thread, Lark/Feishu message thread or Linear issue into a project. Tokens are stored in Keychain. Local account records include verified workspace and user identities. Each read rechecks identity; cached sources and task bindings never grant remote access. Permission markers in SQLite describe adapter capabilities, not remotely granted scopes.

## Setup and bounds

- Slack: app user OAuth token with access to the chosen channel and history. Enter channel ID and parent message timestamp. Reads up to 500 messages / ten pages and requires the root. Files, blocks and linked resources are not downloaded. Slack Connect and private-channel membership remain subject to Slack policy.
- Linear: personal API key for the intended workspace/teams. Enter issue UUID or identifier. Queries issue metadata and comments; rejects GraphQL partial errors, changing revisions and a moved team on revalidation. Limits are 500 comments / ten pages.
- Lark or Feishu: user access token for the corresponding service. The tenant and app-scoped user identity are verified. Enter an exact message ID. Visible thread replies are fetched only within the same chat/thread. Missing/deleted/invisible roots fail rather than producing a misleading complete thread. The source locator is an authenticated API URL, not a claimed public deep link.

All readers reject oversized responses, redirects, repeated pagination cursors and incomplete bounded snapshots. Rate limits fail visibly; no background retry storm is scheduled. A selected source is copied to memory only through an explicit action. Disconnect removes cached account sources and blocks linked task dispatch; connected memory copies remain editable but are excluded from AI context after disconnect. Users may explicitly create independent copies in Knowledge & Memory.

Task preparation installs an editable instruction with structured provenance and an exact project/task destination. Changing that destination requires preparing again. Source identity and access are rechecked before queueing and before dispatch. Source text is untrusted context, not authority for external actions.

## Evidence and open gates

Fixture tests cover Slack pagination/root/account checks, Linear errors/team changes, Lark tenant/chat/root checks, and idempotent project capture after disconnect. Native setup controls were inspected without real credentials. Live authentication/access, consent management, automatic OAuth renewal, incremental monitoring and outbound messages/status updates remain open. No third-party SDK was copied into the app for these adapters.

## Primary research

- [Slack conversations.replies](https://docs.slack.dev/reference/methods/conversations.replies/), [auth.test](https://docs.slack.dev/reference/methods/auth.test/) and [chat.getPermalink](https://docs.slack.dev/reference/methods/chat.getPermalink/). Current method documentation governs rate limits; fixed backoff assumptions from older articles are not used.
- [Linear GraphQL authentication](https://linear.app/developers/graphql), [pagination](https://linear.app/developers/pagination), and [official SDK schema](https://github.com/linear/linear/blob/master/packages/sdk/src/schema.graphql). Personal keys and OAuth bearer tokens have distinct authorization syntax; this implementation accepts personal keys.
- [Lark user identity](https://open.larksuite.com/document/home/user-identity-introduction), [official Go SDK authen types](https://github.com/larksuite/oapi-sdk-go/blob/v3_main/service/authen/v1/model.go), and [official Node SDK](https://github.com/larksuite/node-sdk). Lark and Feishu use separate API hosts and account namespaces.
