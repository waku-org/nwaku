import std/[json, options, strutils]
import results
import ../waku/waku_core/time

proc getProtoInt64*(node: JsonNode, key: string): Option[int64] =
  let (value, ok) =
    if node.hasKey(key):
      if node[key].kind == JString:
        (parseBiggestInt(node[key].getStr()), true)
      else:
        (node[key].getBiggestInt(), true)
    else:
      (0, false)

  if ok:
    return some(value)

  return none(int64)
