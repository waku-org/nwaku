package main

import (
	"fmt"
	"runtime"
)

/*
#include <stdlib.h>

// Passing "-lwaku" to the Go linker through "-extldflags" is not enough. We need it in here, for some reason.
#cgo LDFLAGS: -Wl,-rpath,'$ORIGIN' -L${SRCDIR}/../build -lwaku
#include "libwaku.h"

*/
import "C"

// Arrange that main.main runs on main thread.
func init() {
	runtime.LockOSThread()
}

func Start() {
	C.NimMain()

	messageC := C.CString("Calling info")
	fmt.Println("Start nim-waku")
	var str = C.info(messageC)
	fmt.Println("Info", str)
}

func main() {
	fmt.Println("Hi main")
	Start()
}
