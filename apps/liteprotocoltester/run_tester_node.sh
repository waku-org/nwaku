#!/bin/sh

set -x

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

FUNCTION=$1
if [ "${FUNCTION}" = "SENDER" ]; then
  FUNCTION=--test-func=SENDER
  SERVICENAME=lightpush-service
fi

if [ "${FUNCTION}" = "RECEIVER" ]; then
  FUNCTION=--test-func=RECEIVER
  SERVICENAME=filter-service
fi


RETRIES=${RETRIES:=10}

while [ -z "${SERIVCE_NODE_ADDR}" ] && [ ${RETRIES} -ge 0 ]; do
  SERIVCE_NODE_ADDR=$(wget -qO- http://${SERVICENAME}:8645/debug/v1/info --header='Content-Type:application/json' 2> /dev/null | sed 's/.*"listenAddresses":\["\([^"]*\)".*/\1/');
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
else
    PUBSUB=--pubsub-topic="/waku/2/rs/66/0"
fi

if [ -n "${CONTENT_TOPIC}" ]; then
    CONTENT_TOPIC=--content-topic="${CONTENT_TOPIC}"
fi

if [ -n "${START_PUBLISHING_AFTER}" ]; then
    START_PUBLISHING_AFTER=--start-publishing-after="${START_PUBLISHING_AFTER}"
fi

if [ -n "${MIN_MESSAGE_SIZE}" ]; then
    MIN_MESSAGE_SIZE=--min-test-msg-size="${MIN_MESSAGE_SIZE}"
fi

if [ -n "${MAX_MESSAGE_SIZE}" ]; then
    MAX_MESSAGE_SIZE=--max-test-msg-size="${MAX_MESSAGE_SIZE}"
fi


echo "Tester node: ${FUNCTION}"
echo "Using service node: ${SERIVCE_NODE_ADDR}"

exec /usr/bin/liteprotocoltester\
      --log-level=INFO\
      --service-node="${SERIVCE_NODE_ADDR}"\
      --cluster-id=66\
      --num-messages=${NUM_MESSAGES}\
      --delay-messages=${DELAY_MESSAGES}\
      --nat=extip:${IP}\
      ${PUBSUB}\
      ${CONTENT_TOPIC}\
      ${FUNCTION}\
      ${START_PUBLISHING_AFTER}\
      ${MIN_MESSAGE_SIZE}\
      ${MAX_MESSAGE_SIZE}
      # --config-file=config.toml\
