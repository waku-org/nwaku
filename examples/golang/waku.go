package main

/*
	#cgo LDFLAGS: -L../../build/ -lwaku -Wl,--allow-multiple-definition

	#include "../../library/libwaku.h"
	#include <stdio.h>
	#include <stdlib.h>

	extern void MyEventCallback(int ret, char* msg, size_t len, void* userData);

	typedef struct {
		char* msg;
		size_t len;
	} MyString;

	void* allocMyString() {
		return calloc(1, sizeof(MyString));
	}

	void freeMyString(void* str) {
		if (str != NULL) {
			free(str);
		}
	}

	char* getMyCharPtr(void* myStr) {
		if (myStr == NULL) {
			return NULL;
		}
		MyString* m = (MyString*) myStr;
		return m->msg;
	}

	size_t getMyCharLen(void* myStr) {
		if (myStr == NULL) {
			return 0;
		}
		MyString* m = (MyString*) myStr;
		return m->len;
	}

	// myStr must be set != NULL in case interest on retrieving data from the callback
	void callback(int ret, char* msg, size_t len, void* myStr) {
		if (ret != RET_OK) {
			char* m = calloc(len + 1, sizeof(char));
			snprintf(m, len + 1, "%s", msg);
			printf("error in callback: %s\n", m);
			fflush(stdout);
			free(m);
			exit(-1);
		}
		else { // ret == RET_OK
			if (myStr != NULL) {
				MyString* m = (MyString*) myStr;
				m->msg = msg;
				m->len = len;
			}
		}
	}

	#define WAKU_CALL(call)                                                        \
	do {                                                                           \
		int ret = call;                                                              \
		if (ret != 0) {                                                              \
			printf("Failed the call to: %s. Returned code: %d\n", #call, ret);         \
			exit(1);                                                                   \
		}                                                                            \
	} while (0)

	void* cGoWakuNew(const char* configJson) {
		// We pass NULL because we are not interested in retrieving data from this callback
		return waku_new(configJson, (WakuCallBack) callback, NULL);
	}

	void cGoWakuStart(void* ctx) {
		WAKU_CALL(waku_start(ctx, (WakuCallBack) callback, NULL));
	}

	void cGoWakuStop(void* ctx) {
		WAKU_CALL(waku_stop(ctx, (WakuCallBack) callback, NULL));
	}

	void cGoWakuDestroy(void* ctx) {
		WAKU_CALL(waku_destroy(ctx, (WakuCallBack) callback, NULL));
	}

	void cGoWakuVersion(void* ctx, void* myStr) {
		WAKU_CALL(waku_version(ctx, (WakuCallBack) callback, myStr));
	}

	void cGoWakuSetEventCallback(void* ctx, void* myStr) {
		// We should pass a myStr != NULL in this case to overcome
		// the 'if isNil(ctx[].eventUserData)' check in libwaku.nim
		waku_set_event_callback(ctx, (WakuCallBack) MyEventCallback, myStr);
	}

	void cGoWakuContentTopic(void* ctx,
							char* appName,
							int appVersion,
							char* contentTopicName,
							char* encoding,
							void* myStr) {

		WAKU_CALL( waku_content_topic(ctx,
							appName,
							appVersion,
							contentTopicName,
							encoding,
							(WakuCallBack) callback,
							myStr) );
	}

	void cGoWakuPubsubTopic(void* ctx, char* topicName, void* myStr) {
		WAKU_CALL( waku_pubsub_topic(ctx, topicName, (WakuCallBack) callback, myStr) );
	}

	void cGoWakuDefaultPubsubTopic(void* ctx, void* myStr) {
		WAKU_CALL (waku_default_pubsub_topic(ctx, (WakuCallBack) callback, myStr));
	}

	void cGoWakuRelayPublish(void* ctx,
                       const char* pubSubTopic,
                       const char* jsonWakuMessage,
                       int timeoutMs) {

		WAKU_CALL (waku_relay_publish(ctx,
                       pubSubTopic,
                       jsonWakuMessage,
                       timeoutMs,
                       (WakuCallBack) callback,
                       NULL));
	}

	void cGoWakuRelaySubscribe(void* ctx, char* pubSubTopic) {

		WAKU_CALL ( waku_relay_subscribe(ctx,
							pubSubTopic,
							(WakuCallBack) callback,
							NULL) );
	}

	void cGoWakuRelayUnsubscribe(void* ctx, char* pubSubTopic) {

		WAKU_CALL ( waku_relay_unsubscribe(ctx,
							pubSubTopic,
							(WakuCallBack) callback,
							NULL) );
	}

	void cGoWakuConnect(void* ctx, char* peerMultiAddr, int timeoutMs) {
		WAKU_CALL( waku_connect(ctx,
						peerMultiAddr,
						timeoutMs,
						(WakuCallBack) callback,
						NULL) );
	}

	void cGoWakuListenAddresses(void* ctx, void* myStr) {
		WAKU_CALL (waku_listen_addresses(ctx, (WakuCallBack) callback, myStr) );
	}

*/
import "C"

import (
	"time"
	"fmt"
	"unsafe"
)

func WakuNew(jsonConfig string) unsafe.Pointer {
	return C.cGoWakuNew(C.CString(jsonConfig))
}

func WakuStart(ctx unsafe.Pointer) {
	C.cGoWakuStart(ctx)
}

func WakuStop(ctx unsafe.Pointer) {
	C.cGoWakuStop(ctx)
}

