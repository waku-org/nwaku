all: wakunode start_network quicksim

start_network: waku/start_network.nim
	nim c --threads:on -o:build/start_network waku/start_network.nim

quicksim: waku/quicksim.nim
	nim c --threads:on -o:build/quicksim waku/quicksim.nim

wakunode: waku/wakunode.nim
	nim c --threads:on -o:build/wakunode waku/wakunode.nim
