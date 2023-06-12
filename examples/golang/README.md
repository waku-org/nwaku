
## Summary

This is a simple example on how to integrate the `libwaku.so` library in a
Golang app.

[cgo](https://pkg.go.dev/cmd/cgo) is used in this example.

There are comments in the file `waku.go` that are considered by the cgo itself and
shouldn't be arbitrarily changed unless required.

The important comments in the `waku.go` are the ones above the `import "C"` statement and
above the `eventHandler` function.

## libwaku.so

Before running the example, make sure to properly export the LD_LIBRARY_PATH
with the path that contains the target `libwaku.so` library.

e.g.
From the repo's root folder:
```code
export LD_LIBRARY_PATH=build
```

In order to build the `libwaku.so`, go to the repo's root folder and
invoke the next command, which will create `libwaku.so` under the `build` folder:

```code
make libwaku
```
This will both generate the `libwaku.so` file under the `build` and
the `examples/golang/` fodler.
It is important to notice that there should be a `libwaku.so` at the same level as the `waku.go` file as per how `waku.go` is implemented.

## libwaku.h & nimbase.h

This is the header associated with the `libwaku.so`.

The `libwaku.h` is auto-generated when building the `libwaku.so`.

Everytime a new `libwaku.so` is built, the `libwaku.h` file gets stored in
<REPO_ROOT_DIR>/nimcache/release/libwaku/libwaku.h.

However, the `libwaku.h` is kept version-controlled just for commodity.
It might be needed to update the `libwaku.h` header if a new function
is added to the `libwaku.so` or any signature is modified.

## Running the example

- Open a terminal
- cd <...>/nwaku/
- ```code
  export LD_LIBRARY_PATH=build
  ```
- ```code
  go run examples/golang/waku.go
  ```
  note: `--help` can be appended to the end of the previous command to get better insight of possible params
