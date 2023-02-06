{.used.}

import
  stew/results,
  testutils/unittests
import
  ../../waku/v2/utils/namespacing

suite "Namespacing utils":

  test "Create from string":
    # Expected case
    let nsRes = NamespacedTopic.fromString("/waku/2/default-waku/proto")

    require nsRes.isOk()

    let ns = nsRes.get()

    check:
      ns.application == "waku"
      ns.version == "2"
      ns.topicName == "default-waku"
      ns.encoding == "proto"

  test "Invalid string - Topic is not namespaced":
    check NamespacedTopic.fromString("this-is-not-namespaced").isErr()

  test "Invalid string - Topic should start with slash":
    check NamespacedTopic.fromString("waku/2/default-waku/proto").isErr()

  test "Invalid string - Topic has too few parts":
    check NamespacedTopic.fromString("/waku/2/default-waku").isErr()

  test "Invalid string - Topic has too many parts":
    check NamespacedTopic.fromString("/waku/2/default-waku/proto/2").isErr()

  test "Stringify namespaced topic":
    var ns = NamespacedTopic()

    ns.application = "waku"
    ns.version = "2"
    ns.topicName = "default-waku"
    ns.encoding = "proto"

    check:
      $ns == "/waku/2/default-waku/proto"
