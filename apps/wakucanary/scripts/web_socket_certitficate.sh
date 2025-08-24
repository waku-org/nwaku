#!/bin/bash

WAKUCANARY_BINARY="../../../build/wakucanary"
NODE_PORT=60000
WSS_PORT=$((NODE_PORT + 1000))
PEER_ID="16Uiu2HAmB6JQpewXScGoQ2syqmimbe4GviLxRwfsR8dCpwaGBPSE"
PROTOCOL="relay"
KEY_PATH="./certs/client.key"
CERT_PATH="./certs/client.crt"
LOG_DIR="logs"
mkdir -p "$LOG_DIR"

PEER_ADDRESS="/ip4/127.0.0.1/tcp/$WSS_PORT/wss/p2p/$PEER_ID"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/wss_cert_test_$TIMESTAMP.log"

echo "Building Waku Canary app..."
( cd ../../../ && make wakucanary ) >> "$LOG_FILE" 2>&1

{
  echo "=== Canary WSS + Cert Test ==="
  echo "Timestamp : $TIMESTAMP"
  echo "Node Port : $NODE_PORT"
  echo "WSS Port  : $WSS_PORT"
  echo "Peer ID   : $PEER_ID"
  echo "Protocol  : $PROTOCOL"
  echo "Key Path  : $KEY_PATH"
  echo "Cert Path : $CERT_PATH"
  echo "Address   : $PEER_ADDRESS"
  echo "------------------------------------------"

  $WAKUCANARY_BINARY \
    --address="$PEER_ADDRESS" \
    --protocol="$PROTOCOL" \
    --log-level=DEBUG \
    --websocket-secure-key-path="$KEY_PATH" \
    --websocket-secure-cert-path="$CERT_PATH"

  echo "------------------------------------------"
  echo "Exit code: $?"
} 2>&1 | tee "$LOG_FILE"

echo "✅ Log saved to: $LOG_FILE"
