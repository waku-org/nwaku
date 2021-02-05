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
DOCKER_IMAGE_NIM_PARAMS ?= -d:chronicles_colors:none -d:insecure

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

.PHONY: \
	all \
	deps \
	update \
	sim1 \
	wakunode1 \
	wakunode2 \
	example1 \
	example2 \
	bridge \
	test \
	clean \
	libbacktrace

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
all: | wakunode1 sim1 example1 wakunode2 sim2 example2 chat2 bridge

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

deps: | deps-common nat-libs waku.nims
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

#- deletes and recreates "waku.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -rf waku.nims && \
		$(MAKE) waku.nims $(HANDLE_OUTPUT)

# a phony target, because teaching `make` how to do conditional recompilation of Nim projects is too complicated

# Waku v1 targets
wakunode1: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakunode1 $(NIM_PARAMS) waku.nims

sim1: | build deps wakunode1
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim sim1 $(NIM_PARAMS) waku.nims

example1: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim example1 $(NIM_PARAMS) waku.nims

test1: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim test1 $(NIM_PARAMS) waku.nims

docs: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim doc --accept --index:on --project --out:.gh-pages waku/waku.nim waku.nims

# Waku v2 targets
wakunode2: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakunode2 $(NIM_PARAMS) waku.nims

sim2: | build deps wakunode2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim sim2 $(NIM_PARAMS) waku.nims

example2: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim example2 $(NIM_PARAMS) waku.nims

# detecting the os
ifeq ($(OS),Windows_NT) # is Windows_NT on XP, 2000, 7, Vista, 10...
 detected_OS := Windows
else ifeq ($(strip $(shell uname)),Darwin)
 detected_OS := macOS
else
 # e.g. Linux
 detected_OS := $(strip $(shell uname))
endif

installganache: 
	npm install ganache-cli; npx ganache-cli -p	8540	-g	0	-l	3000000000000&


test2: | build deps installganache
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim test2 $(NIM_PARAMS) waku.nims
	# the following command (pkill -f ganache-cli) attempts to kill ganache-cli process on macos  
	# if we do not kill the process then it would hang there and causes issue in GitHub Actions macos job (the job never finsihes)
	(([[ $(detected_OS) = macOS ]] && \
		pkill -f ganache-cli) || true)

scripts2: | build deps wakunode2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim scripts2 $(NIM_PARAMS) waku.nims

chat2: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim chat2 $(NIM_PARAMS) waku.nims

bridge: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim bridge $(NIM_PARAMS) waku.nims

# Builds and run the test suite (Waku v1 + v2)
test: | test1 test2

# symlink
waku.nims:
	ln -s waku.nimble $@

# nim-libbacktrace
libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

# build a docker image for the fleet
docker-image: MAKE_TARGET ?= wakunode1
docker-image: DOCKER_IMAGE_TAG ?= $(MAKE_TARGET)
docker-image: DOCKER_IMAGE_NAME ?= statusteam/nim-waku:$(DOCKER_IMAGE_TAG)
docker-image:
	docker build \
		--build-arg="MAKE_TARGET=$(MAKE_TARGET)" \
		--build-arg="NIM_PARAMS=$(DOCKER_IMAGE_NIM_PARAMS)" \
		--tag $(DOCKER_IMAGE_NAME) .

docker-push:
	docker push $(DOCKER_IMAGE_NAME)

# usual cleaning
clean: | clean-common
	rm -rf build
ifneq ($(USE_LIBBACKTRACE), 0)
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif

endif # "variables.mk" was not included
