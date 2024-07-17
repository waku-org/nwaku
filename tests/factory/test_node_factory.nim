{.used.}

import testutils/unittests, chronos

import ../testlib/wakunode, waku/factory/node_factory, waku/waku_node

suite "Node Factory":
  test "Set up a node based on default configurations":
    let conf = defaultTestWakuNodeConf()

    let node = setupNode(conf).valueOr:
      raiseAssert error

    check:
      not node.isNil()
      node.wakuArchive.isNil()
      node.wakuStore.isNil()
      node.wakuFilter.isNil()
      node.wakuStoreClient.isNil()
      not node.rendezvous.isNil()

  test "Set up a node with Store enabled":
    var conf = defaultTestWakuNodeConf()
    conf.store = true

    let node = setupNode(conf).valueOr:
      raiseAssert error

    check:
      not node.isNil()
      not node.wakuStore.isNil()
      not node.wakuArchive.isNil()

test "Set up a node with Filter enabled":
  var conf = defaultTestWakuNodeConf()
  conf.filter = true

  let node = setupNode(conf).valueOr:
    raiseAssert error

  check:
    not node.isNil()
    not node.wakuFilter.isNil()

test "Start a node based on default configurations":
  let conf = defaultTestWakuNodeConf()

  let node = setupNode(conf).valueOr:
    raiseAssert error

  assert not node.isNil(), "Node can't be nil"

  let startRes = catch:
    (waitFor startNode(node, conf))

  assert not startRes.isErr(), "Exception starting node"
  assert startRes.get().isOk(), "Error starting node " & startRes.get().error

  check:
    node.started == true

  ## Cleanup
  waitFor node.stop()
