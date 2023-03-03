{.used.}

import
  stew/results,
  testutils/unittests
import
  ../../waku/v2/protocol/waku_message/topics

suite "Waku Message - Topics namespacing":

  test "Stringify namespaced topic":
    ## Given
    var ns = NamespacedTopic()
    ns.application = "waku"
    ns.version = "2"
    ns.name = "default-waku"
    ns.encoding = "proto"

    ## When
    let topic = $ns

    ## Then
    check:
      topic == "/waku/2/default-waku/proto"

  test "Parse topic string - Valid string":
    ## Given
    let topic = "/waku/2/default-waku/proto"

    ## When
    let nsRes = NamespacedTopic.parse(topic)

    ## Then
    check nsRes.isOk()

    let ns = nsRes.get()
    check:
      ns.application == "waku"
      ns.version == "2"
      ns.name == "default-waku"
      ns.encoding == "proto"

  test "Parse topic string - Invalid string: doesn't start with slash":
    ## Given
    let topic = "waku/2/default-waku/proto"

    ## When
    let ns = NamespacedTopic.parse(topic)

    ## Then
    check ns.isErr()
    let err = ns.tryError()
    check:
      err.kind == NamespacingErrorKind.InvalidFormat
      err.cause == "topic must start with slash"

  test "Parse topic string - Invalid string: not namespaced":
    ## Given
    let topic = "/this-is-not-namespaced"

    ## When
    let ns = NamespacedTopic.parse(topic)

    ## Then
    check ns.isErr()
    let err = ns.tryError()
    check:
      err.kind == NamespacingErrorKind.InvalidFormat
      err.cause == "invalid topic structure"


  test "Parse topic string - Invalid string: missing encoding part":
    ## Given
    let topic = "/waku/2/default-waku"

    ## When
    let ns = NamespacedTopic.parse(topic)

    ## Then
    check ns.isErr()
    let err = ns.tryError()
    check:
      err.kind == NamespacingErrorKind.InvalidFormat
      err.cause == "invalid topic structure"

  test "Parse topic string - Invalid string: too many parts":
    ## Given
    let topic = "/waku/2/default-waku/proto/33"

    ## When
    let ns = NamespacedTopic.parse(topic)

    ## Then
    check ns.isErr()
    let err = ns.tryError()
    check:
      err.kind == NamespacingErrorKind.InvalidFormat
      err.cause == "invalid topic structure"

