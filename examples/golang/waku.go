package main

/*
	#cgo LDFLAGS: -L../../build/ -lwaku -Wl,--allow-multiple-definition

	#include "../../library/libwaku.h"
	#include <stdio.h>
	#include <stdlib.h>

	extern void globalEventCallback(int ret, char* msg, size_t len, void* userData);

	typedef struct {
		int ret;
		char* msg;
		size_t len;
	} Resp;

	void* allocResp() {
		return calloc(1, sizeof(Resp));
	}

	void freeResp(void* resp) {
		if (resp != NULL) {
			free(resp);
		}
	}

	char* getMyCharPtr(void* resp) {
		if (resp == NULL) {
			return NULL;
		}
		Resp* m = (Resp*) resp;
		return m->msg;
	}

	size_t getMyCharLen(void* resp) {
		if (resp == NULL) {
			return 0;
		}
		Resp* m = (Resp*) resp;
		return m->len;
	}

	int getRet(void* resp) {
		if (resp == NULL) {
			return 0;
		}
		Resp* m = (Resp*) resp;
		return m->ret;
	}

	// resp must be set != NULL in case interest on retrieving data from the callback
	void callback(int ret, char* msg, size_t len, void* resp) {
		if (resp != NULL) {
			Resp* m = (Resp*) resp;
			m->ret = ret;
			m->msg = msg;
			m->len = len;
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

	void* cGoWakuNew(const char* configJson, void* resp) {
		// We pass NULL because we are not interested in retrieving data from this callback
		return waku_new(configJson, (WakuCallBack) callback, resp);
	}

	void cGoWakuStart(void* ctx, void* resp) {
		WAKU_CALL(waku_start(ctx, (WakuCallBack) callback, resp));
	}

	void cGoWakuStop(void* ctx, void* resp) {
		WAKU_CALL(waku_stop(ctx, (WakuCallBack) callback, resp));
	}

	void cGoWakuDestroy(void* ctx, void* resp) {
		WAKU_CALL(waku_destroy(ctx, (WakuCallBack) callback, resp));
	}

	void cGoWakuVersion(void* ctx, void* resp) {
		WAKU_CALL(waku_version(ctx, (WakuCallBack) callback, resp));
	}

	void cGoWakuSetEventCallback(void* ctx) {
		// The 'globalEventCallback' Go function is shared amongst all possible WakuNode instances.

		// Given that the 'globalEventCallback' is shared, we pass again the
		// ctx instance but in this case is needed to pick up the correct method
		// that will handle the event.

		// In other words, for every call the libwaku makes to globalEventCallback,
		// the 'userData' parameter will bring the context of the node that registered
		// that globalEventCallback.

		// This technique is needed because cgo only allows to export Go functions and not methods.

		waku_set_event_callback(ctx, (WakuCallBack) globalEventCallback, ctx);
	}

	void cGoWakuContentTopic(void* ctx,
							char* appName,
							int appVersion,
							char* contentTopicName,
							char* encoding,
							void* resp) {

		WAKU_CALL( waku_content_topic(ctx,
							appName,
							appVersion,
							contentTopicName,
							encoding,
							(WakuCallBack) callback,
							resp) );
	}

	void cGoWakuPubsubTopic(void* ctx, char* topicName, void* resp) {
		WAKU_CALL( waku_pubsub_topic(ctx, topicName, (WakuCallBack) callback, resp) );
	}

	void cGoWakuDefaultPubsubTopic(void* ctx, void* resp) {
		WAKU_CALL (waku_default_pubsub_topic(ctx, (WakuCallBack) callback, resp));
	}

	void cGoWakuRelayPublish(void* ctx,
                       const char* pubSubTopic,
                       const char* jsonWakuMessage,
                       int timeoutMs,
					   void* resp) {

		WAKU_CALL (waku_relay_publish(ctx,
                       pubSubTopic,
                       jsonWakuMessage,
                       timeoutMs,
                       (WakuCallBack) callback,
                       resp));
	}

	void cGoWakuRelaySubscribe(void* ctx, char* pubSubTopic, void* resp) {

		WAKU_CALL ( waku_relay_subscribe(ctx,
							pubSubTopic,
							(WakuCallBack) callback,
							resp) );
	}

	void cGoWakuRelayUnsubscribe(void* ctx, char* pubSubTopic, void* resp) {

		WAKU_CALL ( waku_relay_unsubscribe(ctx,
							pubSubTopic,
							(WakuCallBack) callback,
							resp) );
	}

	void cGoWakuConnect(void* ctx, char* peerMultiAddr, int timeoutMs, void* resp) {
		WAKU_CALL( waku_connect(ctx,
						peerMultiAddr,
						timeoutMs,
						(WakuCallBack) callback,
						resp) );
	}

	void cGoWakuListenAddresses(void* ctx, void* resp) {
		WAKU_CALL (waku_listen_addresses(ctx, (WakuCallBack) callback, resp) );
	}

*/
import "C"

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"unsafe"
)

