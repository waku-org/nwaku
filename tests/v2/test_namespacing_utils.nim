{.used.}

import
  testutils/unittests,
  chronos,
  stew/results,
  ../../waku/v2/utils/namespacing

procSuite "Namespacing utils":

  asyncTest "Create from string":
    # Expected case
    let ns = NamespacedTopic.fromString("/waku/2/default-waku/proto").tryGet()
    
    check:
      ns.application == "waku"
      ns.version == "2"
      ns.topicName == "default-waku"
      ns.encoding == "proto"
    
    # Invalid cases
    expect ValueError:
      # Topic should be namespaced
      discard NamespacedTopic.fromString("this-is-not-namespaced").tryGet()
    
    expect ValueError:
      # Topic should start with '/'
      discard NamespacedTopic.fromString("waku/2/default-waku/proto").tryGet()

    expect ValueError:
      # Topic has too few parts
      discard NamespacedTopic.fromString("/waku/2/default-waku").tryGet()

    expect ValueError:
      # Topic has too many parts
      discard NamespacedTopic.fromString("/waku/2/default-waku/proto/2").tryGet()

  asyncTest "Stringify namespaced topic":
    var ns = NamespacedTopic()

    ns.application = "waku"
    ns.version = "2"
    ns.topicName = "default-waku"
    ns.encoding = "proto"
    
    check:
      $ns == "/waku/2/default-waku/proto"
