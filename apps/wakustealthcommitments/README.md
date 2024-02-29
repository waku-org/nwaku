# wakustealthcommitments

This application/tool/protocol is used to securely communicate requests and responses for the [Stealth Address Scheme](https://eips.ethereum.org/EIPS/eip-5564)

Uses TWN config as default, and content topic: `/wakustealthcommitments/1/app/proto"`

## Usage

1. `make -j16 wakustealthcommitments`
2. 
```sh
./build/wakustealthcommitments \
    --rln-relay-eth-client-address:<insert http rpc url> \
    --rln-relay-cred-path:<path-to-credentials-file> \
    --rln-relay-cred-password:<password-of-credentials-file>
```

This service listens for requests for stealth commitment/address generation, 
partakes in the generation of said stealth commitment and then distributes the response to the mesh.

