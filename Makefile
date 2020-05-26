# Copyright (c) 2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by Make

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# Docker image name
DOCKER_IMAGE_TAG ?= latest
DOCKER_IMAGE_NAME ?= statusteam/nim-waku:$(DOCKER_IMAGE_TAG)
# Necessary to enable Prometheus HTTP endpoint for metrics
DOCKER_IMAGE_NIM_PARAMS ?= -d:insecure

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

.PHONY: \
	all \
	deps \
	update \
	wakunode \
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
all: | wakunode wakusim

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

deps: | deps-common waku.nims
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

#- deletes and recreates "waku.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -rf waku.nims && \
		$(MAKE) waku.nims $(HANDLE_OUTPUT)

# a phony target, because teaching `make` how to do conditional recompilation of Nim projects is too complicated
wakunode: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakunode $(NIM_PARAMS) waku.nims

wakusim: | build deps wakunode
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakusim $(NIM_PARAMS) waku.nims

wakunode2: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakunode2 $(NIM_PARAMS) waku.nims

wakusim2: | build deps wakunode2
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakusim2 $(NIM_PARAMS) waku.nims

protocol2:
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim protocol2 $(NIM_PARAMS) waku.nims

wakutest2:
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakutest2 $(NIM_PARAMS) waku.nims

# symlink
waku.nims:
	ln -s waku.nimble $@

# nim-libbacktrace
libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

# build a docker image for the fleet
docker-image:
	docker build \
		--build-arg="NIM_PARAMS=$(DOCKER_IMAGE_NIM_PARAMS)" \
		--tag $(DOCKER_IMAGE_NAME) .

docker-push:
	docker push $(DOCKER_IMAGE_NAME)

# builds and runs the test suite
test: | build deps
	$(ENV_SCRIPT) nim test $(NIM_PARAMS) waku.nims

# usual cleaning
clean: | clean-common
	rm -rf build/{wakunode,quicksim,start_network,all_tests}
ifneq ($(USE_LIBBACKTRACE), 0)
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif

endif # "variables.mk" was not included
