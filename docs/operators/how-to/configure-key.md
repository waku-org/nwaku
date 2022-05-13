# Generate and configure a node key

By default a node will generate a new, random key pair each time it boots,
resulting in a different public libp2p `multiaddrs` after each restart.

To maintain consistent addressing across restarts,
it is possible to configure the node with a previously generated private key using the `--nodekey` option.

```shell
wakunode2 --nodekey=<64_char_hex>
```

This option takes a [Secp256k1](https://en.bitcoin.it/wiki/Secp256k1) private key in 64 char hexstring format.

One way such a key can be generated on Linux systems using the `/dev/urandom` pseudorandom generator is by using `openssl`,
coupled with some standard utilities to extract the 32 byte private key in hex format.

```shell
openssl ecparam -genkey -name secp256k1 -rand /dev/urandom -out my_private_key.pem
openssl ec -in my_private_key.pem -outform DER | tail -c +8 | head -c 32| xxd -p -c 32
```

Example output:

```shell
read EC key
writing EC key
0c687bb8a7984c770b566eae08520c67f53d302f24b8d4e5e47cc479a1e1ce23
```

where the key `0c687bb8a7984c770b566eae08520c67f53d302f24b8d4e5e47cc479a1e1ce23` can be used as `nodekey`.

```shell
wakunode2 --nodekey=0c687bb8a7984c770b566eae08520c67f53d302f24b8d4e5e47cc479a1e1ce23
```