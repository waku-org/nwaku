{.used.}

import
  testutils/unittests,
  chronos

import
  ../testlib/wakunode,
  ../../waku/factory/node_factory

suite "Node Factory":
  test "Set up a node based on default configurations":    
    let conf = defaultTestWakuNodeConf()

    let node = setupNode(conf).valueOr:
      raiseAssert error
    
    check:
      not node.isNil()
      node.wakuArchive.isNil()
      node.wakuStore.isNil()
      not node.wakuStoreClient.isNil()
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
    



