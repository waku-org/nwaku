import std/options
import chronos, results, confutils, confutils/defs
import waku

type CliArgs = object
  ethRpcEndpoint* {.
    defaultValue: "", desc: "ETH RPC Endpoint, if passed, RLN is enabled"
  .}: string

when isMainModule:
  let args = CliArgs.load()

  echo "Starting Waku node..."

  let config =
    if (args.ethRpcEndpoint == ""):
      # Create a basic configuration for the Waku node
      # No RLN as we don't have an ETH RPC Endpoint
      NodeConfig.init(wakuConfig = WakuConfig.init(entryNodes = @[], clusterId = 42))
    else:
      # Connect to TWN, use ETH RPC Endpoint for RLN
      NodeConfig.init(ethRpcEndpoints = @[args.ethRpcEndpoint])

  # Create the node using the library API's createNode function
  let node = (waitFor createNode(config)).valueOr:
    echo "Failed to create node: ", error
    quit(QuitFailure)

  echo("Waku node created successfully!")

  # Start the node
  (waitFor startWaku(addr node)).isOkOr:
    echo "Failed to start node: ", error
    quit(QuitFailure)

  echo "Node started successfully!"

  runForever()
