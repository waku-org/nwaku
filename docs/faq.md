# FAQ

## Where do I find cluster node logs? (internal)

At [Kibana](https://kibana.status.im/app/kibana#/discover?_g=(filters:!(),refreshInterval:(pause:!t,value:0),time:(from:'2020-09-09T20:21:49.910Z',to:now))&_a=(columns:!(message,severity_name),filters:!(('$state':(store:appState),meta:(alias:!n,disabled:!f,index:d6db7610-60fd-11e9-98fa-2f101d13f938,key:program.keyword,negate:!f,params:(query:docker%2Fnim-waku-node),type:phrase),query:(match_phrase:(program.keyword:docker%2Fnim-waku-node))),('$state':(store:appState),meta:(alias:!n,disabled:!f,index:d6db7610-60fd-11e9-98fa-2f101d13f938,key:fleet.keyword,negate:!f,params:(query:wakuv2.test),type:phrase),query:(match_phrase:(fleet.keyword:wakuv2.test)))),index:d6db7610-60fd-11e9-98fa-2f101d13f938,interval:auto,query:(language:kuery,query:Listening),sort:!()))

Login with Github. For access issues, contact devops.

Modify search field and time window as appropriate.

## How do I see what address a node is listening for?

Grep for "Listening on". It should be printed at INFO level at the beginning. E.g. from Kibana:

`Oct 7, 2020 @ 23:17:00.383INF 2020-10-07 23:17:00.375+00:00 Listening on                               topics="wakunode" tid=1 file=wakunode2.nim:140 full=/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS`

## How do I update all submodules at once?

`git submodule foreach --recursive git submodule update --init`
