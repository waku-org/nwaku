import std/options
import chronos, results
import waku

proc main() {.async.} =
  echo("Starting Waku node...")

  # Create a basic configuration for the Waku node
  # No RLN so we don't need to path an eth rpc endpoint
  let config = newNodeConfig(
    newWakuConfig(
      bootstrapNodes = @[],
      clusterId = 42,
      messageValidation = MessageValidation(
        maxMessageSizeBytes: 150'u64 * 1024'u64, # 150kB
        rlnConfig: none(RlnConfig),
      ),
    )
  )

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
  waitFor main()
