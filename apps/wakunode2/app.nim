# TODO: Uncomment the exceptions check once the refactoring work is done
# when (NimMajor, NimMinor) < (1, 4):
#   {.push raises: [Defect].}
# else:
#   {.push raises: [].}

import
  std/[options, strutils, sequtils],
  stew/results,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/nameresolving/dnsresolver,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/peerid,
  eth/keys,
  eth/net/nat
import
  ../../waku/common/sqlite,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/node/peer_manager/peer_store/waku_peer_storage,
  ../../waku/v2/node/peer_manager/peer_store/migrations as peer_store_sqlite_migrations,
  ../../waku/v2/protocol/waku_archive,
  ../../waku/v2/protocol/waku_archive/driver/queue_driver,
  ../../waku/v2/protocol/waku_archive/driver/sqlite_driver,
  ../../waku/v2/protocol/waku_archive/driver/sqlite_driver/migrations as archive_driver_sqlite_migrations,
  ../../waku/v2/protocol/waku_archive/retention_policy,
  ../../waku/v2/protocol/waku_archive/retention_policy/retention_policy_capacity,
  ../../waku/v2/protocol/waku_archive/retention_policy/retention_policy_time,
  ../../waku/v2/protocol/waku_dnsdisc,
  ../../waku/v2/utils/peers,
  ./config


type AppResult[T] = Result[T, string]


## SQLite database

proc setupDatabaseConnection(dbUrl: string): AppResult[Option[SqliteDatabase]] =
  ## dbUrl mimics SQLAlchemy Database URL schema
  ## See: https://docs.sqlalchemy.org/en/14/core/engines.html#database-urls
  if dbUrl == "" or dbUrl == "none":
    return ok(none(SqliteDatabase))

  let dbUrlParts = dbUrl.split("://", 1)
  let
    engine = dbUrlParts[0]
    path = dbUrlParts[1]

  let connRes = case engine
    of "sqlite":
      # SQLite engine
      # See: https://docs.sqlalchemy.org/en/14/core/engines.html#sqlite
      SqliteDatabase.new(path)

    else:
      return err("unknown database engine")

  if connRes.isErr():
    return err("failed to init database connection: " & connRes.error)

  ok(some(connRes.value))


## Peer persistence

const PeerPersistenceDbUrl = "sqlite://peers.db"

proc setupPeerStorage(): AppResult[Option[WakuPeerStorage]] =
  let db = ?setupDatabaseConnection(PeerPersistenceDbUrl)

  ?peer_store_sqlite_migrations.migrate(db.get())

  let res = WakuPeerStorage.new(db.get())
  if res.isErr():
    return err("failed to init peer store" & res.error)

  ok(some(res.value))


## Waku archive

proc gatherSqlitePageStats(db: SqliteDatabase): AppResult[(int64, int64, int64)] =
  let
    pageSize = ?db.getPageSize()
    pageCount = ?db.getPageCount()
    freelistCount = ?db.getFreelistCount()

  ok((pageSize, pageCount, freelistCount))

proc performSqliteVacuum(db: SqliteDatabase): AppResult[void] =
  ## SQLite database vacuuming
  # TODO: Run vacuuming conditionally based on database page stats
  # if (pageCount > 0 and freelistCount > 0):

  debug "starting sqlite database vacuuming"

  let resVacuum = db.vacuum()
  if resVacuum.isErr():
    return err("failed to execute vacuum: " & resVacuum.error)

  debug "finished sqlite database vacuuming"

proc setupWakuArchiveRetentionPolicy(retentionPolicy: string): AppResult[Option[RetentionPolicy]] =
  if retentionPolicy == "" or retentionPolicy == "none":
    return ok(none(RetentionPolicy))

  let rententionPolicyParts = retentionPolicy.split(":", 1)
  let
    policy = rententionPolicyParts[0]
    policyArgs = rententionPolicyParts[1]


  if policy == "time":
    var retentionTimeSeconds: int64
    try:
      retentionTimeSeconds = parseInt(policyArgs)
    except ValueError:
      return err("invalid time retention policy argument")

    let retPolicy: RetentionPolicy = TimeRetentionPolicy.init(retentionTimeSeconds)
    return ok(some(retPolicy))

  elif policy == "capacity":
    var retentionCapacity: int
    try:
      retentionCapacity = parseInt(policyArgs)
    except ValueError:
      return err("invalid capacity retention policy argument")

    let retPolicy: RetentionPolicy = CapacityRetentionPolicy.init(retentionCapacity)
    return ok(some(retPolicy))

  else:
    return err("unknown retention policy")

proc setupWakuArchiveDriver(dbUrl: string, vacuum: bool, migrate: bool): AppResult[ArchiveDriver] =
  let db = ?setupDatabaseConnection(dbUrl)

  if db.isSome():
    # SQLite vacuum
    # TODO: Run this only if the database engine is SQLite
    let (pageSize, pageCount, freelistCount) = ?gatherSqlitePageStats(db.get())
    debug "sqlite database page stats", pageSize=pageSize, pages=pageCount, freePages=freelistCount

    if vacuum and (pageCount > 0 and freelistCount > 0):
      ?performSqliteVacuum(db.get())

  # Database migration
    if migrate:
      ?archive_driver_sqlite_migrations.migrate(db.get())

  if db.isSome():
    debug "setting up sqlite waku archive driver"
    let res = SqliteDriver.new(db.get())
    if res.isErr():
      return err("failed to init sqlite archive driver: " & res.error)

    ok(res.value)

  else:
    debug "setting up in-memory waku archive driver"
    let driver = QueueDriver.new()  # Defaults to a capacity of 25.000 messages
    ok(driver)


## Retrieve dynamic bootstrap nodes (DNS discovery)

proc retrieveDynamicBootstrapNodes*(dnsDiscovery: bool, dnsDiscoveryUrl: string, dnsDiscoveryNameServers: seq[ValidIpAddress]): AppResult[seq[RemotePeerInfo]] =

  if dnsDiscovery and dnsDiscoveryUrl != "":
    # DNS discovery
    debug "Discovering nodes using Waku DNS discovery", url=dnsDiscoveryUrl

    var nameServers: seq[TransportAddress]
    for ip in dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain=domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl, resolver)
    if wakuDnsDiscovery.isOk():
      return wakuDnsDiscovery.get().findPeers()
        .mapErr(proc (e: cstring): string = $e)
    else:
      warn "Failed to init Waku DNS discovery"

  debug "No method for retrieving dynamic bootstrap nodes specified."
  ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default
