## v0.22.0 (2023-11-15)

> Note: The `--topic` option is now deprecated in favor of a more specific options `--pubsub-topic` & `--content-topic`

> Note: The `--ext-multiaddr-only` CLI flag was introduced for cases in which the user wants to manually set their announced addresses

## What's Changed

Release highlights:
* simplified the process of generating RLN credentials through the new `generateRlnKeystore` subcommand
* added support for configuration of port 0 in order to bind to kernel selected ports
* shards are now automatically updated in metadata protocol when supported shards change on runtime
* introduced `messageHash` attribute to SQLite which will later replace the `id` attribute

### Features

- rln-keystore-generator is now a subcommand ([#2189](https://github.com/waku-org/nwaku/issues/2189)) ([3498a846](https://github.com/waku-org/nwaku/commit/3498a846))
- amending computeDigest func. + related test cases ([#2132](https://github.com/waku-org/nwaku/issues/2132))" ([#2180](https://github.com/waku-org/nwaku/issues/2180)) ([d7ef3ca1](https://github.com/waku-org/nwaku/commit/d7ef3ca1))
- **discv5:** filter out peers without any listed capability ([#2186](https://github.com/waku-org/nwaku/issues/2186)) ([200a11da](https://github.com/waku-org/nwaku/commit/200a11da))
- metadata protocol shard subscription ([#2149](https://github.com/waku-org/nwaku/issues/2149)) ([bcf8e963](https://github.com/waku-org/nwaku/commit/bcf8e963))
- REST APIs discovery handlers ([#2109](https://github.com/waku-org/nwaku/issues/2109)) ([7ca516a5](https://github.com/waku-org/nwaku/commit/7ca516a5))
- implementing port 0 support ([#2125](https://github.com/waku-org/nwaku/issues/2125)) ([f7b9afc2](https://github.com/waku-org/nwaku/commit/f7b9afc2))
- messageHash attribute added in SQLite + testcase ([#2142](https://github.com/waku-org/nwaku/issues/2142))" ([#2154](https://github.com/waku-org/nwaku/issues/2154)) ([13aeebe4](https://github.com/waku-org/nwaku/commit/13aeebe4))
- messageHash attribute added in SQLite + testcase ([#2142](https://github.com/waku-org/nwaku/issues/2142)) ([9cd8c73d](https://github.com/waku-org/nwaku/commit/9cd8c73d))
- amending computeDigest func. + related test cases ([#2132](https://github.com/waku-org/nwaku/issues/2132)) ([1669f710](https://github.com/waku-org/nwaku/commit/1669f710))

### Bug Fixes

- typo ([6dd28063](https://github.com/waku-org/nwaku/commit/6dd28063))
- lightpush rest  ([#2176](https://github.com/waku-org/nwaku/issues/2176)) ([fa467e24](https://github.com/waku-org/nwaku/commit/fa467e24))
- **ci:** fix Docker tag for latest and release jobs ([52759faa](https://github.com/waku-org/nwaku/commit/52759faa))
- **rest:** fix bug in rest api when sending rln message ([#2169](https://github.com/waku-org/nwaku/issues/2169)) ([250e8b98](https://github.com/waku-org/nwaku/commit/250e8b98))
- updating v0.21.1 release date in changelog ([#2160](https://github.com/waku-org/nwaku/issues/2160)) ([3be61636](https://github.com/waku-org/nwaku/commit/3be61636))

### Changes

- Optimize postgres - prepared statements in select ([#2182](https://github.com/waku-org/nwaku/issues/2182)) ([6da1aeec](https://github.com/waku-org/nwaku/commit/6da1aeec))
- **release:** update changelog for v0.21.2 release ([#2188](https://github.com/waku-org/nwaku/issues/2188)) ([d0a93e7c](https://github.com/waku-org/nwaku/commit/d0a93e7c))
- upgrade dependencies v0.22 ([#2185](https://github.com/waku-org/nwaku/issues/2185)) ([b9563ae0](https://github.com/waku-org/nwaku/commit/b9563ae0))
- Optimize postgres - use of rowCallback approach ([#2171](https://github.com/waku-org/nwaku/issues/2171)) ([2b4ca4d0](https://github.com/waku-org/nwaku/commit/2b4ca4d0))
- **networking:** lower dhigh to limit amplification factor ([#2168](https://github.com/waku-org/nwaku/issues/2168)) ([f0f69b32](https://github.com/waku-org/nwaku/commit/f0f69b32))
- Minor Postgres optimizations ([#2166](https://github.com/waku-org/nwaku/issues/2166)) ([282c2e81](https://github.com/waku-org/nwaku/commit/282c2e81))
- adding patch release instructions to release doc ([#2157](https://github.com/waku-org/nwaku/issues/2157)) ([cc01bb07](https://github.com/waku-org/nwaku/commit/cc01bb07))
- **release:** update changelog for v0.21.1 release ([#2155](https://github.com/waku-org/nwaku/issues/2155)) ([b109a583](https://github.com/waku-org/nwaku/commit/b109a583))
- adding ext-multiaddr-only CLI flag ([#2141](https://github.com/waku-org/nwaku/issues/2141)) ([944dfdaa](https://github.com/waku-org/nwaku/commit/944dfdaa))
- bumping nim-libp2p to include WSS fix ([#2150](https://github.com/waku-org/nwaku/issues/2150)) ([817a7b2e](https://github.com/waku-org/nwaku/commit/817a7b2e))
- **cbindings:** avoid using global var in libwaku.nim ([#2118](https://github.com/waku-org/nwaku/issues/2118)) ([1e8f5771](https://github.com/waku-org/nwaku/commit/1e8f5771))
- adding postgres flag to manual docker job instructions ([#2139](https://github.com/waku-org/nwaku/issues/2139)) ([459331e3](https://github.com/waku-org/nwaku/commit/459331e3))

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` <br />`/vac/waku/filter-subscribe/2.0.0-beta1` <br />`/vac/waku/filter-push/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |
| [`66/WAKU2-METADATA`](https://rfc.vac.dev/spec/66/) | `raw` | `/vac/waku/metadata/1.0.0` |

The Waku v1 implementation has been removed from this repository and can be found in a separate [Waku Legacy](https://github.com/waku-org/waku-legacy) repository.

## Upgrade instructions

* Note that the `--topic` CLI option is now deprecated in favor of a more specific options `--pubsub-topic` & `--content-topic`.

## v0.21.3 (2023-11-09)

This patch release adds the following feature:
- Adding generateRlnKeystore subcommand for RLN membership generation

### Features

- rln-keystore-generator is now a subcommand ([#2189](https://github.com/waku-org/nwaku/issues/2189)) ([1e919177](https://github.com/waku-org/nwaku/commit/1e919177))

This is a patch release that is fully backwards-compatible with release `v0.21.0`, `v0.21.1` and `v0.21.2`.

It supports the same [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` <br />`/vac/waku/filter-subscribe/2.0.0-beta1` <br />`/vac/waku/filter-push/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation has been removed from this repository and can be found in a separate [Waku Legacy](https://github.com/waku-org/waku-legacy) repository.

## v0.21.2 (2023-11-07)

This patch release addresses the following issue:
- Inability to send RLN messages through the REST API

### Bug Fixes

- **rest:** fix bug in rest api when sending rln message ([#2169](https://github.com/waku-org/nwaku/issues/2169)) ([33decd7a](https://github.com/waku-org/nwaku/commit/33decd7a))

This is a patch release that is fully backwards-compatible with release `v0.21.0` and `v0.21.1`.

It supports the same [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` <br />`/vac/waku/filter-subscribe/2.0.0-beta1` <br />`/vac/waku/filter-push/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation has been removed from this repository and can be found in a separate [Waku Legacy](https://github.com/waku-org/waku-legacy) repository.

## v0.21.1 (2023-10-26)

This patch release addresses the following issues:
- WSS connections being suddenly terminated under rare conditions
- Ability for the user to control announced multiaddresses 

### Changes

- adding ext-multiaddr-only CLI flag ([#2141](https://github.com/waku-org/nwaku/issues/2141)) ([e2dfc2ed](https://github.com/waku-org/nwaku/commit/e2dfc2ed))
- bumping nim-libp2p to include WSS fix ([#2150](https://github.com/waku-org/nwaku/issues/2150)) ([18b5149a](https://github.com/waku-org/nwaku/commit/18b5149a))

This is a patch release that is fully backwards-compatible with release `v0.21.0`.

It supports the same [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` <br />`/vac/waku/filter-subscribe/2.0.0-beta1` <br />`/vac/waku/filter-push/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation has been removed from this repository and can be found in a separate [Waku Legacy](https://github.com/waku-org/waku-legacy) repository.

## v0.21.0 (2023-10-18)

> Note: This is the last release supporting the `--topic` option. It is being deprecated in favor of a more specific options `--pubsub-topic` & `--content-topic`

## What's Changed

Release highlights:
* Implemented a req/resp [protocol](https://rfc.vac.dev/spec/66/) that provides information about the node's medatadata
* Added REST APIs for Filter v2 and Lightpush protocols' services
* Ported /admin endpoint to REST
* Added a size-based retention policy for the user to set a limit for SQLite storage used

### Features

- add new metadata protocol ([#2062](https://github.com/waku-org/nwaku/issues/2062)) ([d5c3ade5](https://github.com/waku-org/nwaku/commit/d5c3ade5))
- /admin rest api endpoint  ([#2094](https://github.com/waku-org/nwaku/issues/2094)) ([7b5c36b1](https://github.com/waku-org/nwaku/commit/7b5c36b1))
- **coverage:** Add simple coverage ([#2067](https://github.com/waku-org/nwaku/issues/2067)) ([d864db3f](https://github.com/waku-org/nwaku/commit/d864db3f))
- added RELAY openapi definitions ([#2081](https://github.com/waku-org/nwaku/issues/2081)) ([56dbe2a7](https://github.com/waku-org/nwaku/commit/56dbe2a7))
- **wakucanary:** add latency measurement using ping protocol ([#2074](https://github.com/waku-org/nwaku/issues/2074)) ([6cb9a8da](https://github.com/waku-org/nwaku/commit/6cb9a8da))
- Autosharding API for RELAY subscriptions ([#1983](https://github.com/waku-org/nwaku/issues/1983)) ([1763b1ef](https://github.com/waku-org/nwaku/commit/1763b1ef))
- **networkmonitor:** add ping latencies, optimize reconnections ([#2068](https://github.com/waku-org/nwaku/issues/2068)) ([ed473545](https://github.com/waku-org/nwaku/commit/ed473545))
- peer manager can filter peers by shard ([#2063](https://github.com/waku-org/nwaku/issues/2063)) ([0d9e9fbd](https://github.com/waku-org/nwaku/commit/0d9e9fbd))
- lightpush rest api ([#2052](https://github.com/waku-org/nwaku/issues/2052)) ([02a814bd](https://github.com/waku-org/nwaku/commit/02a814bd))
- HTTP REST API: Filter support v2 ([#1890](https://github.com/waku-org/nwaku/issues/1890)) ([dac072f8](https://github.com/waku-org/nwaku/commit/dac072f8))

### Bug Fixes

- fix wrong install of filter rest api ([#2133](https://github.com/waku-org/nwaku/issues/2133)) ([5277d122](https://github.com/waku-org/nwaku/commit/5277d122))
- consider WS extMultiAddrs before publishing host address ([#2122](https://github.com/waku-org/nwaku/issues/2122)) ([a5b1cfd0](https://github.com/waku-org/nwaku/commit/a5b1cfd0))
- return erring response if lightpush request is invalid ([#2083](https://github.com/waku-org/nwaku/issues/2083)) ([2c5eb427](https://github.com/waku-org/nwaku/commit/2c5eb427))
- sqlite limited delete query bug ([#2111](https://github.com/waku-org/nwaku/issues/2111)) ([06bc433a](https://github.com/waku-org/nwaku/commit/06bc433a))
- cluster id & sharding terminology ([#2104](https://github.com/waku-org/nwaku/issues/2104)) ([a47dc9e6](https://github.com/waku-org/nwaku/commit/a47dc9e6))
- **ci:** update the dependency list in pre-release WF ([#2088](https://github.com/waku-org/nwaku/issues/2088)) ([e85f05b0](https://github.com/waku-org/nwaku/commit/e85f05b0))
- **ci:** fix name of discord notify method ([aaf10e08](https://github.com/waku-org/nwaku/commit/aaf10e08))
- update wakuv2 fleet DNS discovery enrtree ([89854a96](https://github.com/waku-org/nwaku/commit/89854a96))
- libwaku.nim: unsubscribe -> unsubscribeAll to make it build properly ([#2082](https://github.com/waku-org/nwaku/issues/2082)) ([3264a4f5](https://github.com/waku-org/nwaku/commit/3264a4f5))
- **archive:** dburl check ([#2071](https://github.com/waku-org/nwaku/issues/2071)) ([a27d005f](https://github.com/waku-org/nwaku/commit/a27d005f))
- filter discv5 bootstrap nodes by shards ([#2073](https://github.com/waku-org/nwaku/issues/2073)) ([d178105d](https://github.com/waku-org/nwaku/commit/d178105d))
- **rln-relay:** segfault when no params except rln-relay are passed in ([#2047](https://github.com/waku-org/nwaku/issues/2047)) ([45fe2d3b](https://github.com/waku-org/nwaku/commit/45fe2d3b))
- **sqlite:** Properly set user_version to 7 so that the migration procedure is not started ([#2031](https://github.com/waku-org/nwaku/issues/2031)) ([aa3e1a66](https://github.com/waku-org/nwaku/commit/aa3e1a66))

### Changes

- remove js-node tests as release candidate dependencies ([#2123](https://github.com/waku-org/nwaku/issues/2123)) ([ce5fb340](https://github.com/waku-org/nwaku/commit/ce5fb340))
- added size based retention policy ([#2098](https://github.com/waku-org/nwaku/issues/2098)) ([25d6e52e](https://github.com/waku-org/nwaku/commit/25d6e52e))
- Clarify running instructions ([#2038](https://github.com/waku-org/nwaku/issues/2038)) ([12e8b122](https://github.com/waku-org/nwaku/commit/12e8b122))
- **rln:** add more hardcoded memberhips to static group ([#2108](https://github.com/waku-org/nwaku/issues/2108)) ([1042cacd](https://github.com/waku-org/nwaku/commit/1042cacd))
- Revert lightpush error handling to allow zero peer publish again succeed ([#2099](https://github.com/waku-org/nwaku/issues/2099)) ([f05528d4](https://github.com/waku-org/nwaku/commit/f05528d4))
- adding NetConfig test suite ([#2091](https://github.com/waku-org/nwaku/issues/2091)) ([23b49ca5](https://github.com/waku-org/nwaku/commit/23b49ca5))
- **cbindings:** Adding cpp example that integrates the 'libwaku' ([#2079](https://github.com/waku-org/nwaku/issues/2079)) ([8455b8dd](https://github.com/waku-org/nwaku/commit/8455b8dd))
- **networkmonitor:** refactor setConnectedPeersMetrics, make it partially concurrent, add version ([#2080](https://github.com/waku-org/nwaku/issues/2080)) ([c5aa9704](https://github.com/waku-org/nwaku/commit/c5aa9704))
- resolving DNS IP and publishing it when no extIp is provided ([#2030](https://github.com/waku-org/nwaku/issues/2030)) ([7797b2cd](https://github.com/waku-org/nwaku/commit/7797b2cd))
- Adding -d:postgres flag when creating a Docker image for release and PRs ([#2076](https://github.com/waku-org/nwaku/issues/2076)) ([7a376f59](https://github.com/waku-org/nwaku/commit/7a376f59))
- Moved external APIs out of node ([#2069](https://github.com/waku-org/nwaku/issues/2069)) ([3e72e830](https://github.com/waku-org/nwaku/commit/3e72e830))
- bump nim-libp2p, nim-toml-serialization, nim-unicodedb, nim-unittest2, nim-websock, nim-zlib, & nimbus-build-system ([#2065](https://github.com/waku-org/nwaku/issues/2065)) ([dc25057a](https://github.com/waku-org/nwaku/commit/dc25057a))
- **ci:** add js-waku as a dependency for pre-release createion ([#2022](https://github.com/waku-org/nwaku/issues/2022)) ([28b04000](https://github.com/waku-org/nwaku/commit/28b04000))
- Updating nim-chronicles, nim-chronos, nim-presto, nimcrypto, nim-libp2p, and nim-nat-transversal ([#2043](https://github.com/waku-org/nwaku/issues/2043)) ([f617cd97](https://github.com/waku-org/nwaku/commit/f617cd97))
- **cbindings:** Thread-safe communication between the main thread and the Waku Thread ([#1978](https://github.com/waku-org/nwaku/issues/1978)) ([72f90663](https://github.com/waku-org/nwaku/commit/72f90663))
- **rln-relay:** logs, updated submodule, leaves_set metric ([#2024](https://github.com/waku-org/nwaku/issues/2024)) ([2e515a06](https://github.com/waku-org/nwaku/commit/2e515a06))
- **release:** update changelog for v0.20.0 release ([#2026](https://github.com/waku-org/nwaku/issues/2026)) ([9085b1b3](https://github.com/waku-org/nwaku/commit/9085b1b3))
- **postgres:** not loading the libpq library by default & better user feedback ([#2028](https://github.com/waku-org/nwaku/issues/2028)) ([e8602021](https://github.com/waku-org/nwaku/commit/e8602021))
- move SubscriptionManager under waku_core  ([#2025](https://github.com/waku-org/nwaku/issues/2025)) ([563b2b20](https://github.com/waku-org/nwaku/commit/563b2b20))
- **README:** List possible WSL Issue ([#1995](https://github.com/waku-org/nwaku/issues/1995)) ([ebe715e9](https://github.com/waku-org/nwaku/commit/ebe715e9))
- **ci:** add js-waku test to pre-release workflow ([#2017](https://github.com/waku-org/nwaku/issues/2017)) ([e8776fd6](https://github.com/waku-org/nwaku/commit/e8776fd6))

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` <br />`/vac/waku/filter-subscribe/2.0.0-beta1` <br />`/vac/waku/filter-push/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation has been removed from this repository and can be found in a separate [Waku Legacy](https://github.com/waku-org/waku-legacy) repository.

## Upgrade instructions

* Note that the `--topic` CLI option is being deprecated in favor of a more specific options `--pubsub-topic` & `--content-topic`. This is the last release supporting the `--topic` option.
* The size-based retention policy has been tested with SQLite storage and is still on validation phases for Postgres

## 2023-09-14 v0.20.0

> Note: IP address 0.0.0.0 is no longer advertised by a node

> Note: Multiple CLI options have been removed in this release, please see _Upgrade instructions_ section for details.

## What's Changed

Release highlights:
* RLN is now part of standard release (is no longer EXPERIMENTAL feature)
* Interop tests between nwaku and js-waku are now gating PRs and releases
* Libwaku has been made more threadsafe (1 out of 3 improvements applied.)
* Added autosharding option on various protocol APIs



### Features

- **rln-relay:** removed rln from experimental 🚀 ([#2001](https://github.com/waku-org/nwaku/issues/2001)) ([645b0343](https://github.com/waku-org/nwaku/commit/645b0343))
- Rest endoint /health for rln ([#2011](https://github.com/waku-org/nwaku/issues/2011)) ([fc6194bb](https://github.com/waku-org/nwaku/commit/fc6194bb))
- **rln_db_inspector:** create rln_db_inspector tool ([#1999](https://github.com/waku-org/nwaku/issues/1999)) ([ec42e2c7](https://github.com/waku-org/nwaku/commit/ec42e2c7))
- **relay:** ordered validator execution ([#1966](https://github.com/waku-org/nwaku/issues/1966)) ([debc5f19](https://github.com/waku-org/nwaku/commit/debc5f19))
- **discv5:** topic subscriptions update discv5 filter predicate ([#1918](https://github.com/waku-org/nwaku/issues/1918)) ([4539dfc7](https://github.com/waku-org/nwaku/commit/4539dfc7))
- topic subscriptions updates discv5 ENR ([#1875](https://github.com/waku-org/nwaku/issues/1875)) ([c369b329](https://github.com/waku-org/nwaku/commit/c369b329))
- **rln_keystore_generator:** wired to onchain group manager ([#1931](https://github.com/waku-org/nwaku/issues/1931)) ([c9b48ea1](https://github.com/waku-org/nwaku/commit/c9b48ea1))
- **rln:** init rln_keystore_generator ([#1925](https://github.com/waku-org/nwaku/issues/1925)) ([3d849541](https://github.com/waku-org/nwaku/commit/3d849541))
- update various protocols to autoshard ([#1857](https://github.com/waku-org/nwaku/issues/1857)) ([cf301396](https://github.com/waku-org/nwaku/commit/cf301396))

### Bug Fixes

- **rln-relay:** waku_rln_number_registered_memberships metrics appropriately handled ([#2018](https://github.com/waku-org/nwaku/issues/2018)) ([a4e78330](https://github.com/waku-org/nwaku/commit/a4e78330))
- prevent IP 0.0.0.0 from being published and update peers with empty ENR data ([#1982](https://github.com/waku-org/nwaku/issues/1982)) ([47ae19c1](https://github.com/waku-org/nwaku/commit/47ae19c1))
- **rln-relay:** missed roots during sync ([#2015](https://github.com/waku-org/nwaku/issues/2015)) ([21604e6b](https://github.com/waku-org/nwaku/commit/21604e6b))
- **p2p:** fix possible connectivity issue ([#1996](https://github.com/waku-org/nwaku/issues/1996)) ([7d9d8a3f](https://github.com/waku-org/nwaku/commit/7d9d8a3f))
- **rln-db-inspector:** use valueOr pattern ([#2012](https://github.com/waku-org/nwaku/issues/2012)) ([a8095d87](https://github.com/waku-org/nwaku/commit/a8095d87))
- **tests:** relay tests use random port to avoid conflict ([#1998](https://github.com/waku-org/nwaku/issues/1998)) ([b991682b](https://github.com/waku-org/nwaku/commit/b991682b))
- **ci:** incorrect use of braces ([#1987](https://github.com/waku-org/nwaku/issues/1987)) ([4ed41457](https://github.com/waku-org/nwaku/commit/4ed41457))
- **Makefile:** invalid path to crate build ([#1981](https://github.com/waku-org/nwaku/issues/1981)) ([1a318c29](https://github.com/waku-org/nwaku/commit/1a318c29))
- --topic should be ignore when using --pubsub-topic or --content-topic ([#1977](https://github.com/waku-org/nwaku/issues/1977)) ([037b1662](https://github.com/waku-org/nwaku/commit/037b1662))
- **tests:** fix flaky test ([#1972](https://github.com/waku-org/nwaku/issues/1972)) ([f262397d](https://github.com/waku-org/nwaku/commit/f262397d))
- **rln-relay:** deserialization of valid merkle roots ([#1973](https://github.com/waku-org/nwaku/issues/1973)) ([d262837e](https://github.com/waku-org/nwaku/commit/d262837e))
- **ci:** rename tools artifact to prevent conflict ([#1971](https://github.com/waku-org/nwaku/issues/1971)) ([26c06b27](https://github.com/waku-org/nwaku/commit/26c06b27))
- **Makefile:** rln was enabled by default ([#1964](https://github.com/waku-org/nwaku/issues/1964)) ([9b1d2904](https://github.com/waku-org/nwaku/commit/9b1d2904))
- **rln-relay:** modify keystore credentials logic ([#1956](https://github.com/waku-org/nwaku/issues/1956)) ([e7b2b88f](https://github.com/waku-org/nwaku/commit/e7b2b88f))
- **Makefile:** error out if rln-keystore-generator not compiled with rln flag ([#1960](https://github.com/waku-org/nwaku/issues/1960)) ([ac258550](https://github.com/waku-org/nwaku/commit/ac258550))
- **rln-relay:** sync from deployed block number ([#1955](https://github.com/waku-org/nwaku/issues/1955)) ([bd3be219](https://github.com/waku-org/nwaku/commit/bd3be219))
- **rln-relay:** window of acceptable roots synced to rln metadata ([#1953](https://github.com/waku-org/nwaku/issues/1953)) ([01634f57](https://github.com/waku-org/nwaku/commit/01634f57))
- **rln-relay:** bump zerokit to v0.3.2 ([#1951](https://github.com/waku-org/nwaku/issues/1951)) ([32aa1c5b](https://github.com/waku-org/nwaku/commit/32aa1c5b))
- **rln-relay:** flush_interval incorrectly set ([#1933](https://github.com/waku-org/nwaku/issues/1933)) ([c07d63db](https://github.com/waku-org/nwaku/commit/c07d63db))
- **rln-relay:** RLN DB should be aware of chain and contract address ([#1932](https://github.com/waku-org/nwaku/issues/1932)) ([1ae5b5a9](https://github.com/waku-org/nwaku/commit/1ae5b5a9))
- **rln-relay:** waitFor startup, otherwise valid proofs will be marked invalid ([#1920](https://github.com/waku-org/nwaku/issues/1920)) ([6c6302f9](https://github.com/waku-org/nwaku/commit/6c6302f9))
- **test:** fix flaky rln test ([#1923](https://github.com/waku-org/nwaku/issues/1923)) ([0ac8a7f0](https://github.com/waku-org/nwaku/commit/0ac8a7f0))
- **rln-relay:** remove registration capability ([#1916](https://github.com/waku-org/nwaku/issues/1916)) ([f08315cd](https://github.com/waku-org/nwaku/commit/f08315cd))
- **rln-relay:** invalid start index being set results in invalid proofs  ([#1915](https://github.com/waku-org/nwaku/issues/1915)) ([b3bb7a11](https://github.com/waku-org/nwaku/commit/b3bb7a11))
- **rln-relay:** should error out on rln-relay mount failure ([#1904](https://github.com/waku-org/nwaku/issues/1904)) ([8c568cab](https://github.com/waku-org/nwaku/commit/8c568cab))
- **rln-relay:** timeout on macos runners, use fixed version of ganache ([#1913](https://github.com/waku-org/nwaku/issues/1913)) ([c9772af0](https://github.com/waku-org/nwaku/commit/c9772af0))
- no enr record in chat2 ([#1907](https://github.com/waku-org/nwaku/issues/1907)) ([fc604ca5](https://github.com/waku-org/nwaku/commit/fc604ca5))

### Changes

- **ci:** add js-waku test to pre-release workflow ([#2017](https://github.com/waku-org/nwaku/issues/2017)) ([e8776fd6](https://github.com/waku-org/nwaku/commit/e8776fd6))
- **rln-relay:** updated docs ([#1993](https://github.com/waku-org/nwaku/issues/1993)) ([76e34077](https://github.com/waku-org/nwaku/commit/76e34077))
- **ci:** execute js-waku integration tests on image build ([#2006](https://github.com/waku-org/nwaku/issues/2006)) ([5d976df9](https://github.com/waku-org/nwaku/commit/5d976df9))
- **rln-relay:** add isReady check ([#1989](https://github.com/waku-org/nwaku/issues/1989)) ([5638bd06](https://github.com/waku-org/nwaku/commit/5638bd06))
- **rln-relay:** clean up nullifier table every MaxEpochGap ([#1994](https://github.com/waku-org/nwaku/issues/1994)) ([483f40c8](https://github.com/waku-org/nwaku/commit/483f40c8))
- **ci:** use commit instead of master for docker image ([#1990](https://github.com/waku-org/nwaku/issues/1990)) ([98850192](https://github.com/waku-org/nwaku/commit/98850192))
- **rln-relay:** log levels for certain logs ([#1986](https://github.com/waku-org/nwaku/issues/1986)) ([97a7c9d0](https://github.com/waku-org/nwaku/commit/97a7c9d0))
- **rln-relay:** use the only key from keystore if only 1 exists ([#1984](https://github.com/waku-org/nwaku/issues/1984)) ([a14c3261](https://github.com/waku-org/nwaku/commit/a14c3261))
- **ci:** enable experimental for the PR image builds ([#1976](https://github.com/waku-org/nwaku/issues/1976)) ([1b835b4e](https://github.com/waku-org/nwaku/commit/1b835b4e))
- **rln-relay:** confirm that the provided credential is correct using onchain query ([#1980](https://github.com/waku-org/nwaku/issues/1980)) ([be48891f](https://github.com/waku-org/nwaku/commit/be48891f))
- **api:** validate rln message before sending (rest + rpc) ([#1968](https://github.com/waku-org/nwaku/issues/1968)) ([05c98864](https://github.com/waku-org/nwaku/commit/05c98864))
- **cbindings:** Thread-safe libwaku. WakuNode instance created directly from the Waku Thread ([#1957](https://github.com/waku-org/nwaku/issues/1957)) ([68e8d9a7](https://github.com/waku-org/nwaku/commit/68e8d9a7))
- add debug log indicating succesful message pushes and also log the message hash ([#1965](https://github.com/waku-org/nwaku/issues/1965)) ([e272bec9](https://github.com/waku-org/nwaku/commit/e272bec9))
- **rln-keystore-generator:** log out the membership index upon registration ([#1963](https://github.com/waku-org/nwaku/issues/1963)) ([7d53aec1](https://github.com/waku-org/nwaku/commit/7d53aec1))
- **rln-relay:** integrate waku rln registry ([#1943](https://github.com/waku-org/nwaku/issues/1943)) ([cc9f8d42](https://github.com/waku-org/nwaku/commit/cc9f8d42))
- **ci:** add a job checking config options and db schema ([#1927](https://github.com/waku-org/nwaku/issues/1927)) ([505d1967](https://github.com/waku-org/nwaku/commit/505d1967))
- **rln_keystore_generator:** generate and persist credentials ([#1928](https://github.com/waku-org/nwaku/issues/1928)) ([07945a37](https://github.com/waku-org/nwaku/commit/07945a37))
- **rln-relay:** rename keystore application to waku-rln-relay ([#1924](https://github.com/waku-org/nwaku/issues/1924)) ([8239b455](https://github.com/waku-org/nwaku/commit/8239b455))
- **rln:** remove old and add new rln metric ([#1926](https://github.com/waku-org/nwaku/issues/1926)) ([56c228f8](https://github.com/waku-org/nwaku/commit/56c228f8))
- **rln:** run rln in all relay pubsubtopics + remove cli flags ([#1917](https://github.com/waku-org/nwaku/issues/1917)) ([af95b571](https://github.com/waku-org/nwaku/commit/af95b571))
- **release:** update changelog for delayed v0.19.0 release ([#1911](https://github.com/waku-org/nwaku/issues/1911)) ([78690787](https://github.com/waku-org/nwaku/commit/78690787))

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` <br />`/vac/waku/filter-subscribe/2.0.0-beta1` <br />`/vac/waku/filter-push/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation has been removed from this repository and can be found in a separate [Waku Legacy](https://github.com/waku-org/waku-legacy) repository.

## Upgrade instructions

* Note that the `--topic` CLI option is being deprecated in favor of a more specific options `--pubsub-topic` & `--content-topic`. The `--topic` option will be available for next release with a deprecation note.
* CLI option `--store-resume-peer` has been removed.
* Following options related to RLN have been removed:
  * `--rln-relay-membership-group-index`
  * `--rln-relay-pubsub-topic`
  * `--rln-relay-content-topic`


## 2023-08-16 v0.19.0

> Note that the `--topic` CLI option is being deprecated in favor a more specific option `--pubsub-topic`.

> The Waku v1 implementation has been removed from this repository and can be found in a separate [Waku Legacy](https://github.com/waku-org/waku-legacy) repository.


## What's Changed

Release highlights:
* Improved connection management, including management for non-relay peers and limiting the number of connections from a single IP
* Postgres support has been added as a backend for archive module
* RLN initialization optimizations
* Update to the latest nim-libp2p
* Removed Waku v1 and also references to `v2` from the current version
* Basic implementation of Autosharding for the Waku Network
* REST API implementation for Filter protocol

### Features

- **ci:** add docker image builds per PR ([#1881](https://github.com/waku-org/nwaku/issues/1881)) ([84f94d5d](https://github.com/waku-org/nwaku/commit/84f94d5d))
- Rest API interface for legacy (v1) filter service.  ([#1851](https://github.com/waku-org/nwaku/issues/1851)) ([08ff6672](https://github.com/waku-org/nwaku/commit/08ff6672))
- autosharding content topics in config ([#1856](https://github.com/waku-org/nwaku/issues/1856)) ([afb93e29](https://github.com/waku-org/nwaku/commit/afb93e29))
- autosharding core algorithm ([#1854](https://github.com/waku-org/nwaku/issues/1854)) ([bbff1ac1](https://github.com/waku-org/nwaku/commit/bbff1ac1))
- **cbindings:** tiny waku relay example in Python ([#1793](https://github.com/waku-org/nwaku/issues/1793)) ([0b2cfae5](https://github.com/waku-org/nwaku/commit/0b2cfae5))
- **rln-relay:** close db connection appropriately ([#1858](https://github.com/waku-org/nwaku/issues/1858)) ([76c73b62](https://github.com/waku-org/nwaku/commit/76c73b62))
- enable TcpNoDelay ([#1470](https://github.com/waku-org/nwaku/issues/1470)) ([08f3bba3](https://github.com/waku-org/nwaku/commit/08f3bba3))
- limit relay connections below max conns ([#1813](https://github.com/waku-org/nwaku/issues/1813)) ([17b24cde](https://github.com/waku-org/nwaku/commit/17b24cde))
- **postgres:** integration of postgres in wakunode2 ([#1808](https://github.com/waku-org/nwaku/issues/1808)) ([88b7481f](https://github.com/waku-org/nwaku/commit/88b7481f))
- discovery peer filtering for relay shard ([#1804](https://github.com/waku-org/nwaku/issues/1804)) ([a4da87bb](https://github.com/waku-org/nwaku/commit/a4da87bb))
- **rln-relay:** resume onchain sync from persisted tree db ([#1805](https://github.com/waku-org/nwaku/issues/1805)) ([bbded9ee](https://github.com/waku-org/nwaku/commit/bbded9ee))
- **rln-relay:** metadata ffi api ([#1803](https://github.com/waku-org/nwaku/issues/1803)) ([045f07c6](https://github.com/waku-org/nwaku/commit/045f07c6))

### Bug Fixes

- bring back default topic in config ([#1902](https://github.com/waku-org/nwaku/issues/1902)) ([d5d2243c](https://github.com/waku-org/nwaku/commit/d5d2243c))
- **ci:** only add comment on PR and do not duplicate it ([#1908](https://github.com/waku-org/nwaku/issues/1908)) ([b785b6ba](https://github.com/waku-org/nwaku/commit/b785b6ba))
- **ci:** add mising OS arch option to image build ([#1905](https://github.com/waku-org/nwaku/issues/1905)) ([2575f3c4](https://github.com/waku-org/nwaku/commit/2575f3c4))
- **wakucanary:** add missing return on timeout ([#1901](https://github.com/waku-org/nwaku/issues/1901)) ([7dce0b9e](https://github.com/waku-org/nwaku/commit/7dce0b9e))
- fixes out of bounds crash when waku2 is not set ([#1895](https://github.com/waku-org/nwaku/issues/1895)) ([03363f1b](https://github.com/waku-org/nwaku/commit/03363f1b))
- **wakucanary:** add enr record to builder ([#1882](https://github.com/waku-org/nwaku/issues/1882)) ([831a093f](https://github.com/waku-org/nwaku/commit/831a093f))
- check nil before calling clearTimer ([#1869](https://github.com/waku-org/nwaku/issues/1869)) ([2fc48842](https://github.com/waku-org/nwaku/commit/2fc48842))
- **rln-relay:** mark duplicated messages as spam ([#1867](https://github.com/waku-org/nwaku/issues/1867)) ([4756ccc1](https://github.com/waku-org/nwaku/commit/4756ccc1))
- **ci:** do not depend on number of procesors with job name ([#1863](https://github.com/waku-org/nwaku/issues/1863)) ([c560af11](https://github.com/waku-org/nwaku/commit/c560af11))
- **libp2p:** Updating nim-libp2p to fix the `wss` connectivity issue ([#1848](https://github.com/waku-org/nwaku/issues/1848)) ([1d3410c7](https://github.com/waku-org/nwaku/commit/1d3410c7))
- **rln-relay:** chunk event fetching ([#1830](https://github.com/waku-org/nwaku/issues/1830)) ([e4d9ee1f](https://github.com/waku-org/nwaku/commit/e4d9ee1f))
- **discv5:** Fixing issue that prevented the wakunode2 from starting ([#1829](https://github.com/waku-org/nwaku/issues/1829)) ([3aefade6](https://github.com/waku-org/nwaku/commit/3aefade6))
- sanity-check the docker image start ([ae05f0a8](https://github.com/waku-org/nwaku/commit/ae05f0a8))
- **ci:** fix broken test with wrong import ([#1820](https://github.com/waku-org/nwaku/issues/1820)) ([4573e8c5](https://github.com/waku-org/nwaku/commit/4573e8c5))
- temporary fix to disable default experimental builds on fleets ([#1810](https://github.com/waku-org/nwaku/issues/1810)) ([e9028618](https://github.com/waku-org/nwaku/commit/e9028618))
- **rln-relay:** tree race condition upon initialization ([#1807](https://github.com/waku-org/nwaku/issues/1807)) ([f8e270fb](https://github.com/waku-org/nwaku/commit/f8e270fb))
- fix mac docker build alpine version ([#1801](https://github.com/waku-org/nwaku/issues/1801)) ([fce845bb](https://github.com/waku-org/nwaku/commit/fce845bb))
- **rln-relay:** flaky static group manager test ([#1798](https://github.com/waku-org/nwaku/issues/1798)) ([0e9ecbd6](https://github.com/waku-org/nwaku/commit/0e9ecbd6))

### Changes

- remove references to v2 ([#1898](https://github.com/waku-org/nwaku/issues/1898)) ([b9d5d28a](https://github.com/waku-org/nwaku/commit/b9d5d28a))
- **submodules:** use zerokit v0.3.1 only ([#1886](https://github.com/waku-org/nwaku/issues/1886)) ([311f5ea0](https://github.com/waku-org/nwaku/commit/311f5ea0))
- remove Waku v1 and wakubridge code ([#1874](https://github.com/waku-org/nwaku/issues/1874)) ([ab344a9d](https://github.com/waku-org/nwaku/commit/ab344a9d))
- **cbindings:** libwaku - run waku node in a secondary working thread  ([#1865](https://github.com/waku-org/nwaku/issues/1865)) ([069c1ad2](https://github.com/waku-org/nwaku/commit/069c1ad2))
- update docs link ([#1850](https://github.com/waku-org/nwaku/issues/1850)) ([d2b6075b](https://github.com/waku-org/nwaku/commit/d2b6075b))
- **changelog:** release notes for v0.19.0 ([#1861](https://github.com/waku-org/nwaku/issues/1861)) ([32c1276f](https://github.com/waku-org/nwaku/commit/32c1276f))
- **rln-relay:** verify proofs based on bandwidth usage ([#1844](https://github.com/waku-org/nwaku/issues/1844)) ([3fe4522a](https://github.com/waku-org/nwaku/commit/3fe4522a))
- **rln-relay:** bump zerokit ([#1838](https://github.com/waku-org/nwaku/issues/1838)) ([4f0bdf9a](https://github.com/waku-org/nwaku/commit/4f0bdf9a))
- bump nim-libp2p to 224f92e ([661638da](https://github.com/waku-org/nwaku/commit/661638da))
- **refactor:** Move record creation & fix libwaku compilation ([#1833](https://github.com/waku-org/nwaku/issues/1833)) ([97d3b9f7](https://github.com/waku-org/nwaku/commit/97d3b9f7))
- discv5 re-org clean-up ([#1823](https://github.com/waku-org/nwaku/issues/1823)) ([cf46fb7c](https://github.com/waku-org/nwaku/commit/cf46fb7c))
- **networking:** disconnect due to colocation ip in conn handler ([#1821](https://github.com/waku-org/nwaku/issues/1821)) ([e12c979c](https://github.com/waku-org/nwaku/commit/e12c979c))
- **rln-relay:** bump zerokit for version fix ([#1822](https://github.com/waku-org/nwaku/issues/1822)) ([add294a9](https://github.com/waku-org/nwaku/commit/add294a9))
- move discv5 out of node. ([#1818](https://github.com/waku-org/nwaku/issues/1818)) ([62d36530](https://github.com/waku-org/nwaku/commit/62d36530))
- **archive:** Moving waku archive logic from app.nim to the archive module ([#1817](https://github.com/waku-org/nwaku/issues/1817)) ([52894a82](https://github.com/waku-org/nwaku/commit/52894a82))
- add peer manager config to builder ([#1816](https://github.com/waku-org/nwaku/issues/1816)) ([71c4ac16](https://github.com/waku-org/nwaku/commit/71c4ac16))
- discv5 re-org setup ([#1815](https://github.com/waku-org/nwaku/issues/1815)) ([44f9d8dc](https://github.com/waku-org/nwaku/commit/44f9d8dc))
- **databases:** Creation of the databases folder to keep the logic for sqlite and postgres ([#1811](https://github.com/waku-org/nwaku/issues/1811)) ([a44d4bfb](https://github.com/waku-org/nwaku/commit/a44d4bfb))
- **deps:** bump libp2p & websock ([#1800](https://github.com/waku-org/nwaku/issues/1800)) ([f6e89c31](https://github.com/waku-org/nwaku/commit/f6e89c31))

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` <br />`/vac/waku/filter-subscribe/2.0.0-beta1` <br />`/vac/waku/filter-push/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation has been removed from this repository and can be found in a separate [Waku Legacy](https://github.com/waku-org/waku-legacy) repository.

## Upgrade instructions

* Note that the `--topic` CLI option is being deprecated in favor a more specific option `--pubsub-topic`. The `--topic` option will be available for next 2 releases with a deprecation note.

## 2023-06-14 v0.18.0

> Note that there is a new naming scheme for release artifacts.

## What's Changed

Release highlights:
* Support for Gossipsub scoring
* [Rendezvous discovery protocol](https://docs.libp2p.io/concepts/discovery-routing/rendezvous/) enabled by default with relay
* Initial support for postgresql as Store backend
* Atomic operations for insertions and deletions included in rln-relay

### Features

- **postgres:** complete implementation of driver and apply more tests ([#1785](https://github.com/waku-org/nwaku/issues/1785)) ([5fc5770d](https://github.com/waku-org/nwaku/commit/5fc5770d))
- **postgres:** adding a postgres async pool to make the db interactions asynchronous ([#1779](https://github.com/waku-org/nwaku/issues/1779)) ([cb2e3d86](https://github.com/waku-org/nwaku/commit/cb2e3d86))
- **rln-relay:** pass in index to keystore credentials ([#1777](https://github.com/waku-org/nwaku/issues/1777)) ([a00aa8cc](https://github.com/waku-org/nwaku/commit/a00aa8cc))
- **networking:** integrate gossipsub scoring ([#1769](https://github.com/waku-org/nwaku/issues/1769)) ([34a92631](https://github.com/waku-org/nwaku/commit/34a92631))
- **discv5:** added find random nodes with predicate ([#1762](https://github.com/waku-org/nwaku/issues/1762)) ([#1763](https://github.com/waku-org/nwaku/issues/1763)) ([21737c7c](https://github.com/waku-org/nwaku/commit/21737c7c))
- **wakunode2:** enable libp2p rendezvous protocol by default ([#1770](https://github.com/waku-org/nwaku/issues/1770)) ([835a409d](https://github.com/waku-org/nwaku/commit/835a409d))
- **postgresql:** align previous work's PR[#1590](https://github.com/waku-org/nwaku/issues/1590) changes into master ([#1764](https://github.com/waku-org/nwaku/issues/1764)) ([7df6f4c8](https://github.com/waku-org/nwaku/commit/7df6f4c8))
- **networking:** prune peers from same ip beyond collocation limit ([#1765](https://github.com/waku-org/nwaku/issues/1765)) ([047d1cf0](https://github.com/waku-org/nwaku/commit/047d1cf0))
- **ci:** add nightly builds ([#1758](https://github.com/waku-org/nwaku/issues/1758)) ([473af70a](https://github.com/waku-org/nwaku/commit/473af70a))
- **postgresql:** 1st commit to async sql (waku_archive/driver...) ([#1755](https://github.com/waku-org/nwaku/issues/1755)) ([59ca03a8](https://github.com/waku-org/nwaku/commit/59ca03a8))
- **ci:** add release-notes target ([#1734](https://github.com/waku-org/nwaku/issues/1734)) ([ceb54b18](https://github.com/waku-org/nwaku/commit/ceb54b18))
- **rln-relay:** use new atomic_operation ffi api ([#1733](https://github.com/waku-org/nwaku/issues/1733)) ([611e9539](https://github.com/waku-org/nwaku/commit/611e9539))

### Bug Fixes

- **ci:** enforce basic CPU instruction set to prevent CI issues ([#1759](https://github.com/waku-org/nwaku/issues/1759)) ([35520bd0](https://github.com/waku-org/nwaku/commit/35520bd0))
- **test:** wait more for gossip ([#1753](https://github.com/waku-org/nwaku/issues/1753)) ([0fce3d83](https://github.com/waku-org/nwaku/commit/0fce3d83))
- **rln-relay:** keystore usage ([#1750](https://github.com/waku-org/nwaku/issues/1750)) ([36266b43](https://github.com/waku-org/nwaku/commit/36266b43))
- **ci:** fix flaky test for dos topic ([#1747](https://github.com/waku-org/nwaku/issues/1747)) ([46e231d0](https://github.com/waku-org/nwaku/commit/46e231d0))
- **rln-relay:** trace log ([#1743](https://github.com/waku-org/nwaku/issues/1743)) ([5eae60e8](https://github.com/waku-org/nwaku/commit/5eae60e8))
- **ci:** make experimental default to true in fleet deployment ([#1742](https://github.com/waku-org/nwaku/issues/1742)) ([b148c305](https://github.com/waku-org/nwaku/commit/b148c305))

### Changes

- **rln:** bump zerokit ([#1787](https://github.com/waku-org/nwaku/issues/1787)) ([9c04b59b](https://github.com/waku-org/nwaku/commit/9c04b59b))
- **ci:** extend and rename nightly workflow to support RC builds ([#1784](https://github.com/waku-org/nwaku/issues/1784)) ([96074071](https://github.com/waku-org/nwaku/commit/96074071))
- **rln-relay:** pass in the path to the tree db ([#1782](https://github.com/waku-org/nwaku/issues/1782)) ([dba84248](https://github.com/waku-org/nwaku/commit/dba84248))
- **rln-relay:** update tree_config ([#1781](https://github.com/waku-org/nwaku/issues/1781)) ([ba8ec704](https://github.com/waku-org/nwaku/commit/ba8ec704))
- **ci:** properly set os and architecture for nightly and release ([#1780](https://github.com/waku-org/nwaku/issues/1780)) ([44bcf0f2](https://github.com/waku-org/nwaku/commit/44bcf0f2))
- **ci:** remove add-to-project workflow ([#1778](https://github.com/waku-org/nwaku/issues/1778)) ([a9505892](https://github.com/waku-org/nwaku/commit/a9505892))
- **ci:** add experimental builds to nightly ([#1761](https://github.com/waku-org/nwaku/issues/1761)) ([ffac7761](https://github.com/waku-org/nwaku/commit/ffac7761))
- **px:** close px streams after resp is sent ([#1746](https://github.com/waku-org/nwaku/issues/1746)) ([3c2d2891](https://github.com/waku-org/nwaku/commit/3c2d2891))
- **docs:** fix docs and mark some as deprecated ([#1754](https://github.com/waku-org/nwaku/issues/1754)) ([b51fb616](https://github.com/waku-org/nwaku/commit/b51fb616))
- **makefile:** unify where chronicles_log_level is set ([#1748](https://github.com/waku-org/nwaku/issues/1748)) ([39902dc2](https://github.com/waku-org/nwaku/commit/39902dc2))
- **rln-relay:** docs and config update for testnet 3 ([#1738](https://github.com/waku-org/nwaku/issues/1738)) ([bb9d231b](https://github.com/waku-org/nwaku/commit/bb9d231b))
- **rln-relay:** update metrics dashboard ([#1745](https://github.com/waku-org/nwaku/issues/1745)) ([0ced2195](https://github.com/waku-org/nwaku/commit/0ced2195))
- **rln-relay:** updated metrics for testnet 3 ([#1744](https://github.com/waku-org/nwaku/issues/1744)) ([62578746](https://github.com/waku-org/nwaku/commit/62578746))
- **networking:** set and use target outbound connections + prune ([#1739](https://github.com/waku-org/nwaku/issues/1739)) ([87f694a8](https://github.com/waku-org/nwaku/commit/87f694a8))
- proper use of setupNat ([#1740](https://github.com/waku-org/nwaku/issues/1740)) ([665484c1](https://github.com/waku-org/nwaku/commit/665484c1))

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` <br />`/vac/waku/filter-subscribe/2.0.0-beta1` <br />`/vac/waku/filter-push/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## Upgrade instructions

There is a new naming scheme for release artifacts - `nwaku-${ARCHITECTURE}-${OS}-${VERSION}.tar.gz`. If you use any automation to download latest release, you may need to update it.

The `--topics` config option has been deprecated to unify the configuration style. It is still available in this release but will be removed in the next one. The new option `--topic` is introduced, which can be used repeatedly to achieve the same behavior.

## 2023-05-17 v0.17.0

> Note that the --topics config item has been deprecated and support will be dropped in future releases. To configure support for multiple pubsub topics, use the new --topic parameter repeatedly.

## What's Changed

Release highlights:
* New REST API for Waku Store protocol.
* New Filter protocol implentation. See [12/WAKU2-FILTER](https://rfc.vac.dev/spec/12/).
* Initial C bindings support.
* Support for Heaptrack to investigate memory utilization ([tutorial](https://github.com/waku-org/nwaku/blob/master/docs/tutorial/heaptrack.md)).

### Features

- **cbindings:** first commit - waku relay ([#1632](https://github.com/waku-org/nwaku/issues/1632)) ([#1714](https://github.com/waku-org/nwaku/issues/1714)) ([2defbd23](https://github.com/waku-org/nwaku/commit/2defbd23))
- example using filter and lightpush ([#1720](https://github.com/waku-org/nwaku/issues/1720)) ([8987d4a3](https://github.com/waku-org/nwaku/commit/8987d4a3))
- configure protected topics via cli ([#1696](https://github.com/waku-org/nwaku/issues/1696)) ([16b44523](https://github.com/waku-org/nwaku/commit/16b44523))
- **mem-analysis:** Adding Dockerfile_with_heaptrack ([#1681](https://github.com/waku-org/nwaku/issues/1681)) ([9b9172ab](https://github.com/waku-org/nwaku/commit/9b9172ab))
- add metrics with msg size histogram ([#1697](https://github.com/waku-org/nwaku/issues/1697)) ([67e96ba8](https://github.com/waku-org/nwaku/commit/67e96ba8))
- curate peers shared over px protocol ([#1671](https://github.com/waku-org/nwaku/issues/1671)) ([14305c61](https://github.com/waku-org/nwaku/commit/14305c61))
- **enr:** added support for relay shards field ([96162536](https://github.com/waku-org/nwaku/commit/96162536))
- add tools maket target and build tools in CI ([#1668](https://github.com/waku-org/nwaku/issues/1668)) ([d5979e94](https://github.com/waku-org/nwaku/commit/d5979e94))
- integrate new filter protocol, other improvements ([#1637](https://github.com/waku-org/nwaku/issues/1637)) ([418efca2](https://github.com/waku-org/nwaku/commit/418efca2))
- **rest-api-store:** new rest api to retrieve store waku messages ([#1611](https://github.com/waku-org/nwaku/issues/1611)) ([#1630](https://github.com/waku-org/nwaku/issues/1630)) ([b2acb54d](https://github.com/waku-org/nwaku/commit/b2acb54d))
- **node:** added waku node builder type ([e931fa5d](https://github.com/waku-org/nwaku/commit/e931fa5d))
- dos protected topic relay msgs based on meta field ([#1614](https://github.com/waku-org/nwaku/issues/1614)) ([c26dcb2b](https://github.com/waku-org/nwaku/commit/c26dcb2b))
- further filter improvements ([#1617](https://github.com/waku-org/nwaku/issues/1617)) ([d920b973](https://github.com/waku-org/nwaku/commit/d920b973))
- **common:** added extensible implementation of the enr typed record ([ac56e1dc](https://github.com/waku-org/nwaku/commit/ac56e1dc))
- **rln-relay:** fetch release from zerokit ci, or build ([#1603](https://github.com/waku-org/nwaku/issues/1603)) ([179be681](https://github.com/waku-org/nwaku/commit/179be681))
- **filter-v2:** new filter protocol increment - message handling and clients ([#1600](https://github.com/waku-org/nwaku/issues/1600)) ([be446b98](https://github.com/waku-org/nwaku/commit/be446b98))

### Fixes

- **ci:** remove target flag from docker command ([#1725](https://github.com/waku-org/nwaku/issues/1725)) ([d822cdc5](https://github.com/waku-org/nwaku/commit/d822cdc5))
- wakunode2 config. adding new 'topic' config parameter. ([#1727](https://github.com/waku-org/nwaku/issues/1727)) ([2ec9809c](https://github.com/waku-org/nwaku/commit/2ec9809c))
- streams was used instead of connections ([#1722](https://github.com/waku-org/nwaku/issues/1722)) ([b9e0763e](https://github.com/waku-org/nwaku/commit/b9e0763e))
- change filter request default behaviour to ping ([#1721](https://github.com/waku-org/nwaku/issues/1721)) ([7c39be9a](https://github.com/waku-org/nwaku/commit/7c39be9a))
- **rln-relay:** handle invalid deletes ([#1717](https://github.com/waku-org/nwaku/issues/1717)) ([81dffee8](https://github.com/waku-org/nwaku/commit/81dffee8))
- fix filter v2 proto fields ([#1716](https://github.com/waku-org/nwaku/issues/1716)) ([68a39c65](https://github.com/waku-org/nwaku/commit/68a39c65))
- unstable peers in mesh ([#1710](https://github.com/waku-org/nwaku/issues/1710)) ([703c3ab5](https://github.com/waku-org/nwaku/commit/703c3ab5))
- **networkmonitor:** break import dependency with wakunode2 app ([043feacd](https://github.com/waku-org/nwaku/commit/043feacd))
- import nimchronos instead heartbeat ([#1695](https://github.com/waku-org/nwaku/issues/1695)) ([7d12adf6](https://github.com/waku-org/nwaku/commit/7d12adf6))
- **rest:** change rest server result error type to string ([d5ef9331](https://github.com/waku-org/nwaku/commit/d5ef9331))
- **rln-relay:** scope of getEvents ([#1672](https://github.com/waku-org/nwaku/issues/1672)) ([b62193e5](https://github.com/waku-org/nwaku/commit/b62193e5))
- **logs:** fix log reporting wrong ok connected peers ([#1675](https://github.com/waku-org/nwaku/issues/1675)) ([1a885b96](https://github.com/waku-org/nwaku/commit/1a885b96))
- move canBeConnected to PeerManager and check for potential overflow ([#1670](https://github.com/waku-org/nwaku/issues/1670)) ([d5c2770c](https://github.com/waku-org/nwaku/commit/d5c2770c))
- wrap untracked protocol handler exceptions ([9e1432c9](https://github.com/waku-org/nwaku/commit/9e1432c9))
- **wakunode2:** made setup nat return errors ([1cfb251b](https://github.com/waku-org/nwaku/commit/1cfb251b))
- fixed multiple bare except warnings ([caf78249](https://github.com/waku-org/nwaku/commit/caf78249))
- bump libp2p with traffic metrics fix ([#1642](https://github.com/waku-org/nwaku/issues/1642)) ([0ef46673](https://github.com/waku-org/nwaku/commit/0ef46673))
- **rln-relay:** buildscript bad cp ([#1636](https://github.com/waku-org/nwaku/issues/1636)) ([bd9857c1](https://github.com/waku-org/nwaku/commit/bd9857c1))
- **wakunode2:** fix main warnings and drop swap support ([f95147f5](https://github.com/waku-org/nwaku/commit/f95147f5))
- **rln-relay:** on chain registration ([#1627](https://github.com/waku-org/nwaku/issues/1627)) ([b1bafda2](https://github.com/waku-org/nwaku/commit/b1bafda2))
- connect instead of dialing relay peers ([#1622](https://github.com/waku-org/nwaku/issues/1622)) ([85f33a8e](https://github.com/waku-org/nwaku/commit/85f33a8e))
- fix hash size greater than 32 ([#1621](https://github.com/waku-org/nwaku/issues/1621)) ([c42ac16f](https://github.com/waku-org/nwaku/commit/c42ac16f))

### Changes

- **ci:** cache all of submodules/deps to speed up build time ([#1731](https://github.com/waku-org/nwaku/issues/1731)) ([4394c69d](https://github.com/waku-org/nwaku/commit/4394c69d))
- **rln-relay:** update args to contract ([#1724](https://github.com/waku-org/nwaku/issues/1724)) ([b277ce10](https://github.com/waku-org/nwaku/commit/b277ce10))
- **rln-relay:** use new config for ffi ([#1718](https://github.com/waku-org/nwaku/issues/1718)) ([44c54312](https://github.com/waku-org/nwaku/commit/44c54312))
- adding new tutorial on how to handle heaptrack with nim waku ([#1719](https://github.com/waku-org/nwaku/issues/1719)) ([4b59e472](https://github.com/waku-org/nwaku/commit/4b59e472))
- add timestamp and ephemeral for opt-in dos validator ([#1713](https://github.com/waku-org/nwaku/issues/1713)) ([3e0a693d](https://github.com/waku-org/nwaku/commit/3e0a693d))
- add test vectors dos protection validator ([#1711](https://github.com/waku-org/nwaku/issues/1711)) ([eaa162ee](https://github.com/waku-org/nwaku/commit/eaa162ee))
- add validator for dos protec metrics and move to app ([#1704](https://github.com/waku-org/nwaku/issues/1704)) ([3e146869](https://github.com/waku-org/nwaku/commit/3e146869))
- use QUICK_AND_DIRTY_COMPILER flag for CI ([#1708](https://github.com/waku-org/nwaku/issues/1708)) ([21510425](https://github.com/waku-org/nwaku/commit/21510425))
- move networkmonitor and wakucanary to apps directory ([209579b0](https://github.com/waku-org/nwaku/commit/209579b0))
- **wakunode2:** flatten and simplify app setup ([#1705](https://github.com/waku-org/nwaku/issues/1705)) ([ce92fc1a](https://github.com/waku-org/nwaku/commit/ce92fc1a))
- **wakunode2:** split setup logic into app module ([c8081c88](https://github.com/waku-org/nwaku/commit/c8081c88))
- add payload bytes to trace log ([#1703](https://github.com/waku-org/nwaku/issues/1703)) ([c6d291d3](https://github.com/waku-org/nwaku/commit/c6d291d3))
- refactor flaky test with while ([#1698](https://github.com/waku-org/nwaku/issues/1698)) ([dca0e9b2](https://github.com/waku-org/nwaku/commit/dca0e9b2))
- **core:** move peers utils module to waku_core ([e041e043](https://github.com/waku-org/nwaku/commit/e041e043))
- decouple test2 target from testcommon ([91baa232](https://github.com/waku-org/nwaku/commit/91baa232))
- **core:** move utils time module to waku_core ([93b0c071](https://github.com/waku-org/nwaku/commit/93b0c071))
- add deprecation notice to utils module. move heartbeat to common ([e8dceb2a](https://github.com/waku-org/nwaku/commit/e8dceb2a))
- **core:** rename waku_message module to waku_core ([c9b6b230](https://github.com/waku-org/nwaku/commit/c9b6b230))
- flatten waku v2 protocols folder ([d7b72ac7](https://github.com/waku-org/nwaku/commit/d7b72ac7))
- fix test failing intermittently ([#1679](https://github.com/waku-org/nwaku/issues/1679)) ([8d213e85](https://github.com/waku-org/nwaku/commit/8d213e85))
- **networking:** get relay number of connections from protocol conns/streams ([#1609](https://github.com/waku-org/nwaku/issues/1609)) ([73cbafa6](https://github.com/waku-org/nwaku/commit/73cbafa6))
- allow to call store api endpoints without a storenode ([#1575](https://github.com/waku-org/nwaku/issues/1575)) ([#1647](https://github.com/waku-org/nwaku/issues/1647)) ([0b4a2e68](https://github.com/waku-org/nwaku/commit/0b4a2e68))
- bump container image versions to v0.16.0 in quickstart ([#1640](https://github.com/waku-org/nwaku/issues/1640)) ([5c33d9d1](https://github.com/waku-org/nwaku/commit/5c33d9d1))
- **node:** remove deprecated constructor and extend testlib with builder ([9dadc1f5](https://github.com/waku-org/nwaku/commit/9dadc1f5))
- do not mount relay more than once ([#1650](https://github.com/waku-org/nwaku/issues/1650)) ([5d853b86](https://github.com/waku-org/nwaku/commit/5d853b86))
- pointed all waku node imports to the barrel import ([e8448dfd](https://github.com/waku-org/nwaku/commit/e8448dfd))
- **node:** added waku_node barrel import and split config module ([13942888](https://github.com/waku-org/nwaku/commit/13942888))
- remove deprecated enr record init method ([0627b4f8](https://github.com/waku-org/nwaku/commit/0627b4f8))
- **deps:** upgrade nim-chronos and nim-presto to latest version ([7c229ece](https://github.com/waku-org/nwaku/commit/7c229ece))
- remove waku swap protocol ([2b5fd2a2](https://github.com/waku-org/nwaku/commit/2b5fd2a2))
- **deps:** upgrade nim-confutils to latest version ([67fa736d](https://github.com/waku-org/nwaku/commit/67fa736d))
- **rln-relay:** gracefully handle chain forks ([#1623](https://github.com/waku-org/nwaku/issues/1623)) ([00a3812b](https://github.com/waku-org/nwaku/commit/00a3812b))
- bump nim-libp2p 53b060f ([#1633](https://github.com/waku-org/nwaku/issues/1633)) ([11ff93c2](https://github.com/waku-org/nwaku/commit/11ff93c2))
- added testcommon target to makefile ([048ca45d](https://github.com/waku-org/nwaku/commit/048ca45d))
- increase meta size to 64 bytes + tests ([#1629](https://github.com/waku-org/nwaku/issues/1629)) ([1f793756](https://github.com/waku-org/nwaku/commit/1f793756))
- **enr:** move waku enr multiaddr to typedrecord and builder extensions ([2ffd2f80](https://github.com/waku-org/nwaku/commit/2ffd2f80))
- **enr:** added waku2 capabilities accessor ([157724d9](https://github.com/waku-org/nwaku/commit/157724d9))
- **rln-relay:** reduce exports ([#1615](https://github.com/waku-org/nwaku/issues/1615)) ([2f3ba3d6](https://github.com/waku-org/nwaku/commit/2f3ba3d6))
- add dash between target and version ([#1613](https://github.com/waku-org/nwaku/issues/1613)) ([24d62791](https://github.com/waku-org/nwaku/commit/24d62791))
- **release:** added regression checking and clarifications ([#1610](https://github.com/waku-org/nwaku/issues/1610)) ([b495dd7b](https://github.com/waku-org/nwaku/commit/b495dd7b))


This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` <br />`/vac/waku/filter-subscribe/2.0.0-beta1` <br />`/vac/waku/filter-push/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## Upgrade instructions

* The `--topics` config option has been deprecated to unify the configuration style. It still available in this and will be in next release, but will be removed after that. The new option `--topic` is introduced, which can be use repeatedly to achieve the same behaviour.

## 2023-03-15 v0.16.0

## What's Changed

Release highlights:
- a fix for an issue that prevented the node from generating high-resolution (up to nanosecond) timestamps
- introduction of an application-defined `meta` attribute to the Waku Message. This can be quite valuable for network-wide deduplication, deterministic hashing, validity checking and other planned improvements to the protocol
- many optimizations in RLN implementation and its underlying dependencies

### Features

- Integrated a new group manager for RLN-protected relay [1496](https://github.com/waku-org/nwaku/pull/1496)
- Added application-defined meta attribute to Waku Message according to RFC [14/WAKU2-MESSAGE](https://rfc.vac.dev/spec/14/#message-attributes) [1581](https://github.com/waku-org/nwaku/pull/1581)
- Implemented deterministic hashing scheme for Waku Messages according to RFC [14/WAKU2-MESSAGE](https://rfc.vac.dev/spec/14/#deterministic-message-hashing) [1586](https://github.com/waku-org/nwaku/pull/1586)

### Changes

- Upgraded nim-sqlite3-abi to the latest version [1565](https://github.com/waku-org/nwaku/pull/1565)
- Better validation of protocol buffers [1563](https://github.com/waku-org/nwaku/pull/1563)
- Improved underlying Zerokit performance and FFI [1571](https://github.com/waku-org/nwaku/pull/1571)
- Node peer ID now logged with relay trace logging [1574](https://github.com/waku-org/nwaku/pull/1574)
- Continued refactoring of several protocol implementations to improve maintainability and readability
- Refactored and cleaned up peer manager [1539](https://github.com/waku-org/nwaku/pull/1539)
- Removed unused and legacy websocket submodule [1580](https://github.com/waku-org/nwaku/pull/1580) [1582](https://github.com/waku-org/nwaku/pull/1582)
- Use base64 URL-safe encoding for noise [1569](https://github.com/waku-org/nwaku/pull/1569)
- Various general improvements to RLN implementation [1585](https://github.com/waku-org/nwaku/pull/1585) [1587](https://github.com/waku-org/nwaku/pull/1587)
- Started on implementation for new and improved filter protocol [1584](https://github.com/waku-org/nwaku/pull/1584)
- Updated pubsub and content topic namespacing to reflect latest changes in RFC [23/WAKU2-TOPICS](https://rfc.vac.dev/spec/23/) [1589](https://github.com/waku-org/nwaku/pull/1589)
- Unified internal peer data models [1597](https://github.com/waku-org/nwaku/pull/1597)
- Improved internal implementation of Waku ENR encoding and decoding [1598](https://github.com/waku-org/nwaku/pull/1598) [1599](https://github.com/waku-org/nwaku/pull/1599)
- Underlying dependency for RLN implementation now loaded as a static library [1578](https://github.com/waku-org/nwaku/pull/1578)

### Fixes

- Fixed internally generated timestamps to allow higher resolution than seconds [1570](https://github.com/waku-org/nwaku/pull/1570)
- Fixed padded base64 usage for encoding and decoding payloads on the JSON RPC API [1572](https://github.com/waku-org/nwaku/pull/1572)
- Fixed incorrect relative module imports [1591](https://github.com/waku-org/nwaku/pull/1591)
- Fixed RLN relay erroneously storing messages from multiple apps [1594](https://github.com/waku-org/nwaku/pull/1594)

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2023-02-15 v0.15.0

Release highlights:
- Relay connectivity is now maintained by a management loop that selects from the peerstore
- Ability to manually specify `multiaddrs` for the nwaku node to advertise
- Two important fixes related to historical message queries:
  - fixed archive bug that resulted in duplicate messages in store query response
  - fixed query page size limit not being respected

### Features

- New connectivity loop to maintain relay connectivity from peerstore [1482](https://github.com/waku-org/nwaku/pull/1482) [1462](https://github.com/waku-org/nwaku/pull/1462)
- Support for manually specifying `multiaddrs` to advertise [1509](https://github.com/waku-org/nwaku/pull/1509) [1512](https://github.com/waku-org/nwaku/pull/1512)
- Added dynamic keystore for membership credential storage and management [1466](https://github.com/waku-org/nwaku/pull/1466)

### Changes

- Abstracted RLN relay group management into its own API [1465](https://github.com/waku-org/nwaku/pull/1465)
- Prune peers from peerstore when exceeding capacity [1513](https://github.com/waku-org/nwaku/pull/1513)
- Removed Kilic submodule [1517](https://github.com/waku-org/nwaku/pull/1517)
- Continued refactoring of several protocol implementations to improve maintainability and readability
- Refactored and improved JSON RPC API
- Added safe default values for peer-store-capacity [1525](https://github.com/waku-org/nwaku/pull/1525)
- Improvements in regular CI test reliability and repeatability
- Improved archive query performance [1510](https://github.com/waku-org/nwaku/pull/1510)
- Added better e2e trace logging for relay messages [1526](https://github.com/waku-org/nwaku/pull/1526)
- Relay RPC API now encodes message payloads in base64 [572](https://github.com/vacp2p/rfc/pull/572) [1555](https://github.com/waku-org/nwaku/pull/1555)

### Fixes

- Fixed Waku archive queries returning duplicate messages due to incorrect reordering [1511](https://github.com/waku-org/nwaku/pull/1511)
- Fixed Admin RPC API crashing on returning peer with no multiaddresses [1507](https://github.com/waku-org/nwaku/pull/1507)
- Fixed page size limit not being respected in store query responses [1520](https://github.com/waku-org/nwaku/pull/1520)
- Fixed nwaku subscribing to default pubsub topic even if not configured [1548](https://github.com/waku-org/nwaku/pull/1548)
- Fixed underlying issue causing node to incorrectly report it's unreachable [1518](https://github.com/waku-org/nwaku/pull/1518) [1546](https://github.com/waku-org/nwaku/pull/1546)
- Fixed Relay RPC API not adhering to RFC [1139](https://github.com/waku-org/nwaku/issues/1139)
- Fixed message IDs in nwaku diverging from those in go-waku [1556](https://github.com/waku-org/nwaku/pull/1556)

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2023-01-16 v0.14.0

Release highlights:
- An important fix for the Waku message archive returning inconsistent responses to history queries.
- Support for [AutoNAT](https://docs.libp2p.io/concepts/nat/autonat/) and [libp2p Circuit Relay](https://docs.libp2p.io/concepts/nat/circuit-relay/) that allows, among other things, for [NAT hole punching](https://docs.libp2p.io/concepts/nat/hole-punching/).
- Support for structured logging in JSON format.
- A fix for an underlying file descriptor leak that affected websocket connections.

### Features

- Support for [AutoNAT](https://docs.libp2p.io/concepts/nat/autonat/)
- Support for [libp2p Circuit Relay](https://docs.libp2p.io/concepts/nat/circuit-relay/) (server only)
- New Waku Archive implementation. This allows easy addition of drivers for different technologies to store historical messages.
- Support for structured logging and specifying log format.
- Node now keeps track of its external reachability.

### Changes

- Zerokit RLN library now statically linked.
- Use extended key generation in Zerokit API to comply with [32/RLN](https://rfc.vac.dev/spec/32/).
- Re-enable root validation in [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) implementation.
- [Network monitoring tool](https://github.com/status-im/nwaku/tree/2336522d7f478337237a5a4ec8c5702fb4babc7d/tools#networkmonitor) now supports DNS discovery.
- Added [dashboard](https://github.com/waku-org/nwaku/blob/3e0e1cb2398297fca761aa74f52d32fa837d556c/metrics/waku-network-monitor-dashboard.json) for network monitoring.
- Continued refactoring of several protocol implementations to improve maintainability and readability.
- Removed swap integration from store protocol.
- Peerstore now consolidated with libp2p peerstore.
- Peerstore now also tracks peer direction.
- SIGSEGV signals are now handled and logged properly.
- Waku v2 no longer imports libraries from Waku v1.
- Improved build and CI processes:
  - Added support for an `EXPERIMENTAL` compiler flag.
  - Simplified project Makefile.
  - Split Dockerfile into production and experimental stages.
  - Removed obsolete simulation libraries from build.
- Improved parallellisation (and therefore processing time) when dialing several peers simultaneously.
- Waku Archive now responds with error to historical queries containing more than 10 content topics.

### Fixes

- Fixed support for optional fields in several protocol rpc codecs. [#1393](https://github.com/waku-org/nwaku/pull/1393) [#1395](https://github.com/waku-org/nwaku/pull/1395) [#1396](https://github.com/waku-org/nwaku/pull/1396)
- Fixed clients with `--store=false` not installing Store Client JSON-RPC API handlers. [#1382](https://github.com/waku-org/nwaku/pull/1382)
- Fixed SQLite driver returning inconsistent responses to store queries. [#1415](https://github.com/waku-org/nwaku/pull/1415)
- Fixed peer exchange discv5 loop starting before discv5 has started. [#1407](https://github.com/waku-org/nwaku/pull/1407)
- Fixed wakubridge test timing. [#1429](https://github.com/waku-org/nwaku/pull/1429)
- Fixed bug in Noise module types equating `T_ss` incorrectly to `"se"` and not `"ss"`. [#1432](https://github.com/waku-org/nwaku/pull/1432)
- Fixed Ctrl-C quitting resulting in unreleased resources and exit failures. [#1416](https://github.com/waku-org/nwaku/pull/1416)
- Fixed CI workflows not cloning repo on startup. [#1454](https://github.com/waku-org/nwaku/pull/1454) [#1455](https://github.com/waku-org/nwaku/pull/1455)
- Fixed Admin API peer connection not returning error response if peer can't be connected. [#1476](https://github.com/waku-org/nwaku/pull/1476)
- Fixed underlying file descriptor leak. [#1483](https://github.com/waku-org/nwaku/pull/1483)

### Docs

- Added [instructions](https://github.com/waku-org/nwaku/blob/3e0e1cb2398297fca761aa74f52d32fa837d556c/docs/operators/quickstart.md) for running nwaku with docker compose.

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2022-11-15 v0.13.0

Release highlights:
- A [Waku canary tool](https://github.com/status-im/nwaku/tree/2336522d7f478337237a5a4ec8c5702fb4babc7d/tools#waku-canary-tool) to check if nodes are reachable and what protocols they support.
- Simplified configuration for store protocol. This [new guide](https://github.com/status-im/nwaku/blob/4e5318bfbb204bd1239c95472d7b84b6a326dd9d/docs/operators/how-to/configure-store.md) explains how to configure store from this release forward.
- Support for environment variables to configure a nwaku node. See our [configuration guide](https://github.com/status-im/nwaku/blob/384abed614050bf3aa90c901d7f5e8bc383e8b22/docs/operators/how-to/configure.md) for more.
- A Waku [network monitoring tool](https://github.com/status-im/nwaku/tree/2336522d7f478337237a5a4ec8c5702fb4babc7d/tools#networkmonitor) to report network metrics, including network size, discoverable peer capabilities and more.

### Features

- Added Waku canary tool to check if i) a given node is reachable and ii) it supports a set of protocols.
- Simplified [Waku store configuration](https://github.com/status-im/nwaku/blob/4e5318bfbb204bd1239c95472d7b84b6a326dd9d/docs/operators/how-to/configure-store.md).
- Decoupled Waku peer persistence configuration from message store configuration.
- Added keyfile support for secure storage of RLN credentials.
- Added configurable libp2p agent string to nwaku switch.
- Support for [configuration with environment variables](https://github.com/status-im/nwaku/blob/384abed614050bf3aa90c901d7f5e8bc383e8b22/docs/operators/how-to/configure.md).
- Added [example module](https://github.com/status-im/nwaku/tree/2336522d7f478337237a5a4ec8c5702fb4babc7d/examples/v2) to showcase basic nwaku relay usage.
- Added a nwaku [network monitoring tool](https://github.com/status-im/nwaku/tree/2336522d7f478337237a5a4ec8c5702fb4babc7d/tools#networkmonitor) to provide metrics on peers, network size and more.

### Changes

- Removed support for Kilic's RLN library (obsolete).
- Improved logging for [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) implementation.
- Connection to eth node for RLN now more stable, maintains state and logs failures.
- Waku apps and tools now moved to their own subdirectory.
- Continued refactoring of several protocol implementations to improve maintainability and readability.
- Periodically log metrics when running RLN spam protection.
- Added metrics dashboard for RLN spam protection.
- Github CI test workflows are now run selectively, based on the content of a PR.
- Improved reliability of CI runs and added email notifications.
- Discv5 discovery loop now triggered to fill a [34/WAKU2-PEER-EXCHANGE](https://rfc.vac.dev/spec/34/) peer list cache asynchronously.
- Upgraded to Nim v1.6.6.
- Cleaned up compiler warnings on unused imports.
- Improved exception handling and annotation.
- [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) no longer enabled by default on nwaku nodes.
- Merkle tree roots for RLN membership changes now on a per-block basis to allow poorly connected peers to operate within a window of acceptable roots.

### Fixes

- Fixed encoding of ID commitments for RLN from Big-Endian to Little-Endian. [#1256](https://github.com/status-im/nwaku/pull/1256)
- Fixed maxEpochGap to be the maximum allowed epoch gap (RLN). [#1257](https://github.com/status-im/nwaku/pull/1257)
- Fixed store cursors being retrieved incorrectly (truncated) from DB. [#1263](https://github.com/status-im/nwaku/pull/1263)
- Fixed message indexed by store cursor being excluded from history query results. [#1263](https://github.com/status-im/nwaku/pull/1263)
- Fixed log-level configuration being ignored by the nwaku node. [#1272](https://github.com/status-im/nwaku/pull/1272)
- Fixed incorrect error message when failing to set [34/WAKU2-PEER-EXCHANGE](https://rfc.vac.dev/spec/34/) peer. [#1298](https://github.com/status-im/nwaku/pull/1298)
- Fixed and replaced deprecated `TaintedString` type. [#1326](https://github.com/status-im/nwaku/pull/1326)
- Fixed and replaced unreliable regex library and usage. [#1327](https://github.com/status-im/nwaku/pull/1327) [#1328](https://github.com/status-im/nwaku/pull/1328)
- Fixed and replaced deprecated `ganache-cli` node package with `ganache` for RLN onchain tests. Added graceful daemon termination. [#1347](https://github.com/status-im/nwaku/pull/1347)

### Docs

- Added cross client RLN testnet [tutorial](https://github.com/status-im/nwaku/blob/44d8a2026dc31a37e181043ceb67e2822376dc03/docs/tutorial/rln-chat-cross-client.md).
- Fixed broken link to Kibana in [cluster documentation](https://github.com/status-im/nwaku/blob/5e90085242e9e4d6f3cf307e189efbf7e59da9f9/docs/contributors/cluster-logs.md).
- Added an improved [quickstart guide](https://github.com/status-im/nwaku/blob/8f5363ea8f5e95fc1104307aa0d2fc59fda13698/docs/operators/quickstart.md) for operators.
- Added a [Docker usage guide](https://github.com/status-im/nwaku/blob/8f5363ea8f5e95fc1104307aa0d2fc59fda13698/docs/operators/docker-quickstart.md#prerequisites) for operators.
- Added operator [guide on running RLN spam prevention](https://github.com/status-im/nwaku/blob/bd516788cb39132ccbf0a4dcf0880e9694beb233/docs/operators/how-to/run-with-rln.md) on nwaku nodes.
- Extended guidelines on nwaku [configuration methods](https://github.com/status-im/nwaku/blob/384abed614050bf3aa90c901d7f5e8bc383e8b22/docs/operators/how-to/configure.md) for operators.
- Added new [store configuration guide](https://github.com/status-im/nwaku/blob/4e5318bfbb204bd1239c95472d7b84b6a326dd9d/docs/operators/how-to/configure-store.md) to reflect simplified options.

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2022-10-06 v0.12.0

Release highlights:
- The performance and stability of the message `store` has improved dramatically. Query durations, even for long-term stores, have improved by more than a factor of 10.
- Support for Waku Peer Exchange - a discovery method for resource-restricted nodes.
- Messages can now be marked as "ephemeral" to prevent them from being stored.
- [Zerokit](https://github.com/vacp2p/zerokit) is now the default implementation for spam-protected `relay` with RLN.

The full list of changes is below.

### Features

- Default support for [Zerokit](https://github.com/vacp2p/zerokit) version of [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) implementation.
- Added Filter REST API OpenAPI specification.
- Added POC implementation for [43/WAKU2-DEVICE-PAIRING](https://rfc.vac.dev/spec/43/).
- [14/WAKU2-MESSAGE](https://rfc.vac.dev/spec/14/) can now be marked as `ephemeral` to prevent them from being stored.
- Support for [34/WAKU2-PEER-EXCHANGE](https://rfc.vac.dev/spec/34/).

### Changes

- [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) implementation now handles on-chain transaction errors.
- [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) implementation now validates the Merkle tree root against a window of acceptable roots.
- Added metrics for [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) implementation.
- Continued refactoring of several protocol implementations to improve maintainability and readability.
- Cleaned up nwaku imports and dependencies.
- Refactored and organised nwaku unit tests.
- Nwaku now periodically logs node metrics by default.
- Further improvements to the `store` implementation:
  - Better logging and query traceability.
  - More useful metrics to measure query and insertion time.
  - Reworked indexing for faster inserts and queries.
  - Reworked data model to use a simple, single timestamp for indexing, ordering and querying.
  - Improved retention policy management with periodic execution.
  - Run sqlite database vacuum at node start.
  - Improved logging when migrating the database to a newer version.
- `relay` no longer auto-mounted on all nwaku nodes.
- The most complete node ENR now included in response to API requests for node `info()`.
- Updated Grafana dashboards included with nwaku.
- Github CI test execution now skipped for doc-only changes.

### Fixes

- Fixed nwaku unnecessary sleep when no dynamic bootstrap nodes retrieved.
- Fixed [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) not working from browser-based clients due to nwaku peer manager failing to reuse existing connection.
- Waku Message payload now correctly encoded as base64 in the Relay REST API.
- Fixed handling of bindParam(uint32) in sqlite.
- `chat2` application now correctly selects a random store node on startup.
- Fixed macos builds failing due to an unsupported dependency.
- Fixed nwaku not reconnecting to previously discovered nodes after losing connection.
- Fixed nwaku failing to start switch transports with external IP configuration.
- Fixed SIGSEGV crash when attempting to start nwaku store without `db-path` configuration.

### Docs

- Improved [RLN testnet tutorial](https://github.com/status-im/nwaku/blob/14abdef79677ddc828ff396ece321e05cedfca17/docs/tutorial/onchain-rln-relay-chat2.md)
- Added [tutorial](https://github.com/status-im/nwaku/blob/14abdef79677ddc828ff396ece321e05cedfca17/docs/operators/droplet-quickstart.md) on running nwaku from a DigitalOcean droplet.
- Added [guide](https://github.com/status-im/nwaku/blob/14abdef79677ddc828ff396ece321e05cedfca17/docs/operators/how-to/monitor.md) on how to monitor nwaku using Prometheus and Grafana.

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2022-08-15 v0.11

Release highlights:
- Major improvements in the performance of historical message queries to longer-term, sqlite-only message stores.
- Introduction of an HTTP REST API with basic functionality
- On-chain RLN group management. This was also integrated into an [example spam-protected chat application](https://github.com/status-im/nwaku/blob/4f93510fc9a938954dd85593f8dc4135a1c367de/docs/tutorial/onchain-rln-relay-chat2.md).

The full list of changes is below.

### Features

- Support for on-chain group membership management in the [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) implementation.
- Integrated HTTP REST API for external access to some `wakunode2` functionality:
  - Debug REST API exposes debug information about a `wakunode2`.
  - Relay REST API allows basic pub/sub functionality according to [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/).
- [`35/WAKU2-NOISE`](https://rfc.vac.dev/spec/35/) implementation now adds padding to ChaChaPoly encryptions to increase security and reduce metadata leakage.

### Changes

- Significantly improved the SQLite-only historical message `store` query performance.
- Refactored several protocol implementations to improve maintainability and readability.
- Major code reorganization for the [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) implementation to improve maintainability. This will also make the `store` extensible to support multiple implementations.
- Disabled compiler log colors when running in a CI environment.
- Refactored [`35/WAKU2-NOISE`](https://rfc.vac.dev/spec/35/) implementation into smaller submodules.
- [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) implementation can now optionally be compiled with [Zerokit RLN](https://github.com/vacp2p/zerokit/tree/64f508363946b15ac6c52f8b59d8a739a33313ec/rln). Previously only [Kilic's RLN](https://github.com/kilic/rln/tree/7ac74183f8b69b399e3bc96c1ae8ab61c026dc43) was supported.

### Fixes

- Fixed wire encoding of protocol buffers to use proto3.
- Fixed Waku v1 <> Waku v2 bridge losing connection to statically configured v1 nodes.
- Fixed underlying issue causing DNS discovery to fail for records containing multiple strings.

### Docs

- Updated [release process](https://github.com/status-im/nwaku/blob/4f93510fc9a938954dd85593f8dc4135a1c367de/docs/contributors/release-process.md) documentation.
- Added [tutorial](https://github.com/status-im/nwaku/blob/4f93510fc9a938954dd85593f8dc4135a1c367de/docs/tutorial/onchain-rln-relay-chat2.md) on how to run a spam-protected chat2 application with on-chain group management.


This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2022-06-15 v0.10

Release highlights:
- Support for key exchange using Noise handshakes.
- Support for a SQLite-only historical message `store`. This allows for cheaper, longer-term historical message storage on disk rather than in memory.
- Several fixes for native WebSockets, including slow or hanging connections and connections dropping unexpectedly due to timeouts.
- A fix for a memory leak in nodes running a local SQLite database.

### Features

- Support for [`35/WAKU2-NOISE`](https://rfc.vac.dev/spec/35/) handshakes as key exchange protocols.
- Support for TOML config files via `--config-file=<path/to/config.toml>`.
- Support for `--version` command. This prints the current tagged version (or compiled commit hash, if not on a version).
- Support for running `store` protocol from a `filter` client, storing only the filtered messages.
- Start of an HTTP REST API implementation.
- Support for a memory-efficient SQLite-only `store` configuration.

### Changes

- Added index on `receiverTimestamp` in the SQLite `store` to improve query performance.
- GossipSub [Peer Exchange](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#prune-backoff-and-peer-exchange) is now disabled by default. This is a more secure option.
- Progress towards dynamic group management for the [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) implementation.
- Nodes with `--keep-alive` enabled now sends more regular pings to keep connections more reliably alive.
- Disabled `swap` protocol by default.
- Reduced unnecessary and confusing logging, especially during startup.
- Added discv5 UDP port to the node's main discoverable ENR.

### Fixes

- The in-memory `store` now checks the validity of message timestamps before storing.
- Fixed underlying bug that caused connection leaks in the HTTP client.
- Fixed Docker image compilation to use the correct external variable for compile-time flags (`NIMFLAGS` instead of `NIM_PARAMS`).
- Fixed issue where `--dns4-domain-name` caused an unhandled exception if no external port was available.
- Avoids unnecessarily calling DB migration if a `--db-path` is set but nothing is persisted in the DB. This led to a misleading warning log.
- Fixed underlying issues that caused WebSocket connections to hang.
- Fixed underlying issue that caused WebSocket connections to time out after 10 mins.
- Fixed memory leak in nodes that implements a SQLite database.

### Docs

- Added [tutorial](https://github.com/status-im/nwaku/blob/16dd267bd9d25ff24c64fc5c92a20eb0d322217c/docs/operators/how-to/configure-key.md) on how to generate and configure a node key.
- Added first [guide](https://github.com/status-im/nwaku/tree/16dd267bd9d25ff24c64fc5c92a20eb0d322217c/docs/operators) for nwaku operators.

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2022-03-31 v0.9

Release highlights:

- Support for Peer Exchange (PX) when a peer prunes a [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) mesh due to oversubscription. This can significantly increase mesh stability.
- Improved start-up times through managing the size of the underlying persistent message storage.
- New websocket connections are no longer blocked due to parsing failures in other connections.

The full list of changes is below.

### Features

- Support for bootstrapping [`33/WAKU-DISCV5`](https://rfc.vac.dev/spec/33) via [DNS discovery](https://rfc.vac.dev/spec/10/#discovery-methods)
- Support for GossipSub [Peer Exchange](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#prune-backoff-and-peer-exchange)

### Changes

- Waku v1 <> v2 bridge now supports DNS `multiaddrs`
- Waku v1 <> v2 bridge now validates content topics before attempting to bridge a message from Waku v2 to Waku v1
- Persistent message storage now auto deletes messages once over specified `--store-capacity`. This can significantly improve node start-up times.
- Renamed Waku v1 <> v2 bridge `make` target and binary to `wakubridge`
- Increased `store` logging to assist with debugging
- Increased `rln-relay` logging to assist with debugging
- Message metrics no longer include the content topic as a dimension to keep Prometheus metric cardinality under control
- Waku v2 `toy-chat` application now sets the sender timestamp when creating messages
- The type of the `proof` field of the `WakuMessage` is changed to `RateLimitProof`
- Added method to the JSON-RPC API that returns the git tag and commit hash of the binary
- The node's ENR is now included in the JSON-RPC API response when requesting node info

### Fixes

- Fixed incorrect conversion of seconds to nanosecond timestamps
- Fixed store queries blocking due to failure in resource clean up
- Fixed underlying issue where new websocket connections are blocked due to parsing failures in other connections
- Fixed failure to log the ENR necessary for a discv5 connection to the node

### Docs

- Added [RAM requirements](https://github.com/status-im/nim-waku/tree/ee96705c7fbe4063b780ac43b7edee2f6c4e351b/waku/v2#wakunode) to `wakunode2` build instructions
- Added [tutorial](https://github.com/status-im/nim-waku/blob/ee96705c7fbe4063b780ac43b7edee2f6c4e351b/docs/tutorial/rln-chat2-live-testnet.md) on communicating with waku2 test fleets via the chat2 `toy-chat` application in spam-protected mode using [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/).
- Added a [section on bug reporting](https://github.com/status-im/nim-waku/blob/ee96705c7fbe4063b780ac43b7edee2f6c4e351b/README.md#bugs-questions--features) to `wakunode2` README
- Fixed broken links in the [JSON-RPC API Tutorial](https://github.com/status-im/nim-waku/blob/5ceef37e15a15c52cbc589f0b366018e81a958ef/docs/tutorial/jsonrpc-api.md)

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

##  2022-03-03 v0.8

Release highlights:

- Working demonstration and integration of [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) in the Waku v2 `toy-chat` application
- Beta support for ambient peer discovery using [a version of Discovery v5](https://github.com/vacp2p/rfc/pull/487)
- A fix for the issue that caused a `store` node to run out of memory after serving a number of historical queries
- Ability to configure a `dns4` domain name for a node and resolve other dns-based `multiaddrs`

The full list of changes is below.

### Features

- [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) implementation now supports spam-protection for a specific combination of `pubsubTopic` and `contentTopic` (available under the `rln` compiler flag).
- [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) integrated into chat2 `toy-chat` (available under the `rln` compiler flag)
- Added support for resolving dns-based `multiaddrs`
- A Waku v2 node can now be configured with a domain name and `dns4` `multiaddr`
- Support for ambient peer discovery using [`33/WAKU-DISCV5`](https://github.com/vacp2p/rfc/pull/487)

### Changes

- Metrics: now monitoring content topics and the sources of new connections
- Metrics: improved default fleet monitoring dashboard
- Introduced a `Timestamp` type (currently an alias for int64).
- All timestamps changed to nanosecond resolution.
- `timestamp` field number in WakuMessage object changed from `4` to `10`
- [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) identifier updated to `/vac/waku/store/2.0.0-beta4`
- `toy-chat` application now uses DNS discovery to connect to existing fleets

### Fixes

- Fixed underlying bug that caused occasional failures when reading the certificate for secure websockets
- Fixed `store` memory usage issues when responding to history queries

### Docs

- Documented [use of domain certificates](https://github.com/status-im/nim-waku/tree/2972a5003568848164033da3fe0d7f52a3d54824/waku/v2#enabling-websocket) for secure websockets
- Documented [how to configure a `dns4` domain name](https://github.com/status-im/nim-waku/tree/2972a5003568848164033da3fe0d7f52a3d54824/waku/v2#using-dns-discovery-to-connect-to-existing-nodes) for a node
- Clarified [use of DNS discovery](https://github.com/status-im/nim-waku/tree/2972a5003568848164033da3fe0d7f52a3d54824/waku/v2#using-dns-discovery-to-connect-to-existing-nodes) and provided current URLs for discoverable fleet nodes
- Added [tutorial](https://github.com/status-im/nim-waku/blob/2972a5003568848164033da3fe0d7f52a3d54824/docs/tutorial/rln-chat2-local-test.md) on using [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) with the chat2 `toy-chat` application
- Added [tutorial](https://github.com/status-im/nim-waku/blob/2972a5003568848164033da3fe0d7f52a3d54824/docs/tutorial/bridge.md) on how to configure and a use a [`15/WAKU-BRIDGE`](https://rfc.vac.dev/spec/15/)

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta4` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

##  2022-01-19 v0.7

Release highlights:

- Support for secure websockets.
- Ability to remove unreachable clients in a `filter` node.
- Several fixes to improve `store` performance and decrease query times. Query time for large stores decreased from longer than 8 min to under 100 ms.
- Fix for a long-standing bug that prevented proper database migration in some deployed Docker containers.

The full list of changes is below.

### Features

- Support for secure websocket transport

### Changes

- Filter nodes can now remove unreachable clients
- The WakuInfo `listenStr` is deprecated and replaced with a sequence of `listenAddresses` to accommodate multiple transports
- Removed cached `peerInfo` on local node. Rely on underlying libp2p switch instead
- Metrics: added counters for protocol messages
- Waku v2 node discovery now supports [`31/WAKU2-ENR`](https://rfc.vac.dev/spec/31/)
- resuming the history via `resume` now takes the answers of all peers in `peerList` into consideration and consolidates them into one deduplicated list

### Fixes

- Fixed database migration failure in the Docker image
- All `HistoryResponse` messages are now auto-paginated to a maximum of 100 messages per response
- Increased maximum length for reading from a libp2p input stream to allow largest possible protocol messages, including `HistoryResponse` messages at max size
- Significantly improved `store` node query performance
- Implemented a GossipSub `MessageIdProvider` for `11/WAKU2-RELAY` messages instead of relying on the unstable default
- Receiver timestamps for message indexing in the `store` now have consistent millisecond resolution

This release supports the following [libp2p protocols](https://docs.libp2p.io/concepts/protocols/):
| Protocol | Spec status | Protocol id |
| ---: | :---: | :--- |
| [`17/WAKU-RLN-RELAY`](https://rfc.vac.dev/spec/17/) | `raw` | `/vac/waku/waku-rln-relay/2.0.0-alpha1` |
| [`11/WAKU2-RELAY`](https://rfc.vac.dev/spec/11/) | `stable` | `/vac/waku/relay/2.0.0` |
| [`12/WAKU2-FILTER`](https://rfc.vac.dev/spec/12/) | `draft` | `/vac/waku/filter/2.0.0-beta1` |
| [`13/WAKU2-STORE`](https://rfc.vac.dev/spec/13/) | `draft` | `/vac/waku/store/2.0.0-beta3` |
| [`18/WAKU2-SWAP`](https://rfc.vac.dev/spec/18/) | `draft` | `/vac/waku/swap/2.0.0-beta1` |
| [`19/WAKU2-LIGHTPUSH`](https://rfc.vac.dev/spec/19/) | `draft` | `/vac/waku/lightpush/2.0.0-beta1` |

The Waku v1 implementation is stable but not under active development.

## 2021-11-05 v0.6

Some useful features and fixes in this release, include:
- two methods for Waku v2 node discovery
- support for unsecure websockets, which paves the way for native browser usage
- a fix for `nim-waku` store nodes running out of memory due to store size: the number of stored messages can now easily be configured
- a fix for densely connected nodes refusing new connections: the maximum number of allowed connections can now easily be configured
- support for larger message sizes (up from 64kb to 1Mb per message)

The full list of changes is below.

### Features

- Waku v2 node discovery via DNS following [EIP-1459](https://eips.ethereum.org/EIPS/eip-1459)
- Waku v2 node discovery via [Node Discovery v5](https://github.com/ethereum/devp2p/blob/master/discv5/discv5-theory.md)

### Changes

- Pagination of historical queries are now simplified
- GossipSub [prune backoff period](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#prune-backoff-and-peer-exchange) is now the recommended 1 minute
- Bridge now uses content topic format according to [23/WAKU2-TOPICS](https://rfc.vac.dev/spec/23/)
- Better internal differentiation between local and remote peer info
- Maximum number of libp2p connections is now configurable
- `udp-port` CLI option has been removed for binaries where it's not used
- Waku v2 now supports unsecure WebSockets
- Waku v2 now supports larger message sizes of up to 1 Mb by default
- Further experimental development of [RLN for spam protection](https://rfc.vac.dev/spec/17/).
These changes are disabled by default under a compiler flag. Changes include:
  - Per-message rate limit proof defined
  - RLN proof generation and verification integrated into Waku v2
  - RLN tree depth changed from 32 to 20
  - Support added for static membership group formation

#### Docs

- Added [contributor guidelines](https://github.com/status-im/nim-waku/blob/master/docs/contributors/waku-fleets.md) on Waku v2 fleet monitoring and management
- Added [basic tutorial](https://github.com/status-im/nim-waku/blob/master/docs/tutorial/dns-disc.md) on using Waku v2 DNS-based discovery

### Fixes

- Bridge between `toy-chat` and matterbridge now shows correct announced addresses
- Bridge no longer re-encodes already encoded payloads when publishing to V1
- Bridge now populates WakuMessage timestamps when publishing to V2
- Store now has a configurable maximum number of stored messages
- Network simulations for Waku v1 and Waku v2 are runnable again

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
