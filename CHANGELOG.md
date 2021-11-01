# Changelog

## Next version

This release contains the following:

### Features

- Waku v2 node discovery via DNS following [EIP-1459](https://eips.ethereum.org/EIPS/eip-1459)
- Waku v2 node discovery via [Node Discovery v5](https://github.com/ethereum/devp2p/blob/master/discv5/discv5-theory.md)

### Changes

- GossipSub [prune backoff period](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#prune-backoff-and-peer-exchange) is now the recommended 1 minute
- Bridge now uses content topic format according to [23/WAKU2-TOPICS](https://rfc.vac.dev/spec/23/)
- Better internal differentiation between local and remote peer info
- Maximum number of libp2p connections is now configurable
- Unsecure Websocket is now supported in nim-waku. 

#### General refactoring

#### Docs

- Added contributor guidelines on Waku v2 fleet monitoring and management.
- Added basic tutorial on using Waku v2 DNS-based discovery

#### Schema

#### API

### Fixes

- Bridge no longer re-encodes already encoded payloads when publishing to V1
- Bridge now populates WakuMessage timestamps when publishing to V2

## 2021-07-26 v0.5.1

This patch release contains the following fix:
- Support for multiple protocol IDs when reconnecting to previously connected peers:
A bug in `v0.5` caused clients using persistent peer storage to only support the mounted protocol ID.

This is a patch release that is fully backwards-compatible with release `v0.5`.
It supports the same [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`17/WAKU-RLN`](https://rfc.vac.dev/spec/17/) | `raw` | `/vac/waku/waku-rln-relay/2.0.0-alpha1` |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta3` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2021-07-23 v0.5

This release contains the following:

### Features
- Support for keep-alives using [libp2p ping protocol](https://docs.libp2p.io/concepts/protocols/#ping).
- DB migration for the message and peer stores.
- Support for multiple protocol IDs. Mounted protocols now match versions of the same protocol that adds a postfix to the stable protocol ID.

### Changes
- Bridge topics are now configurable.
- The `resume` Nim API now eliminates duplicates messages before storing them.
- The `resume` Nim API now fetches historical messages in page sequence.
- Added support for stable version of `relay` protocol, with protocol ID `/vac/waku/relay/2.0.0`.
- Added optional `timestamp` to `WakuRelayMessage`.
- Removed `PCRE` as a prerequisite for building Waku v1 and Waku v2.
- Improved [`swap`](https://rfc.vac.dev/spec/18/) metrics.

#### General refactoring
- Refactored modules according to [Nim best practices](https://hackmd.io/1imOGULZRsed2HpgmzGleA).
- Simplified the [way protocols get notified](https://github.com/status-im/nim-waku/issues/574) of new messages.
- Refactored `wakunode2` setup into 6 distinct phases with improved logging and error handling.
- Moved `Whisper` types and protocol from the `nim-eth` module to `nim-waku`.

#### Docs
- Added [database migration tutorial](https://github.com/status-im/nim-waku/blob/master/docs/tutorial/db-migration.md).
- Added [tutorial to setup `websockify`](https://github.com/status-im/nim-waku/blob/master/docs/tutorial/websocket.md).

#### Schema
- Updated the `Message` table of the persistent message store:
  - Added `senderTimestamp` column.
  - Renamed the `timestamp` column to `receiverTimestamp` and changes its type to `REAL`.

#### API
- Added optional `timestamp` to [`WakuRelayMessage`](https://rfc.vac.dev/spec/16/#wakurelaymessage) on JSON-RPC API.

### Fixes
- Conversion between topics for the Waku v1 <-> v2 bridge now follows the [RFC recommendation](https://rfc.vac.dev/spec/23/).
- Fixed field order of `HistoryResponse` protobuf message: the field numbers of the `HistoryResponse` are shifted up by one to match up the [13/WAKU2-STORE](https://rfc.vac.dev/spec/13/) specs.

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`17/WAKU-RLN`](https://rfc.vac.dev/spec/17/) | `raw` | `/vac/waku/waku-rln-relay/2.0.0-alpha1` |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta3` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2021-06-03 v0.4

This release contains the following:

### Features

- Initial [`toy-chat` implementation](https://rfc.vac.dev/spec/22/)

### Changes

- The [toy-chat application](https://github.com/status-im/nim-waku/blob/master/docs/tutorial/chat2.md) can now perform `lightpush` and request content-filtered messages from remote peers.
- The [toy-chat application](https://github.com/status-im/nim-waku/blob/master/docs/tutorial/chat2.md) now uses default content topic `/toy-chat/2/huilong/proto`
- Improve `toy-chat` [briding to matterbridge]((https://github.com/status-im/nim-waku/blob/master/docs/tutorial/chat2.md#bridge-messages-between-chat2-and-matterbridge))
- Improve [`swap`](https://rfc.vac.dev/spec/18/) logging and enable soft mode by default
- Content topics are no longer in a redundant nested structure
- Improve error handling

#### API

- [JSON-RPC Store API](https://rfc.vac.dev/spec/16): Added an optional time-based query to filter historical messages.
- [Nim API](https://github.com/status-im/nim-waku/blob/master/docs/api/v2/node.md): Added `resume` method.

### Fixes

- Connections between nodes no longer become unstable due to keep-alive errors if mesh grows large
- Re-enable `lightpush` tests and fix Windows CI failure

The [Waku v2 suite of protocols](https://rfc.vac.dev/) are still in a raw/draft state.
This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`17/WAKU-RLN`](https://rfc.vac.dev/spec/17/) | `raw` | `/vac/waku/waku-rln-relay/2.0.0-alpha1` |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `draft` | `/vac/waku/relay/2.0.0-beta2` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta3` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2021-05-11 v0.3

This release contains the following:

### Features

- Start of [`RLN relay` implementation](https://rfc.vac.dev/spec/17/)
- Start of [`swap` implementation](https://rfc.vac.dev/spec/18/)
- Start of [fault-tolerant `store` implementation](https://rfc.vac.dev/spec/21/)
- Initial [`bridge` implementation](https://rfc.vac.dev/spec/15/) between Waku v1 and v2 protocols
- Initial [`lightpush` implementation](https://rfc.vac.dev/spec/19/)
- A peer manager for `relay`, `filter`, `store` and `swap` peers
- Persistent storage for peers: A node with this feature enabled will now attempt to reconnect to `relay` peers after a restart. It will respect the gossipsub [PRUNE backoff](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#prune-backoff-and-peer-exchange) period before attempting to do so.
- `--persist-peers` CLI option to persist peers in local storage
- `--persist-messages` CLI option to store historical messages locally
- `--keep-alive` CLI option to maintain a stable connection to `relay` peers on idle topics
- A CLI chat application ([`chat2`](https://github.com/status-im/nim-waku/blob/master/docs/tutorial/chat2.md)) over Waku v2 with [bridging to matterbridge](https://github.com/status-im/nim-waku/blob/master/docs/tutorial/chat2.md#bridge-messages-between-chat2-and-matterbridge)

### Changes
- Enable `swap` protocol by default and improve logging
#### General refactoring

- Split out `waku_types` types into the right place; create `utils` folder.
- Change type of `contentTopic` in [`ContentFilter`](https://rfc.vac.dev/spec/12/#protobuf) to `string`.
- Replace sequence of `contentTopics` in [`ContentFilter`](https://rfc.vac.dev/spec/12/#protobuf) with a single `contentTopic`.
- Add `timestamp` field to [`WakuMessage`](https://rfc.vac.dev/spec/14/#payloads).
- Ensure CLI config parameters use a consistent naming scheme. Summary of changes [here](https://github.com/status-im/nim-waku/pull/543).

#### Docs

Several clarifications and additions aimed at contributors, including
  - information on [how to query Status test fleet](https://github.com/status-im/nim-waku/blob/master/docs/faq.md) for node addresses,
  - [how to view logs](https://github.com/status-im/nim-waku/blob/master/docs/contributors/cluster-logs.md), and
  - [how to update submodules](https://github.com/status-im/nim-waku/blob/master/docs/contributors/git-submodules.md).

#### Schema

- Add `Message` table to the persistent message store. This table replaces the old `messages` table. It has two additional columns, namely
  - `pubsubTopic`, and
  - `version`.
- Add `Peer` table for persistent peer storage.

#### API

- [JSON-RPC Admin API](https://rfc.vac.dev/spec/16): Added a [`post` method](https://rfc.vac.dev/spec/16/#post_waku_v2_admin_v1_peers) to connect to peers on an ad-hoc basis.
- [Nim API](https://github.com/status-im/nim-waku/blob/master/docs/api/v2/node.md): PubSub topic `subscribe` and `unsubscribe` no longer returns a future (removed `async` designation).
- [`HistoryQuery`](https://rfc.vac.dev/spec/13/#historyquery): Added  `pubsubTopic` field. Message history can now be filtered and queried based on the `pubsubTopic`.
- [`HistoryQuery`](https://rfc.vac.dev/spec/13/#historyquery): Added support for querying a time window by specifying start and end times.

### Fixes

- Running nodes can now be shut down gracefully
- Content filtering now works on any PubSub topic and not just the `waku` default.
- Nodes can now mount protocols without supporting `relay` as a capability

The [Waku v2 suite of protocols](https://rfc.vac.dev/) are still in a raw/draft state.
This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`17/WAKU-RLN`](https://rfc.vac.dev/spec/17/) | `raw` | `/vac/waku/waku-rln-relay/2.0.0-alpha1` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `raw` | `/vac/waku/swap/2.0.0-alpha1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `raw` | `/vac/waku/lightpush/2.0.0-alpha1` |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `draft` | `/vac/waku/relay/2.0.0-beta2` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta3` |

The Waku v1 implementation is stable but not under active development.

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