type WakuMessageHash = string
type WakuPubsubTopic = string
type WakuContentTopic = string

type WakuConfig struct {
	Host        string `json:"host,omitempty"`
	Port        int    `json:"port,omitempty"`
	NodeKey     string `json:"key,omitempty"`
	EnableRelay bool   `json:"relay"`
	LogLevel    string `json:"logLevel"`
}

type WakuNode struct {
	ctx unsafe.Pointer
}

func WakuNew(config WakuConfig) (*WakuNode, error) {
	jsonConfig, err := json.Marshal(config)
	if err != nil {
		return nil, err
	}

	var cJsonConfig = C.CString(string(jsonConfig))
	var resp = C.allocResp()

	defer C.free(unsafe.Pointer(cJsonConfig))
	defer C.freeResp(resp)

	ctx := C.cGoWakuNew(cJsonConfig, resp)
	if C.getRet(resp) == C.RET_OK {
		return &WakuNode{ctx: ctx}, nil
	}

	errMsg := "error WakuNew: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return nil, errors.New(errMsg)
}

func (self *WakuNode) WakuStart() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuStart(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuStart: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuStop() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuStop(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuStop: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuDestroy() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuDestroy(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuDestroy: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuVersion() (string, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)

	C.cGoWakuVersion(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		var version = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return version, nil
	}

	errMsg := "error WakuVersion: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

//export globalEventCallback
func globalEventCallback(callerRet C.int, msg *C.char, len C.size_t, userData unsafe.Pointer) {
	// This is shared among all Golang instances

	self := WakuNode{ctx: userData}
	self.MyEventCallback(callerRet, msg, len)
}

func (self *WakuNode) MyEventCallback(callerRet C.int, msg *C.char, len C.size_t) {
	fmt.Println("Event received:", C.GoStringN(msg, C.int(len)))
}

func (self *WakuNode) WakuSetEventCallback() {
	// Notice that the events for self node are handled by the 'MyEventCallback' method
	C.cGoWakuSetEventCallback(self.ctx)
}

func (self *WakuNode) FormatContentTopic(
	appName string,
	appVersion int,
	contentTopicName string,
	encoding string) (WakuContentTopic, error) {

	var cAppName = C.CString(appName)
	var cContentTopicName = C.CString(contentTopicName)
	var cEncoding = C.CString(encoding)
	var resp = C.allocResp()

	defer C.free(unsafe.Pointer(cAppName))
	defer C.free(unsafe.Pointer(cContentTopicName))
	defer C.free(unsafe.Pointer(cEncoding))
	defer C.freeResp(resp)

	C.cGoWakuContentTopic(self.ctx,
		cAppName,
		C.int(appVersion),
		cContentTopicName,
		cEncoding,
		resp)

	if C.getRet(resp) == C.RET_OK {
		var contentTopic = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return contentTopic, nil
	}

	errMsg := "error FormatContentTopic: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))

	return "", errors.New(errMsg)
}

func (self *WakuNode) FormatPubsubTopic(topicName string) (WakuPubsubTopic, error) {
	var cTopicName = C.CString(topicName)
	var resp = C.allocResp()

	defer C.free(unsafe.Pointer(cTopicName))
	defer C.freeResp(resp)

	C.cGoWakuPubsubTopic(self.ctx, cTopicName, resp)
	if C.getRet(resp) == C.RET_OK {
		var pubsubTopic = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return pubsubTopic, nil
	}

	errMsg := "error FormatPubsubTopic: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))

	return "", errors.New(errMsg)
}

func (self *WakuNode) WakuDefaultPubsubTopic() (WakuPubsubTopic, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuDefaultPubsubTopic(self.ctx, resp)
	if C.getRet(resp) == C.RET_OK {
		var defaultPubsubTopic = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return defaultPubsubTopic, nil
	}

	errMsg := "error WakuDefaultPubsubTopic: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))

	return "", errors.New(errMsg)
}

func (self *WakuNode) WakuRelayPublish(
	pubsubTopic string,
	message string,
	timeoutMs int) (WakuMessageHash, error) {

	var cPubsubTopic = C.CString(pubsubTopic)
	var msg = C.CString(message)
	var resp = C.allocResp()

	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	defer C.free(unsafe.Pointer(msg))

	C.cGoWakuRelayPublish(self.ctx, cPubsubTopic, msg, C.int(timeoutMs), resp)
	if C.getRet(resp) == C.RET_OK {
		msgHash := C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return msgHash, nil
	}
	errMsg := "error WakuRelayPublish: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

func (self *WakuNode) WakuRelaySubscribe(pubsubTopic string) error {
	var resp = C.allocResp()
	var cPubsubTopic = C.CString(pubsubTopic)

	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	C.cGoWakuRelaySubscribe(self.ctx, cPubsubTopic, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuRelaySubscribe: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuRelayUnsubscribe(pubsubTopic string) error {
	var resp = C.allocResp()
	var cPubsubTopic = C.CString(pubsubTopic)
	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	C.cGoWakuRelayUnsubscribe(self.ctx, cPubsubTopic, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuRelayUnsubscribe: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuConnect(peerMultiAddr string, timeoutMs int) error {
	var resp = C.allocResp()
	var cPeerMultiAddr = C.CString(peerMultiAddr)
	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPeerMultiAddr))

	C.cGoWakuConnect(self.ctx, cPeerMultiAddr, C.int(timeoutMs), resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuConnect: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuListenAddresses() (string, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuListenAddresses(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		var listenAddresses = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return listenAddresses, nil
	}
	errMsg := "error WakuListenAddresses: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

func main() {
	config := WakuConfig{
		Host:        "0.0.0.0",
		Port:        30304,
		NodeKey:     "11d0dcea28e86f81937a3bd1163473c7fbc0a0db54fd72914849bc47bdf78710",
		EnableRelay: true,
		LogLevel:    "DEBUG",
	}

	node, err := WakuNew(config)
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	node.WakuSetEventCallback()

	defaultPubsubTopic, err := node.WakuDefaultPubsubTopic()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.WakuRelaySubscribe(defaultPubsubTopic)
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.WakuConnect(
		// tries to connect to a localhost node with key: 0d714a1fada214dead6dc9c7274585eca0ff292451866e7d6d677dc818e8ccd2
		"/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN",
		10000)
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.WakuStart()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	version, err := node.WakuVersion()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	formattedContentTopic, err := node.FormatContentTopic("appName", 1, "cTopicName", "enc")
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	formattedPubsubTopic, err := node.FormatPubsubTopic("my-ctopic")
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	listenAddresses, err := node.WakuListenAddresses()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	fmt.Println("Version:", version)
	fmt.Println("Custom content topic:", formattedContentTopic)
	fmt.Println("Custom pubsub topic:", formattedPubsubTopic)
	fmt.Println("Default pubsub topic:", defaultPubsubTopic)
	fmt.Println("Listen addresses:", listenAddresses)

	// Wait for a SIGINT or SIGTERM signal
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	<-ch

	err = node.WakuStop()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.WakuDestroy()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}
}
