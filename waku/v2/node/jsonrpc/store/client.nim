when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[os, strutils],
  json_rpc/rpcclient
import
  ../../../waku_core,
  ../../../waku_store/rpc,
  ./types

export types


template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]

createRpcSigs(RpcHttpClient, sourceDir / "callsigs.nim")
