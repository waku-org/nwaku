# CLAUDE.md - nwaku AI Coding Context

This file provides essential context for LLMs assisting with nwaku development.

## Project Identity

**nwaku** is a Nim implementation of the Waku v2 protocol suite for private, censorship-resistant P2P messaging. It targets resource-restricted devices and privacy-preserving communication.

### Design Philosophy

Waku is designed as a **shared public network** for generalized messaging, not application-specific infrastructure. Key architectural decisions:

**Resource-restricted first**: Protocols differentiate between full nodes (relay) and light clients (filter, lightpush, store). Light clients can participate without maintaining full message history or relay capabilities. This explains the client/server split in protocol implementations.

**Privacy through unlinkability**: RLN (Rate Limiting Nullifier) provides DoS protection while preserving sender anonymity. Messages are routed through pubsub topics with automatic sharding across 8 shards. Code prioritizes metadata privacy alongside content encryption.

**Scalability via sharding**: The network uses automatic content-topic-based sharding to distribute traffic. This is why you'll see sharding logic throughout the codebase and why pubsub topic selection is protocol-level, not application-level.

See [The Waku Network documentation](https://docs.waku.org/learn/) for architectural details.

### Core Protocols
- **Relay**: Pub/sub message routing using GossipSub
- **Store**: Historical message retrieval and persistence
- **Filter**: Lightweight message filtering for resource-restricted clients
- **Lightpush**: Lightweight message publishing for clients
- **Peer Exchange**: Peer discovery mechanism
- **RLN Relay**: Rate limiting nullifier for spam protection

### Key Terminology
- **ENR** (Ethereum Node Record): Node identity and capability advertisement
- **Multiaddr**: libp2p addressing format (e.g., `/ip4/127.0.0.1/tcp/60000/p2p/16Uiu2...`)
- **PubsubTopic**: Gossipsub topic for message routing (e.g., `/waku/2/default-waku/proto`)
- **ContentTopic**: Application-level message categorization (e.g., `/my-app/1/chat/proto`)
- **Sharding**: Partitioning network traffic across topics (static or auto-sharding)
- **RLN** (Rate Limiting Nullifier): Zero-knowledge proof system for spam prevention

### Specifications
All Waku specs are at [rfc.vac.dev/waku](https://rfc.vac.dev/waku). RFCs use `WAKU2-XXX` format (not legacy `WAKU-XXX`).

## Architecture

### Directory Structure
```
nwaku/
├── waku/                    # Core protocol implementations
│   ├── waku_core/          # Fundamental types (Message, PubsubTopic, etc.)
│   ├── waku_relay/         # GossipSub-based relay protocol
│   ├── waku_store/         # Message persistence and retrieval
│   ├── waku_filter_v2/     # Lightweight filtering protocol
│   ├── waku_lightpush/     # Lightweight publishing protocol
│   ├── waku_peer_exchange/ # Peer discovery via PX
│   ├── waku_rln_relay/     # RLN spam protection
│   ├── waku_archive/       # Message storage drivers (SQLite, PostgreSQL)
│   ├── node/               # WakuNode orchestration and peer management
│   ├── waku_api/           # REST API handlers
│   └── factory/            # Node factory and configuration
├── apps/                    # Executable applications
│   ├── wakunode2/          # Main Waku node CLI
│   ├── chat2/              # Example chat application
│   └── networkmonitor/     # Network monitoring tool
├── library/                 # C bindings (libwaku)
├── tests/                   # Test suites (organized by protocol)
├── examples/                # Usage examples
└── vendor/                  # Git submodules (auto-generated)
```

### Protocol Module Pattern
Each protocol typically follows this structure:
```
waku_<protocol>/
├── protocol.nim       # Main protocol type and handler logic
├── client.nim         # Client-side API
├── rpc.nim           # RPC message types
├── rpc_codec.nim     # Protobuf encoding/decoding
├── common.nim        # Shared types and constants
└── protocol_metrics.nim  # Prometheus metrics
```

### WakuNode Architecture
- **WakuNode** (`waku/node/waku_node.nim`) is the central orchestrator
- Protocols are "mounted" onto the node's switch (libp2p component)
- PeerManager handles peer selection and connection management
- Switch provides libp2p transport, security, and multiplexing

Example protocol type definition:
```nim
type WakuFilter* = ref object of LPProtocol
  subscriptions*: FilterSubscriptions
  peerManager: PeerManager
  messageCache: TimedCache[string]
```

## Development Essentials

### Build Requirements
- **Nim 2.2.4+** (affects language features available)
- **Rust toolchain** (for RLN dependencies)
- Build via Make → nimbus-build-system

### Build System
Uses Makefile + nimbus-build-system (Status's Nim build framework):
```bash
# Initial build (updates submodules)
make wakunode2

# After git pull, update submodules
make update

# Build with custom flags
make wakunode2 NIMFLAGS="-d:chronicles_log_level=DEBUG"
```

**Note**: The build system uses `--mm:refc` memory management (automatically enforced). Only relevant if compiling outside the standard build system.

### Common Make Targets
```bash
make wakunode2          # Build main node binary
make test               # Run all tests
make testcommon         # Run common tests only
make libwakuStatic      # Build static C library
make chat2              # Build chat example
make install-nph        # Install git hook for auto-formatting
```

### Testing
```bash
# Run all tests
make test

# Run specific test file
make test tests/test_waku_enr.nim

# Run specific test case from file
make test tests/test_waku_enr.nim "check capabilities support"

# Build and run test separately (for development iteration)
make test/tests/test_waku_enr.nim
```

Test structure uses `testutils/unittests`:
```nim
import testutils/unittests

suite "Waku ENR - Capabilities":
  test "check capabilities support":
    ## Given
    let bitfield: CapabilitiesBitfield = 0b0000_1101u8
    
    ## Then
    check:
      bitfield.supportsCapability(Capabilities.Relay)
      not bitfield.supportsCapability(Capabilities.Store)
```

### Code Formatting
**Mandatory**: All code must be formatted with `nph` (vendored in `vendor/nph`)
```bash
# Format specific file
make nph/waku/waku_core.nim

# Install git pre-commit hook (auto-formats on commit)
make install-nph
```
Don't worry about formatting details - nph handles this automatically (especially with the pre-commit hook). Focus on semantic correctness.

### Logging
Uses `chronicles` library with compile-time configuration:
```nim
import chronicles

logScope:
  topics = "waku lightpush"

info "handling request", peerId = peerId, topic = pubsubTopic
error "request failed", error = msg
```

Compile with log level:
```bash
nim c -d:chronicles_log_level=TRACE myfile.nim
```


## Code Conventions

### Naming
- **Files/Directories**: `snake_case` (e.g., `waku_lightpush`, `peer_manager`)
- **Procedures**: `camelCase` (e.g., `handleRequest`, `pushMessage`)
- **Types**: `PascalCase` (e.g., `WakuFilter`, `PubsubTopic`)
- **Constants**: `PascalCase` (e.g., `MaxContentTopicsPerRequest`)

### Imports Organization
Group imports: stdlib, external libs, internal modules:
```nim
import
  std/[options, sequtils],      # stdlib
  results, chronicles, chronos,  # external
  libp2p/peerid
import
  ../node/peer_manager,          # internal (separate import block)
  ../waku_core,
  ./common
```

### Async Programming
Uses **chronos**, not stdlib `asyncdispatch`:
```nim
proc handleRequest(
    wl: WakuLightPush, peerId: PeerId
): Future[WakuLightPushResult] {.async.} =
  let res = await wl.pushHandler(peerId, pubsubTopic, message)
  return res
```

### Error Handling
nwaku uses **both** Result types and exceptions:

**Result types** (nim-results) for protocol/API-level errors:
```nim
proc subscribe(
    wf: WakuFilter, peerId: PeerID
): Future[FilterSubscribeResult] {.async.} =
  if contentTopics.len > MaxContentTopicsPerRequest:
    return err(FilterSubscribeError.badRequest("exceeds maximum"))
  
  # Handle Result with isOkOr
  (await wf.subscriptions.addSubscription(peerId, criteria)).isOkOr:
    return err(FilterSubscribeError.serviceUnavailable(error))
  
  ok()
```

**Exceptions** still used for:
- chronos async failures (CancelledError, etc.)
- Database/system errors
- Library interop

Most files start with `{.push raises: [].}` to disable exception tracking, then use try/catch where needed.

### Pragma Usage
```nim
{.push raises: [].}  # Disable default exception tracking (at file top)

proc myProc(): Result[T, E] {.async.} =  # Async proc
```

### Protocol Inheritance
Protocols inherit from libp2p's `LPProtocol`:
```nim
type WakuLightPush* = ref object of LPProtocol
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager
  pushHandler*: PushMessageHandler
```

### Type Visibility
- Public exports use `*` suffix: `type WakuFilter* = ...`
- Fields without `*` are module-private

## Common Workflows

### Adding a New Protocol
1. Create directory: `waku/waku_myprotocol/`
2. Define core files:
   - `rpc.nim` - Message types
   - `rpc_codec.nim` - Protobuf encoding
   - `protocol.nim` - Protocol handler
   - `client.nim` - Client API
   - `common.nim` - Shared types
3. Define protocol type in `protocol.nim`:
   ```nim
   type WakuMyProtocol* = ref object of LPProtocol
     peerManager: PeerManager
     # ... fields
   ```
4. Implement request handler
5. Mount in WakuNode (`waku/node/waku_node.nim`)
6. Add tests in `tests/waku_myprotocol/`
7. Export module via `waku/waku_myprotocol.nim`

### Adding a REST API Endpoint
1. Define handler in `waku/waku_api/rest/myprotocol/`
2. Implement endpoint following pattern:
   ```nim
   proc installMyProtocolApiHandlers*(
       router: var RestRouter, node: WakuNode
   ) =
     router.api(MethodGet, "/waku/v2/myprotocol/endpoint") do () -> RestApiResponse:
       # Implementation
       return RestApiResponse.jsonResponse(data, status = Http200)
   ```
3. Register in `waku/waku_api/handlers.nim`

### Adding Database Migration
For message_store (SQLite):
1. Create `migrations/message_store/NNNNN_description.up.sql`
2. Create corresponding `.down.sql` for rollback
3. Increment version number sequentially
4. Test migration locally before committing

For PostgreSQL: add in `migrations/message_store_postgres/`

### Running Single Test During Development
```bash
# Build test binary
make test/tests/waku_filter_v2/test_waku_client.nim

# Binary location
./build/tests/waku_filter_v2/test_waku_client.nim.bin

# Or combine
make test tests/waku_filter_v2/test_waku_client.nim "specific test name"
```

### Debugging with Chronicles
Set log level and filter topics:
```bash
nim c -r \
  -d:chronicles_log_level=TRACE \
  -d:chronicles_disabled_topics="eth,dnsdisc" \
  tests/mytest.nim
```

## Key Constraints

### Vendor Directory
- **Never edit directly** - auto-generated from git submodules
- Update after pull: `make update`
- Managed by `nimbus-build-system`

### Chronicles Performance
- Log level configured **at compile time** for performance
- Runtime filtering available but use sparingly: `-d:chronicles_runtime_filtering=on`
- Default sinks optimized for production

### Memory Management
- Uses `refc` (reference counting with cycle collection)
- Automatically enforced by build system (hardcoded in `waku.nimble`)
- Don't override unless you know what you're doing (breaks compatibility)

### RLN Dependencies
- RLN code requires Rust (explains Rust imports in some modules)
- Pre-built `librln` libraries checked into repo

## Quick Reference

**Language**: Nim 2.2.4+ | **License**: MIT or Apache 2.0 | **Version**: 0.36.0

### Important Files
- `Makefile` - Primary build interface
- `waku.nimble` - Package definition and build tasks (called via nimbus-build-system)
- `vendor/nimbus-build-system/` - Status's build framework
- `waku/node/waku_node.nim` - Core node implementation
- `apps/wakunode2/wakunode2.nim` - Main CLI application
- `waku/factory/waku_conf.nim` - Configuration types
- `library/libwaku.nim` - C bindings entry point

### Testing Entry Points
- `tests/all_tests_waku.nim` - All Waku protocol tests
- `tests/all_tests_wakunode2.nim` - Node application tests
- `tests/all_tests_common.nim` - Common utilities tests

### Key Dependencies
- `chronos` - Async framework
- `nim-results` - Result type for error handling
- `chronicles` - Logging
- `libp2p` >= 1.13.0 - P2P networking
- `confutils` - CLI argument parsing
- `presto` - REST server
- `nimcrypto` - Cryptographic primitives


