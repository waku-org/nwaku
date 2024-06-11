LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE := waku
LOCAL_SRC_FILES := ../jniLibs/$(TARGET_ARCH_ABI)/libwaku.so

include $(PREBUILT_SHARED_LIBRARY)

include $(CLEAR_VARS)

LOCAL_SRC_FILES := waku_ffi.c
LOCAL_MODULE := waku_jni
LOCAL_LDLIBS := -llog
LOCAL_SHARED_LIBRARIES := waku

include $(BUILD_SHARED_LIBRARY)