import std/options
import chronos, results, confutils, confutils/defs
import waku

type CliArgs* = object
  ethRpcEndpoint* {.
    defaultValue: "", desc: "ETH RPC Endpoint, if passed, RLN is enabled"
  .}: string

proc main(args: CliArgs) {.async.} =
  echo("Starting Waku node...")

  let config =
    if (args.ethRpcEndpoint == ""):
      # Create a basic configuration for the Waku node
      # No RLN as we don't have an ETH RPC Endpoint
      newNodeConfig(wakuConfig = newWakuConfig(entryNodes = @[], clusterId = 42))
    else:
      # Connect to TWN, use ETH RPC Endpoint for RLN
      newNodeConfig(ethRpcEndpoints = @[args.ethRpcEndpoint])

  # Create the node using the library API's createNode function
  let node = (await createNode(config)).valueOr:
    echo("Failed to create node: ", error)
    quit(1)

  echo("Waku node created successfully!")

  # Start the node
  (await startWaku(addr node)).isOkOr:
    echo("Failed to start node: ", error)
    quit(1)

  echo("Node started successfully! exiting")

when isMainModule:
  let args = CliArgs.load()
  waitFor main(args)
