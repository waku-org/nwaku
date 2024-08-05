#!/bin/sh

# set -x

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

BINARY_PATH=$1

if [ ! -x "${BINARY_PATH}" ]; then
  echo "Invalid binary path. Failing"
  exit 1
fi

FUNCTION=$2
if [ "${FUNCTION}" = "SENDER" ]; then
  FUNCTION=--test-func=SENDER
  SERVICENAME=lightpush-service
fi

if [ "${FUNCTION}" = "RECEIVER" ]; then
  FUNCTION=--test-func=RECEIVER
  SERVICENAME=filter-service
fi

SERIVCE_NODE_ADDR=$3
if [ -z "${SERIVCE_NODE_ADDR}" ]; then
  echo "Service node peer_id provided. Failing"
  exit 1
fi

if [ "${SERIVCE_NODE_ADDR}" = "waku-sim" ]; then

  RETRIES=${RETRIES:=10}

  while [ -z "${SERIVCE_NODE_ADDR}" ] && [ ${RETRIES} -ge 0 ]; do
    SERIVCE_NODE_ADDR=$(wget -qO- http://${SERVICENAME}:8645/debug/v1/info --header='Content-Type:application/json' 2> /dev/null | sed 's/.*"listenAddresses":\["\([^"]*\)".*/\1/');
    echo "Service node not ready, retrying (retries left: ${RETRIES})"
    sleep 1
    RETRIES=$(( $RETRIES - 1 ))
  done

fi

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

if [ -n "${CLUSTER_ID}" ]; then
    CLUSTER_ID=--cluster-id="${CLUSTER_ID}"
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


if [ -n "${NUM_MESSAGES}" ]; then
    NUM_MESSAGES=--num-messages="${NUM_MESSAGES}"
fi

if [ -n "${DELAY_MESSAGES}" ]; then
    DELAY_MESSAGES=--delay-messages="${DELAY_MESSAGES}"
fi

echo "Running binary: ${BINARY_PATH}"
echo "Tester node: ${FUNCTION}"
echo "Using service node: ${SERIVCE_NODE_ADDR}"


exec "${BINARY_PATH}"\
      --log-level=INFO\
      --service-node="${SERIVCE_NODE_ADDR}"\
      ${DELAY_MESSAGES}\
      ${NUM_MESSAGES}\
      ${PUBSUB}\
      ${CONTENT_TOPIC}\
      ${CLUSTER_ID}\
      ${FUNCTION}\
      ${START_PUBLISHING_AFTER}\
      ${MIN_MESSAGE_SIZE}\
      ${MAX_MESSAGE_SIZE}
      # --nat=extip:${IP}\
      # --config-file=config.toml\
