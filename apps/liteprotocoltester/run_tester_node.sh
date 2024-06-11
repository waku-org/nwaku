#!/bin/sh

if test -f .env; then
  echo "Using .env file"
  . $(pwd)/.env
fi

IP=$(ip a | grep "inet " | grep -Fv 127.0.0.1 | sed 's/.*inet \([^/]*\).*/\1/')

echo "I am a lite-protocol-tester node"

# Get an unique node index based on the container's IP
FOURTH_OCTET=${IP##*.}
THIRD_OCTET="${IP%.*}"; THIRD_OCTET="${THIRD_OCTET##*.}"
NODE_INDEX=$((FOURTH_OCTET + 256 * THIRD_OCTET))

echo "NODE_INDEX $NODE_INDEX"

RETRIES=${RETRIES:=10}

while [ -z "${SERIVCE_NODE_ADDR}" ] && [ ${RETRIES} -ge 0 ]; do
  SERIVCE_NODE_ADDR=$(wget -qO- http://servicenode:8645/debug/v1/info --header='Content-Type:application/json' 2> /dev/null | sed 's/.*"listenAddresses":\["\([^"]*\)".*/\1/');
  echo "Service node not ready, retrying (retries left: ${RETRIES})"
  sleep 1
  RETRIES=$(( $RETRIES - 1 ))
done

if [ -z "${SERIVCE_NODE_ADDR}" ]; then
   echo "Could not get SERIVCE_NODE_ADDR and none provided. Failing"
   exit 1
fi


if [ -n "${PUBSUB}" ]; then
    PUBSUB=--pubsub-topic="${PUBSUB}"
fi

if [ -n "${CONTENT_TOPIC}" ]; then
    CONTENT_TOPIC=--content-topic="${CONTENT_TOPIC}"
fi

FUNCTION=$1

echo "Tester node: ${FUNCTION}"

REST_PORT=--rest-port=8647

if [ "${FUNCTION}" = "SENDER" ]; then
  FUNCTION=--test-func=SENDER
  REST_PORT=--rest-port=8646
fi

if [ "${FUNCTION}" = "RECEIVER" ]; then
  FUNCTION=--test-func=RECEIVER
  REST_PORT=--rest-port=8647
fi

if [ -z "${FUNCTION}" ]; then
  FUNCTION=--test-func=RECEIVER
fi

echo "Using service node: ${SERIVCE_NODE_ADDR}"
exec /usr/bin/liteprotocoltester\
      --log-level=DEBUG\
      --service-node="${SERIVCE_NODE_ADDR}"\
      --pubsub-topic=/waku/2/default-waku/proto\
      --cluster-id=0\
      --num-messages=${NUM_MESSAGES}\
      --delay-messages=${DELAY_MESSAGES}\
      --nat=extip:${IP}\
      ${FUNCTION}\
      ${PUBSUB}\
      ${CONTENT_TOPIC}\
      ${REST_PORT}

      # --config-file=config.toml\
