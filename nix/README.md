# Usage

## Shell

A development shell can be started using:
```sh
nix develop
```

## Building

To build a Codex you can use:
```sh
nix build '.#default'
```
The `?submodules=1` part should eventually not be necessary.
For more details see:
https://github.com/NixOS/nix/issues/4423

It can be also done without even cloning the repo:
```sh
nix build 'git+https://github.com/waku-org/nwaku'
```

>:warning: For Nix versions below `2.27` you will need to add `?submodules=1` to URL.

## Running

```sh
nix run 'git+https://github.com/waku-org/nwaku''
```

## Testing

```sh
nix flake check .
```
