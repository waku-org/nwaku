import 
    testutils/unittests,
    stew/results,
    chronicles,
    options,
    ../../waku/v2/protocol/waku_rln_relay/protocol_types,
    ../../waku/v2/protocol/waku_rln_relay/utils,
    ../../waku/v2/protocol/waku_rln_relay/group_manager/static/group_manager

import
  stew/shims/net,
  chronos,
  libp2p/crypto/crypto,
  eth/keys,
  discovery/dnsdisc/builder

proc generateCredentials(rlnInstance: ptr RLN): IdentityCredential =
    let credRes = membershipKeyGen(rlnInstance)
    return credRes.get()

proc generateCredentials(rlnInstance: ptr RLN, n: int): seq[IdentityCredential] =
    var credentials: seq[IdentityCredential] 
    for i in 0 ..< n:
        credentials.add(generateCredentials(rlnInstance))
    return credentials

suite "Static group manager":
    asyncTest "should initialize successfully":
        let rlnInstanceRes = createRlnInstance()
        require:
            rlnInstanceRes.isOk()

        let rlnInstance = rlnInstanceRes.get()
        let credentials = generateCredentials(rlnInstance, 10)
        let staticConfig = StaticGroupManagerConfig(groupSize: 10,
                                            membershipIndex: 5,
                                            groupKeys: credentials)

        let manager = StaticGroupManager(config: staticConfig,
                                         rlnInstance: rlnInstance)
        await manager.init()
        check:
            manager.idCredentials.isSome()
            manager.config.groupKeys.len == 10
            manager.config.groupSize == 10
            manager.config.membershipIndex == 5
            manager.config.groupKeys[5] == manager.idCredentials.get()
            manager.latestIndex == 9

    