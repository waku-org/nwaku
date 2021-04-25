# libwaku
#
# Exposes a C API that can be used by other environment than C.

# TODO Start a node
# TODO Mock info call
# TODO Write header file
# TODO Write example C code file
# TODO Wrap info call
# TODO Init a node

# proc info*(node: WakuNode): WakuInfo =
proc info(foo: string): string {.exportc.} =
  let s = "info about waku node" & foo
  echo s
  return s

proc echo() {.exportc.} =
 echo "echo"
