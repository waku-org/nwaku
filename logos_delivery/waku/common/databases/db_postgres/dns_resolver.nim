## Resolves a host name off the event loop: libpq resolves host names with a
## blocking getaddrinfo, which stalls every other task while the resolver is slow.
{.push raises: [].}

import std/[nativesockets, net, typedthreads]
import chronos, chronos/threadsync, results

const MaxHostLen = 256

type ResolveJob = object
  host: array[MaxHostLen, char]
  resolved: array[64, char] ## NUL terminated text form of the address
  found: bool
  signal: ThreadSignalPtr

type ResolveThread = Thread[ptr ResolveJob]

proc resolveWorker(job: ptr ResolveJob) {.thread, nimcall.} =
  try:
    let addrInfo = getAddrInfo($cast[cstring](addr job.host[0]), Port(0), AF_UNSPEC)
    if not addrInfo.isNil():
      let text = getAddrString(addrInfo.ai_addr)
      if text.len > 0 and text.len < job.resolved.len:
        for i in 0 ..< text.len:
          job.resolved[i] = text[i]
        job.found = true
      freeAddrInfo(addrInfo)
  except CatchableError:
    discard

  discard job.signal.fireSync()

proc reapResolver(
    job: ptr ResolveJob, thread: ptr ResolveThread, res: Future[Result[string, string]]
) {.async: (raises: []).} =
  ## Owns the job and the thread until the worker is done, even when the caller
  ## was cancelled, so that nothing is freed under a running thread.
  try:
    await job.signal.wait()
  except CatchableError:
    discard

  joinThread(thread[])

  let host = $cast[cstring](addr job.host[0])
  let outcome =
    if job.found:
      Result[string, string].ok($cast[cstring](addr job.resolved[0]))
    else:
      Result[string, string].err("could not resolve the host: " & host)

  discard job.signal.close()
  deallocShared(thread)
  deallocShared(job)

  if not res.finished():
    res.complete(outcome)

proc resolveHostAddr*(host: string): Future[Result[string, string]] {.async.} =
  ## The IP address of `host` as text, or "" when libpq needs no lookup: an IP
  ## literal or a unix socket directory.
  if host.len == 0 or host[0] == '/' or host.isIpAddress():
    return ok("")

  if host.len >= MaxHostLen:
    return err("the host name is too long: " & $host.len)

  let signal = ThreadSignalPtr.new().valueOr:
    return err("could not create the resolver signal: " & error)

  let job = cast[ptr ResolveJob](allocShared0(sizeof(ResolveJob)))
  job.signal = signal
  for i in 0 ..< host.len:
    job.host[i] = host[i]

  let thread = cast[ptr ResolveThread](allocShared0(sizeof(ResolveThread)))
  try:
    createThread(thread[], resolveWorker, job)
  except CatchableError:
    discard signal.close()
    deallocShared(thread)
    deallocShared(job)
    return err("could not start the resolver thread")

  let res = newFuture[Result[string, string]]("resolveHostAddr")
  asyncSpawn reapResolver(job, thread, res)

  return await res
