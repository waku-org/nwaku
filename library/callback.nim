
type
  WakuCallBack* = proc(callerRet: cint,
                       msg: ptr cchar,
                       len: csize_t) {.cdecl, gcsafe.}
