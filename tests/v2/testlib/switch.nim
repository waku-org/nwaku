import
  std/options,
  libp2p/switch,
  libp2p/builders
import
  ../../test_helpers

proc newTestSwitch*(key=none(PrivateKey), address=none(MultiAddress)): Switch =
  let peerKey = key.get(PrivateKey.random(ECDSA, rng[]).get())
  let peerAddr = address.get(MultiAddress.init("/ip4/127.0.0.1/tcp/0").get()) 
  return newStandardSwitch(some(peerKey), addrs=peerAddr)