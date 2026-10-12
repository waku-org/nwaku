## Resolves a host name off the event loop: libpq resolves host names with a
## blocking getaddrinfo, which stalls every other task while the resolver is slow.
{.push raises: [].}

import std/[nativesockets, net, strutils, typedthreads]
import chronos, chronos/threadsync, results

const MaxHostLen = 256

type ResolveJob = object
  host: array[MaxHostLen, char]
  resolved: array[512, char] ## NUL terminated, comma separated addresses
  found: bool
  signal: ThreadSignalPtr

type ResolveThread = Thread[ptr ResolveJob]

proc resolveWorker(job: ptr ResolveJob) {.thread, nimcall.} =
  try:
    let addrInfo = getAddrInfo(
      $cast[cstring](addr job.host[0]), Port(0), AF_UNSPEC, SOCK_STREAM, IPPROTO_TCP
    )
    if not addrInfo.isNil():
      ## Every address is kept, in the resolver's order, so that libpq still
      ## falls back from one to the next as it does when it resolves itself.
      var joined = ""
      var node = addrInfo
      while not node.isNil():
        let text = getAddrString(node.ai_addr)
        let candidate =
          if joined.len == 0:
            text
          else:
            joined & "," & text
        if text.len > 0 and text notin joined.split(',') and
            candidate.len < job.resolved.len:
          joined = candidate
        node = node.ai_next

      for i in 0 ..< joined.len:
        job.resolved[i] = joined[i]
      job.found = joined.len > 0
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
  ## The comma separated IP addresses of `host`, or "" when libpq needs no
  ## lookup: an IP literal or a unix socket directory.
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
