#!/bin/sh

#set -x

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

SELECTOR=$4
if [ -z "${SELECTOR}" ] || [ "${SELECTOR}" = "SERVICE" ]; then
  SERVICE_NODE_DIRECT=true
elif [ "${SELECTOR}" = "BOOTSTRAP" ]; then
  SERVICE_NODE_DIRECT=false
else
  echo "Invalid selector '${SELECTOR}'. Failing"
  exit 1
fi

DO_DETECT_SERVICENODE=0

if [ "${SERIVCE_NODE_ADDR}" = "servicenode" ]; then
  DO_DETECT_SERVICENODE=1
  SERIVCE_NODE_ADDR=""
  SERVICENAME=servicenode
fi

if [ "${SERIVCE_NODE_ADDR}" = "waku-sim" ]; then
  DO_DETECT_SERVICENODE=1
  SERIVCE_NODE_ADDR=""
  MY_EXT_IP=$(ip a | grep "inet " | grep -Fv 127.0.0.1 | sed 's/.*inet \([^/]*\).*/\1/')
else
  MY_EXT_IP=$(wget -qO- --no-check-certificate https://api4.ipify.org)
fi


if [ $DO_DETECT_SERVICENODE -eq 1 ]; then
  RETRIES=${RETRIES:=20}

  while [ -z "${SERIVCE_NODE_ADDR}" ] && [ ${RETRIES} -ge 0 ]; do
    SERVICE_DEBUG_INFO=$(wget -qO- http://${SERVICENAME}:8645/debug/v1/info --header='Content-Type:application/json' 2> /dev/null);
    echo "SERVICE_DEBUG_INFO: ${SERVICE_DEBUG_INFO}"

    SERIVCE_NODE_ADDR=$(wget -qO- http://${SERVICENAME}:8645/debug/v1/info --header='Content-Type:application/json' 2> /dev/null | sed 's/.*"listenAddresses":\["\([^"]*\)".*/\1/');
    echo "Service node not ready, retrying (retries left: ${RETRIES})"
    sleep 3
    RETRIES=$(( $RETRIES - 1 ))
  done

fi

if [ -z "${SERIVCE_NODE_ADDR}" ]; then
   echo "Could not get SERIVCE_NODE_ADDR and none provided. Failing"
   exit 1
fi

if $SERVICE_NODE_DIRECT; then
  FULL_NODE=--service-node="${SERIVCE_NODE_ADDR} --fixed-service-peer"
else
  FULL_NODE=--bootstrap-node="${SERIVCE_NODE_ADDR}"
fi

if [ -n "${SHARD}" ]; then
    SHARD=--shard="${SHARD}"
else
    SHARD=--shard="0"
fi

if [ -n "${CONTENT_TOPIC}" ]; then
    CONTENT_TOPIC=--content-topic="${CONTENT_TOPIC}"
fi

if [ -n "${CLUSTER_ID}" ]; then
    CLUSTER_ID=--cluster-id="${CLUSTER_ID}"
fi

if [ -n "${START_PUBLISHING_AFTER_SECS}" ]; then
    START_PUBLISHING_AFTER_SECS=--start-publishing-after="${START_PUBLISHING_AFTER_SECS}"
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

if [ -n "${MESSAGE_INTERVAL_MILLIS}" ]; then
    MESSAGE_INTERVAL_MILLIS=--message-interval="${MESSAGE_INTERVAL_MILLIS}"
fi

if [ -n "${LOG_LEVEL}" ]; then
    LOG_LEVEL=--log-level=${LOG_LEVEL}
else
    LOG_LEVEL=--log-level=INFO
fi

echo "Running binary: ${BINARY_PATH}"
echo "Tester node: ${FUNCTION}"
echo "Using service node: ${SERIVCE_NODE_ADDR}"
echo "My external IP: ${MY_EXT_IP}"

exec "${BINARY_PATH}"\
      --nat=extip:${MY_EXT_IP}\
      --test-peers\
      ${LOG_LEVEL}\
      ${FULL_NODE}\
      ${MESSAGE_INTERVAL_MILLIS}\
      ${NUM_MESSAGES}\
      ${SHARD}\
      ${CONTENT_TOPIC}\
      ${CLUSTER_ID}\
      ${FUNCTION}\
      ${START_PUBLISHING_AFTER_SECS}\
      ${MIN_MESSAGE_SIZE}\
      ${MAX_MESSAGE_SIZE}
      # --config-file=config.toml\
