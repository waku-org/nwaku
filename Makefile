# Copyright (c) 2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by Make

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# -d:insecure - Necessary to enable Prometheus HTTP endpoint for metrics
# -d:chronicles_colors:none - Necessary to disable colors in logs for Docker
DOCKER_IMAGE_NIMFLAGS ?= -d:chronicles_colors:none -d:insecure

EXCLUDED_NIM_PACKAGES := vendor/nim-dnsdisc/vendor

LINK_PCRE := 0


# Get git version
GIT_VERSION ?= $(shell git describe --abbrev=6 --always --tags)

# Detecting the os
ifeq ($(OS),Windows_NT) # is Windows_NT on XP, 2000, 7, Vista, 10...
 detected_OS := Windows
else ifeq ($(strip $(shell uname)),Darwin)
 detected_OS := macOS
else
 # e.g. Linux
 detected_OS := $(strip $(shell uname))
endif


# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

.PHONY: \
	all \
	test \
	update \
	clean \
	libbacktrace \
	deps \
	deps2 \
	v1 \
	v2 \
	test1 \
	test2 \
	wakunode1 \
	example1 \
	sim1 \
	wakunode2 \
	example2 \
	sim2 \
	wakubridge \
	chat2 \
	chat2bridge \
	libwaku.so \
	wrappers

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE); \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.

# default target, because it's the first one that doesn't start with '.'
all: | v1 v2

v1: | wakunode1 example1 sim1 
v2: | wakunode2 example2 sim2 wakubridge chat2 chat2bridge

# Builds and run the test suite (Waku v1 + v2)
test: | test1 test2


# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk


# git version
NIM_PARAMS := $(NIM_PARAMS) -d:git_version:\"$(GIT_VERSION)\"

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif


# symlink
waku.nims:
	ln -s waku.nimble $@

# nim-libbacktrace
libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0


# Common dependencies
deps: | deps-common nat-libs waku.nims
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

# Waku v2-only dependencies
deps2: | rlnlib


#- deletes and recreates "waku.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -rf waku.nims && \
		$(MAKE) waku.nims $(HANDLE_OUTPUT)


## Whisper targets

testwhisper: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim testwhisper $(NIM_PARAMS) waku.nims


## Waku v1 targets

test1: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim test1 $(NIM_PARAMS) waku.nims

wakunode1: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakunode1 $(NIM_PARAMS) waku.nims

example1: | build
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim example1 $(NIM_PARAMS) waku.nims

sim1: | build deps wakunode1
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim sim1 $(NIM_PARAMS) waku.nims


## Waku v2 targets

test2: | build deps deps2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim test2 $(NIM_PARAMS) waku.nims

wakunode2: | build deps deps2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakunode2 $(NIM_PARAMS) waku.nims

example2: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim example2 $(NIM_PARAMS) waku.nims

sim2: | build deps deps2 wakunode2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim sim2 $(NIM_PARAMS) waku.nims

scripts2: | build deps wakunode2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim scripts2 $(NIM_PARAMS) waku.nims

wakubridge: | build deps deps2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim bridge $(NIM_PARAMS) waku.nims

chat2: | build deps deps2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim chat2 $(NIM_PARAMS) waku.nims

chat2bridge: | build deps deps2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim chat2bridge $(NIM_PARAMS) waku.nims

## Waku v2 tooling targets

wakucanary: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakucanary $(NIM_PARAMS) waku.nims

networkmonitor: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim networkmonitor $(NIM_PARAMS) waku.nims

## Waku docs

docs: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim doc --accept --index:on --project --out:.gh-pages waku/waku.nim waku.nims


## RLN

# Experimental flag for all experimental features
ifeq ($(EXPERIMENTAL), true)
$(eval RLN := true)
endif

# control rln code compilation
ifeq ($(RLN), true)
$(eval NIM_PARAMS := $(NIM_PARAMS) -d:rln)
endif

rlnlib:
ifeq ($(RLN), true)
	cargo build --manifest-path vendor/zerokit/rln/Cargo.toml --release
endif

# clean the rln build (forces recompile of old crates on next build)
cleanrln:
	cargo clean --manifest-path vendor/zerokit/rln/Cargo.toml


## Container image targets

# build a docker image for the fleet
docker-image: MAKE_TARGET ?= wakunode1
docker-image: DOCKER_IMAGE_TAG ?= $(MAKE_TARGET)
docker-image: DOCKER_IMAGE_NAME ?= statusteam/nim-waku:$(DOCKER_IMAGE_TAG)
docker-image:
	docker build \
		--build-arg="MAKE_TARGET=$(MAKE_TARGET)" \
		--build-arg="NIMFLAGS=$(DOCKER_IMAGE_NIMFLAGS)" \
		--tag $(DOCKER_IMAGE_NAME) .

docker-push:
	docker push $(DOCKER_IMAGE_NAME)

# usual cleaning
clean: | cleanrln
	rm -rf build
ifneq ($(USE_LIBBACKTRACE), 0)
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif


endif # "variables.mk" was not included


## Waku wrappers targets

libwaku.so: | build deps deps2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c --app:lib --noMain --nimcache:nimcache/libwaku $(NIM_PARAMS) -o:build/$@.0 wrappers/libwaku.nim && \
		rm -f build/$@ && \
		ln -s $@.0 build/$@

# libraries for dynamic linking of non-Nim objects
EXTRA_LIBS_DYNAMIC := -L"$(CURDIR)/build" -lwaku -lm
wrappers: | build deps deps2 libwaku.so
	echo -e $(BUILD_MSG) "build/C_wrapper_example" && \
		 $(CC) wrappers/wrapper_example.c -Wl,-rpath,'$$ORIGIN' $(EXTRA_LIBS_DYNAMIC) -g -o build/C_wrapper_example
	echo -e $(BUILD_MSG) "build/go_wrapper_example" && \
		go build -ldflags "-linkmode external -extldflags '$(EXTRA_LIBS_DYNAMIC)'" -o build/go_wrapper_example wrappers/wrapper_example.go #wrappers/cfuncs.go