func WakuDestroy(ctx unsafe.Pointer) {
	C.cGoWakuDestroy(ctx)
}

func WakuVersion(ctx unsafe.Pointer) string {
	var str = C.allocMyString()
	defer C.freeMyString(str)

	C.cGoWakuVersion(ctx, str)

	var version = C.GoStringN(C.getMyCharPtr(str), C.int(C.getMyCharLen(str)))
    return version
}

//export MyEventCallback
func MyEventCallback(callerRet C.int, msg *C.char, len C.size_t, userData unsafe.Pointer) {
	fmt.Println("Event received:", C.GoStringN(msg, C.int(len)))
}

func WakuSetEventCallback(ctx unsafe.Pointer) {
	var str = C.allocMyString()
	// Notice that we are not releasing the `str` memory in this case
	// because we leave it available to the upcoming events
	C.cGoWakuSetEventCallback(ctx, str)
}

func WakuContentTopic(ctx unsafe.Pointer,
					  appName string,
					  appVersion int,
					  contentTopicName string,
					  encoding string) string {
	var cAppName = C.CString(appName)
	var cContentTopicName = C.CString(contentTopicName)
	var cEncoding = C.CString(encoding)
	var str = C.allocMyString()

	defer C.free(unsafe.Pointer(cAppName))
	defer C.free(unsafe.Pointer(cContentTopicName))
	defer C.free(unsafe.Pointer(cEncoding))
	defer C.freeMyString(str)

	C.cGoWakuContentTopic(ctx, 
						cAppName,
						C.int(appVersion),
						cContentTopicName,
						cEncoding,
						str)

	var contentTopic = C.GoStringN(C.getMyCharPtr(str), C.int(C.getMyCharLen(str)))
    return contentTopic
}

func WakuPubsubTopic(ctx unsafe.Pointer, topicName string) string {
	var cTopicName = C.CString(topicName)
	var str = C.allocMyString()

	defer C.free(unsafe.Pointer(cTopicName))
	defer C.freeMyString(str)

	C.cGoWakuPubsubTopic(ctx, cTopicName, str)

	var pubsubTopic = C.GoStringN(C.getMyCharPtr(str), C.int(C.getMyCharLen(str)))
    return pubsubTopic
}

func WakuDefaultPubsubTopic(ctx unsafe.Pointer) string {
	var str = C.allocMyString()
	defer C.freeMyString(str)
	C.cGoWakuDefaultPubsubTopic(ctx, str)
	var defaultPubsubTopic = C.GoStringN(C.getMyCharPtr(str), C.int(C.getMyCharLen(str)))
    return defaultPubsubTopic
}

func WakuRelayPublish(ctx unsafe.Pointer,
					pubsubTopic string,
					message string,
					timeoutMs int) {
	var cPubsubTopic = C.CString(pubsubTopic)
	var msg = C.CString(message)

	defer C.free(unsafe.Pointer(cPubsubTopic))
	defer C.free(unsafe.Pointer(msg))

	C.cGoWakuRelayPublish(ctx, cPubsubTopic, msg, C.int(timeoutMs))
}

func WakuRelaySubscribe(ctx unsafe.Pointer, pubsubTopic string) {
	var cPubsubTopic = C.CString(pubsubTopic)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	C.cGoWakuRelaySubscribe(ctx, cPubsubTopic)
}

func WakuRelayUnsubscribe(ctx unsafe.Pointer, pubsubTopic string) {
	var cPubsubTopic = C.CString(pubsubTopic)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	C.cGoWakuRelayUnsubscribe(ctx, cPubsubTopic)
}

func WakuConnect(ctx unsafe.Pointer, peerMultiAddr string, timeoutMs int) {
	var cPeerMultiAddr = C.CString(peerMultiAddr)
	defer C.free(unsafe.Pointer(cPeerMultiAddr))

	C.cGoWakuConnect(ctx, cPeerMultiAddr, C.int(timeoutMs))
}

func WakuListenAddresses(ctx unsafe.Pointer) string {
	var str = C.allocMyString()
	defer C.freeMyString(str)
	C.cGoWakuListenAddresses(ctx, str)
	var listenAddresses = C.GoStringN(C.getMyCharPtr(str), C.int(C.getMyCharLen(str)))
    return listenAddresses
}

func main() {
	config := `{
		"host": "0.0.0.0",
		"port": 30304,
		"key": "11d0dcea28e86f81937a3bd1163473c7fbc0a0db54fd72914849bc47bdf78710",
		"relay": true
	}`

	ctx := WakuNew(config)
	WakuSetEventCallback(ctx)
	WakuRelaySubscribe(ctx, WakuDefaultPubsubTopic(ctx))
	WakuConnect(ctx,
		// tries to connect to a localhost node with key: 0d714a1fada214dead6dc9c7274585eca0ff292451866e7d6d677dc818e8ccd2
		"/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN",
		10000)
	WakuStart(ctx)

	fmt.Println("Version:", WakuVersion(ctx))
	fmt.Println("Custom content topic:", WakuContentTopic(ctx, "appName", 1, "cTopicName", "enc"))
	fmt.Println("Custom pubsub topic:", WakuPubsubTopic(ctx, "my-ctopic"))
	fmt.Println("Default pubsub topic:", WakuDefaultPubsubTopic(ctx))
	fmt.Println("Listen addresses:", WakuListenAddresses(ctx))
	
	for {
		// A simple wait to let the Waku node to run.
		// Notice that the Waku node runs in a separate thread.
		time.Sleep(time.Second)
	}
}

