import std/tempfiles

import ../../../waku/waku_rln_relay/[rln, protocol_types]

proc createRLNInstanceWrapper*(): RLNResult =
  return createRlnInstance(tree_path = genTempPath("rln_tree", "waku_rln_relay"))
