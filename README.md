# Nwaku

## Introduction

The nwaku repository implements Waku, and provides tools related to it.

- A Nim implementation of the [Waku (v2) protocol](https://specs.vac.dev/specs/waku/v2/waku-v2.html).
- CLI application `wakunode2` that allows you to run a Waku node.
- Examples of Waku usage.
- Various tests of above.

For more details see the [source code](waku/v2/README.md)

## How to Build & Run

These instructions are generic. For more detailed instructions, see the Waku source code above.

### Prerequisites

The standard developer tools, including a C compiler, GNU Make, Bash, and Git. More information on these installations can be found [here](https://docs.waku.org/guides/nwaku/build-source#install-dependencies).

### Wakunode

```bash
# The first `make` invocation will update all Git submodules.
# You'll run `make update` after each `git pull` in the future to keep those submodules updated.
make wakunode2

# See available command line options
./build/wakunode2 --help
```

For more on how to run `wakunode2`, refer to:
- [Run using binaries](https://docs.waku.org/guides/run-nwaku-node#download-the-binary)
- [Run using docker](https://docs.waku.org/guides/nwaku/run-docker)
- [Run using docker-compose](https://docs.waku.org/guides/nwaku/run-docker-compose)

### Waku Protocol Test Suite

```bash
# Run all the Waku tests
make test
```

### Examples

Examples can be found in the examples folder.
This includes a fully featured chat example.

### Tools

Different tools and their corresponding how-to guides can be found in the `tools` folder.

### Bugs, Questions & Features

For an inquiry, or if you would like to propose new features, feel free to [open a general issue](https://github.com/waku-org/nwaku/issues/new).

For bug reports, please [tag your issue with the `bug` label](https://github.com/waku-org/nwaku/issues/new).

If you believe the reported issue requires critical attention, please [use the `critical` label](https://github.com/waku-org/nwaku/issues/new?labels=critical,bug) to assist with triaging.

To get help, or participate in the conversation, join the [Waku Discord](https://discord.waku.org/) server.
