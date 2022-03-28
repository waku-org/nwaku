# nim-waku

## Introduction

The nim-waku repository implements Waku v1 and v2, and provides tools related to it.

- A Nim implementation of the [Waku v1 protocol](https://specs.vac.dev/waku/waku.html).
- A Nim implementation of the [Waku v2 protocol](https://specs.vac.dev/specs/waku/v2/waku-v2.html).
- CLI applications `wakunode` and `wakunode2` that allows you to run a Waku v1 or v2 node.
- Examples of Waku v1 and v2 usage.
- Various tests of above.

For more details on Waku v1 and v2, see their respective home folders:

- [Waku v1](waku/v1/README.md)
- [Waku v2](waku/v2/README.md)

## How to Build & Run

These instructions are generic and apply to both Waku v1 and v2. For more
detailed instructions, see Waku v1 and v2 home above.

### Prerequisites

* GNU Make, Bash and the usual POSIX utilities. Git 2.9.4 or newer.
* [Rust](https://www.rust-lang.org/)

More information on the installation of these can be found [here](https://github.com/status-im/nimbus#prerequisites).

### Wakunode

```bash
# The first `make` invocation will update all Git submodules.
# You'll run `make update` after each `git pull`, in the future, to keep those submodules up to date.
make wakunode1 wakunode2

# See available command line options
./build/wakunode --help
./build/wakunode2 --help

# Connect the client directly with the Status test fleet
./build/wakunode --log-level:debug --discovery:off --fleet:test --log-metrics
# TODO Equivalent for v2 
```

### Waku Protocol Test Suite

```bash
# Run all the Waku v1 and v2 tests
make test
```

### Examples

Examples can be found in the examples folder. For Waku v2, there is a fully
featured chat example.

### Bugs, Questions & Features

For an inquiry, or if you would like to propose new features, feel free to [open a general issue](https://github.com/status-im/nim-waku/issues/new/).

For bug reports, please [tag your issue with the `bug` label](https://github.com/status-im/nim-waku/issues/new/).

If you believe the reported issue requires critical attention, please [use the `critical` label](https://github.com/status-im/nim-waku/issues/new?labels=critical,bug) to assist with triaging.

To get help, or participate in the conversation, join the [Vac Discord](https://discord.gg/KNj3ctuZvZ) server.
