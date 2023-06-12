package main

/*
	#cgo LDFLAGS: -L./ -lwaku -Wl,--allow-multiple-definition

	#include "libwaku.h"

	static NimStringDesc wakuString;
	NimStringDesc* mResp = &wakuString;

	char* data(NimStringDesc* a) {
		return a->data;
	}

	extern void eventHandler(char* msg);

	void cGoEventHandler(char* msg) {
		eventHandler(msg);
	}

	void setCallback() {
		waku_set_event_callback(cGoEventHandler);
	}

	struct ConfigNode {
		NCSTRING host;
		NU       port;
		NCSTRING key;
		NIM_BOOL relay;
		NCSTRING peers;
	};
*/
import "C"

import (
	"os"
	"fmt"
	"runtime"
	"flag"
)

//export eventHandler
func eventHandler(msg *C.char) {
	fmt.Println("Event received: ", C.GoString(msg))
}

func main() {
	runtime.LockOSThread()

	// Setup the nim runtime and GC.
	C.NimMain()

	var host string
	var port int
	var key string
	var relay int

	flag.StringVar(&host, "host", "0.0.0.0", "Node's host.")
	flag.IntVar(&port, "port", 60000, "Node's port.")
	flag.StringVar(&key, "key", "",
	`P2P node private key as 64 char hex string.
e.g.: 364d111d729a6eb6d2e6113e163f017b5ef03a6f94c9b5b7bb1bb36fa5cb07a9`)
	flag.IntVar(&relay, "relay", 1, "1 -> Enable Relay protocol. 0 -> disable.")
	flag.Parse()

	if key == "" {
		fmt.Println("Please set a valid P2P private node key.")
		fmt.Println("Run with --help to get a better insight.")
		os.Exit(1)
	}

	cfgNode := C.ConfigNode{}
	cfgNode.host = C.CString(host)
	cfgNode.port = C.ulong(port)
	cfgNode.key = C.CString(key)
	cfgNode.relay = relay == 1

	fmt.Println("Git Version: ", C.GoString( C.waku_version() ))
	C.waku_default_pubsub_topic(&C.mResp);
	defaultPubsubTopic := C.data( C.mResp )

	fmt.Println("Default pubsub topic: ", C.GoString( defaultPubsubTopic ) )
	fmt.Println("Bind addr: ", C.GoString(cfgNode.host), ":", cfgNode.port)

	if cfgNode.relay {
		fmt.Println("Waku Relay enabled")
	} else {
		fmt.Println("Waku Relay disabled")
	}

	if ! C.waku_new(&cfgNode, &C.mResp) {
		fmt.Println("Error creating WakuNode: ", C.GoString(C.data(C.mResp)));
		os.Exit(-1)
	}

	C.setCallback()
	C.waku_start()

	if ! C.waku_relay_subscribe(defaultPubsubTopic, &C.mResp) {
		fmt.Println("Error subscribing to PubsubTopic: ",
					C.GoString(C.data(C.mResp)));
		os.Exit(-1)
	}

	for {
		C.waku_poll()
	}
}
