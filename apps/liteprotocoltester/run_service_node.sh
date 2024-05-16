#!/bin/sh

echo "I am a service node"
IP=$(ip a | grep "inet " | grep -Fv 127.0.0.1 | sed 's/.*inet \([^/]*\).*/\1/')

echo "Service node IP: ${IP}"

exec /usr/bin/wakunode\
      --relay=true\
      --filter=true\
      --lightpush=true\
      --store=false\
      --rest=true\
      --rest-admin=true\
      --rest-private=true\
      --rest-address=0.0.0.0\
      --rest-allow-origin="*"\
      --keep-alive=true\
      --max-connections=300\
      --dns-discovery=true\
      --discv5-discovery=true\
      --discv5-enr-auto-update=True\
      --log-level=DEBUG\
      --metrics-server=True\
      --metrics-server-address=0.0.0.0\
      --nodekey=e3f5e64568b3a612dee609f6e7c0203c501dab6131662922bdcbcabd474281d5\
      --nat=extip:${IP}\
      --pubsub-topic=/waku/2/default-waku/proto\
      --cluster-id=0
