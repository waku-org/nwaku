# RLN

This is the development repo of rate limit nullifier zkSNARK circuits.

For details, see work in progress document [here](https://hackmd.io/tMTLMYmTR5eynw2lwK9n1w?view)

## Test

```
cargo test --release --features multicore rln_32 -- --nocapture
```

## Generate Test Keys

```
cargo run --release --example export_test_keys
```

## Wasm Support

### Build

```
wasm-pack build --release --target=nodejs --scope=rln --out-name=$PACKAGE --out-dir=$PACKAGE_DIR -- --features wasm
```

### Test

With wasm-pack:

```
wasm-pack test --release --node -- --features wasm
```

With cargo:

Follow the steps [here](https://rustwasm.github.io/docs/wasm-bindgen/wasm-bindgen-test/usage.html#appendix-using-wasm-bindgen-test-without-wasm-pack) before running the test, then run:

```
cargo test --release --target wasm32-unknown-unknown --features wasm
```