import chronicles
import ../../waku_core/message/message

type PublishObserver* = ref object of RootObj

method onMessagePublished*(
    self: PublishObserver, pubsubTopic: string, message: WakuMessage
) {.base, gcsafe, raises: [].} =
  error "onMessagePublished not implemented"
