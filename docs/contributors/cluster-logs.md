# Cluster node logs

These can be found in [Kibana](https://kibana.status.im/app/kibana#/discover?_g=(filters:!(),refreshInterval:(pause:!t,value:0),time:(from:'2020-09-09T20:21:49.910Z',to:now))&_a=(columns:!(message,severity_name),filters:!(('$state':(store:appState),meta:(alias:!n,disabled:!f,index:d6db7610-60fd-11e9-98fa-2f101d13f938,key:program.keyword,negate:!f,params:(query:docker%2Fnim-waku-node),type:phrase),query:(match_phrase:(program.keyword:docker%2Fnim-waku-node))),('$state':(store:appState),meta:(alias:!n,disabled:!f,index:d6db7610-60fd-11e9-98fa-2f101d13f938,key:fleet.keyword,negate:!f,params:(query:wakuv2.test),type:phrase),query:(match_phrase:(fleet.keyword:wakuv2.test)))),index:d6db7610-60fd-11e9-98fa-2f101d13f938,interval:auto,query:(language:kuery,query:Listening),sort:!())).

Login with Github. For access issues, contact devops.

Modify search field and time window as appropriate.

Notice that there are two clusters, test and production. There is also a Waku v1 cluster.


