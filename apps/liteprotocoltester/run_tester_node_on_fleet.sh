#!/bin/sh

#set -x
#echo "$@"

if test -f .env; then
  echo "Using .env file"
  . $(pwd)/.env
fi


echo "I am a lite-protocol-tester node"

BINARY_PATH=$1

if [ ! -x "${BINARY_PATH}" ]; then
  echo "Invalid binary path '${BINARY_PATH}'. Failing"
  exit 1
fi

if [ "${2}" = "--help" ]; then
  echo "You might want to check nwaku/apps/liteprotocoltester/README.md"
  exec "${BINARY_PATH}" --help
  exit 0
fi

FUNCTION=$2
if [ "${FUNCTION}" = "SENDER" ]; then
  FUNCTION=--test-func=SENDER
  SERIVCE_NODE_ADDR=${LIGHTPUSH_SERVICE_PEER:-${LIGHTPUSH_BOOTSTRAP:-}}
  NODE_ARG=${LIGHTPUSH_SERVICE_PEER:+--service-node="${LIGHTPUSH_SERVICE_PEER}"}
  NODE_ARG=${NODE_ARG:---bootstrap-node="${LIGHTPUSH_BOOTSTRAP}"}
  METRICS_PORT=--metrics-port="${PUBLISHER_METRICS_PORT:-8003}"
fi

if [ "${FUNCTION}" = "RECEIVER" ]; then
  FUNCTION=--test-func=RECEIVER
  SERIVCE_NODE_ADDR=${FILTER_SERVICE_PEER:-${FILTER_BOOTSTRAP:-}}
  NODE_ARG=${FILTER_SERVICE_PEER:+--service-node="${FILTER_SERVICE_PEER}"}
  NODE_ARG=${NODE_ARG:---bootstrap-node="${FILTER_BOOTSTRAP}"}
  METRICS_PORT=--metrics-port="${RECEIVER_METRICS_PORT:-8003}"
fi

if [ -z "${SERIVCE_NODE_ADDR}" ]; then
  echo "Service/Bootsrap node peer_id or enr is not provided. Failing"
  exit 1
fi

MY_EXT_IP=$(wget -qO- --no-check-certificate https://api4.ipify.org)

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
echo "Node function is: ${FUNCTION}"
echo "Using service/bootstrap node as: ${NODE_ARG}"
echo "My external IP: ${MY_EXT_IP}"

exec "${BINARY_PATH}"\
      --log-level=INFO\
      --nat=extip:${MY_EXT_IP}\
      ${NODE_ARG}\
      ${DELAY_MESSAGES}\
      ${NUM_MESSAGES}\
      ${PUBSUB}\
      ${CONTENT_TOPIC}\
      ${CLUSTER_ID}\
      ${FUNCTION}\
      ${START_PUBLISHING_AFTER}\
      ${MIN_MESSAGE_SIZE}\
      ${MAX_MESSAGE_SIZE}\
      ${METRICS_PORT}
