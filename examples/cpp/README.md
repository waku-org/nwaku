## App description
This is a very simple example that shows how to invoke libwaku functions from a C++ program.

## Build
1. Open terminal
2. cd to nwaku root folder
3. make cppwaku_example -j8

This will create libwaku.so and cppwaku_example binary within the build folder.

## Run
1. Open terminal
2. cd to nwaku root folder
3. export LD_LIBRARY_PATH=build
4. `./build/cppwaku_example --host=0.0.0.0 --port=60001`

Use `./build/cppwaku_example --help` to see some other options.

