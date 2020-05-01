all: wakunode start_network quicksim

start_network: node/v0/start_network.nim
	nim c --threads:on -o:build/start_network node/v0/start_network.nim

quicksim: node/v0/quicksim.nim
	nim c --threads:on -o:build/quicksim node/v0/quicksim.nim

wakunode: node/v0/wakunode.nim
	nim c --threads:on -o:build/wakunode node/v0/wakunode.nim

wakunode2: node/v2/wakunode.nim
	nim c --threads:on -o:build/wakunode2 node/v2/wakunode.nim

quicksim2: node/v2/quicksim.nim
	nim c --threads:on -o:build/quicksim2 node/v2/quicksim.nim

protocol2: protocol/v2/waku_protocol.nim
	nim c --threads:on -o:build/protocol2 protocol/v2/waku_protocol.nim
