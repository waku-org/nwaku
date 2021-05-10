# Changelog

## Next version

- Refactor: Split out `waku_types` types into right place; create utils folder.
- Refactor: Replace sequence of ContentTopics in ContentFilter with a single ContentTopic.
- Docs: Add information on how to query Status test fleet for node addresses; how to view logs and how to update submodules.
- PubSub topic `subscribe` and `unsubscribe` no longer returns a future (removed `async` designation)
- Added a peer manager for `relay`, `filter`, `store` and `swap` peers.
- `relay`, `filter`, `store` and `swap` peers are now stored in a common, shared peer store and no longer in separate sets.
- Admin API now provides a `post` method to connect to peers on an ad-hoc basis
- Added persistent peer storage. A node will now attempt to reconnect to `relay` peers after a restart.
- Changed `contentTopic` back to a string
- Fixed: content filtering now works on any PubSub topic and not just the `waku` default.
- Added the `pubsubTopic` field to the `HistoryQuery`. Now, the message history can be filtered and queried based on the `pubsubTopic`.
- Added a new table of `Message` to the message store db. The new table has an additional column of `pubsubTopic` and will be used instead of the old table `messages`.  The message history in the old table `messages` will not be accessed and have to be removed.
- Added a new column of `version` to the `Message` table of the message store db.
- Fix: allow mounting light protocols without `relay`
- Add `keep-alive` option to maintain stable connection to `relay` peers on idle topics
- Add a bridge between Waku v1 and v2
- Add a chat application (`chat2`) over Waku v2 with bridging to matterbridge

## 2021-01-05 v0.2

This release contains the following changes:

- Calls to `publish` a message on `wakunode2` now `await` instead of `discard` dispatched [`WakuRelay`](https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-relay.md) procedures.
- [`StrictNoSign`](https://github.com/libp2p/specs/tree/master/pubsub#message-signing) enabled.
- Add JSON-RPC API for external access to `wakunode2` functionality:
  - Admin API retrieves information about peers registered on the `wakunode2`.
  - Debug API exposes debug information about a `wakunode2`.
  - Filter API saves bandwidth by allowing light nodes to filter for specific content.
  - Private API enables symmetric or asymmetric cryptography to encrypt/decrypt message payloads.
  - Relay API allows basic pub/sub functionality.
  - Store API retrieves historical messages.
- Add tutorial on how to use JSON-RPC API.
- Refactor: Move `waku_filter` protocol into its own module.

The Waku v2 implementation, and [most protocols it consist of](https://specs.vac.dev/specs/waku/),
are still in a draft/beta state. The Waku v1 implementation is stable but not under active development.

## 2020-11-30 v0.1

Initial beta release.

This release contains:

- A Nim implementation of the [Waku v1 protocol](https://specs.vac.dev/waku/waku.html).
- A Nim implementation of the [Waku v2 protocol](https://specs.vac.dev/specs/waku/v2/waku-v2.html).
- CLI applications `wakunode` and `wakunode2` that allows you to run a Waku v1 or v2 node.
- Examples of Waku v1 and v2 usage.
- Various tests of above.

Currenty the Waku v2 implementation, and [most protocols it consist of](https://specs.vac.dev/specs/waku/),
are in a draft/beta state. The Waku v1 implementation is stable but not under active development.

Feedback welcome!
