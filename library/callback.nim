import ./waku_thread/waku_thread

type WakuCallBack* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

template checkLibwakuParams*(ctx: ptr WakuContext, callback: WakuCallBack, userData: pointer) =
  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK
