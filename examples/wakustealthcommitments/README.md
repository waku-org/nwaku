# wakustealthcommitments

This application/tool/protocol is used to securely communicate requests and responses for the [Stealth Address Scheme](https://eips.ethereum.org/EIPS/eip-5564)

Uses TWN config as default, and content topic: `/wakustealthcommitments/1/app/proto`

## Usage

1. Clone the erc-5564-bn254 repo and build the static lib
```sh
gh repo clone rymnc/erc-5564-bn254
cd erc-5564-bn254
cargo build --release --all-features
cp ./target/release/liberc_5564_bn254.a <path-to-nwaku>
```

> ![NOTE]
> This static library also includes the rln ffi library, so you don't need to build it separately.
> This is because using both of them separately brings in a lot of duplicate symbols.

2. Build the wakustealthcommitments app
```sh
cd <path-to-nwaku>
source env.sh
nim c --out:build/wakustealthcommitments  --verbosity:0 --hints:off -d:chronicles_log_level=INFO -d:git_version="v0.24.0-rc.0-62-g7da25c" -d:release --passL:-lm --passL:liberc_5564_bn254.a --debugger:native examples/wakustealthcommitments/wakustealthcommitments.nim
```

3. 
```sh
./build/wakustealthcommitments \
    --rln-relay-eth-client-address:<insert http rpc url> \
    --rln-relay-cred-path:<path-to-credentials-file> \
    --rln-relay-cred-password:<password-of-credentials-file>
```

This service listens for requests for stealth commitment/address generation, 
partakes in the generation of said stealth commitment and then distributes the response to the mesh.

