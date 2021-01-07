# FAQ

## How do I see what address a node is listening for?

Grep for "Listening on". It should be printed at INFO level at the beginning. E.g. from Kibana:

`Oct 7, 2020 @ 23:17:00.383INF 2020-10-07 23:17:00.375+00:00 Listening on                               topics="wakunode" tid=1 file=wakunode2.nim:140 full=/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS`

## How do I find out node addresses at the test cluster?

The easiest way is to use `jq` and query the fleets registry that Status operates:

```
curl -s https://fleets.status.im | jq '.fleets["wakuv2.test"]'

# Output
{
  "waku": {
    "node-01.ac-cn-hongkong-c.wakuv2.test": "/ip4/0.0.0.0/tcp/30303/p2p/16Uiu2HAmSyrYVycqBCWcHyNVQS6zYQcdQbwyov1CDijboVRsQS37",
    "node-01.do-ams3.wakuv2.test": "/ip4/0.0.0.0/tcp/30303/p2p/16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ",
    "node-01.gc-us-central1-a.wakuv2.test": "/ip4/0.0.0.0/tcp/30303/p2p/16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ"
  }
}
```
