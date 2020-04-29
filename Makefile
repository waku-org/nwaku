all: wakunode start_network quicksim

start_network: node/v0/start_network.nim
	nim c --threads:on -o:build/start_network node/v0/start_network.nim

quicksim: node/v0/quicksim.nim
	nim c --threads:on -o:build/quicksim node/v0/quicksim.nim

wakunode: node/v0/wakunode.nim
	nim c --threads:on -o:build/wakunode node/v0/wakunode.nim

wakunode2: node/v2/wakunode.nim
	nim c --threads:on -o:build/wakunode2 node/v2/wakunode.nim
