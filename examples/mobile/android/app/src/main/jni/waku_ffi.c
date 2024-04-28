#include "libwaku.h"
#include <android/log.h>
#include <jni.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// cb_result represents a response received when executing a callback
// if `error` is true, `message` will contain the error message description
// otherwise, it will contain the result of the callback execution
typedef struct {
  bool error;
  char *message;
} cb_result;

// frees the results associated to the allocation of a cb_result
void free_cb_result(cb_result *result) {
  if (result != NULL) {
    free(result->message);
    free(result);
  }
}

// callback executed by libwaku functions. It expects user_data to be a cb_result*.
void on_response(int ret, const char *msg, size_t len, void *user_data) {
  if (ret != 0) {
    char errMsg[300];
    sprintf(errMsg, "function execution failed. Returned code: %d, %s\n", ret, msg);
    if (user_data != NULL) {
      cb_result **data_ref = (cb_result **)user_data;
      (*data_ref) = malloc(sizeof(cb_result));
      (*data_ref)->error = true;
      (*data_ref)->message = malloc(len * sizeof(char) + 1);
      strcpy((*data_ref)->message, msg);
    }
    return;
  }

  if (user_data == NULL)
    return;

  if (len == 0) {
    len = 2;
    msg = "ok";
  }

  cb_result **data_ref = (cb_result **)user_data;
  (*data_ref) = malloc(sizeof(cb_result));
  (*data_ref)->error = false;
  (*data_ref)->message = malloc(len * sizeof(char) + 1);
  strcpy((*data_ref)->message, msg);
}

// converts a cb_result into an instance of the kotlin WakuResult class
jobject to_jni_result(JNIEnv *env, cb_result *result) {
  jclass myStructClass = (*env)->FindClass(env, "com/mobile/WakuResult");
  jmethodID constructor = (*env)->GetMethodID(env, myStructClass, "<init>", "(ZLjava/lang/String;)V");

  jboolean error;
  jstring message;
  if (result != NULL) {
    error = result->error;
    message = (*env)->NewStringUTF(env, result->message);
  } else {
    error = false;
    message = (*env)->NewStringUTF(env, "ok");
  }

  jobject response = (*env)->NewObject(env, myStructClass, constructor, error, message);

  // Free the intermediate message var
  (*env)->DeleteLocalRef(env, message);

  return response;
}

// converts a cb_result into an instance of the kotlin WakuPtr class
jobject to_jni_ptr(JNIEnv *env, cb_result *result, void *ptr) {
  jclass myStructClass = (*env)->FindClass(env, "com/mobile/WakuPtr");
  jmethodID constructor = (*env)->GetMethodID(env, myStructClass, "<init>", "(ZLjava/lang/String;J)V");

  jboolean error;
  jstring message;
  jlong wakuPtr;
  if (result != NULL) {
    error = result->error;
    message = (*env)->NewStringUTF(env, result->message);
    wakuPtr = -1;
  } else {
    error = false;
    message = (*env)->NewStringUTF(env, "ok");
    wakuPtr = (jlong)ptr;
  }

  jobject response = (*env)->NewObject(env, myStructClass, constructor, error, message, wakuPtr);

  // Free the intermediate message var
  (*env)->DeleteLocalRef(env, message);

  return response;
}

// libwaku functions

void Java_com_mobile_WakuModule_wakuSetup(JNIEnv *env, jobject thiz) {
  waku_setup();
}

jobject Java_com_mobile_WakuModule_wakuNew(JNIEnv *env, jobject thiz, jstring configJson) {
  const char *config = (*env)->GetStringUTFChars(env, configJson, 0);
  cb_result *result = NULL;
  void *wakuPtr = waku_new(config, on_response, (void *)&result);
  jobject response = to_jni_ptr(env, result, wakuPtr);
  (*env)->ReleaseStringUTFChars(env, configJson, config);
  free_cb_result(result);
  return response;
}

jobject Java_com_mobile_WakuModule_wakuStart(JNIEnv *env, jobject thiz, jlong wakuPtr) {
  cb_result *result = NULL;
  waku_start((void *)wakuPtr, on_response, &result);
  jobject response = to_jni_result(env, result);
  free_cb_result(result);
  return response;
}

jobject Java_com_mobile_WakuModule_wakuVersion(JNIEnv *env, jobject thiz, jlong wakuPtr) {
  cb_result *result = NULL;
  waku_version((void *)wakuPtr, on_response, (void *)&result);
  jobject response = to_jni_result(env, result);
  free_cb_result(result);
  return response;
}

jobject Java_com_mobile_WakuModule_wakuStop(JNIEnv *env, jobject thiz, jlong wakuPtr) {
  cb_result *result = NULL;
  waku_stop((void *)wakuPtr, on_response, &result);
  jobject response = to_jni_result(env, result);
  free_cb_result(result);
  return response;
}

jobject Java_com_mobile_WakuModule_wakuDestroy(JNIEnv *env, jobject thiz, jlong wakuPtr) {
  cb_result *result = NULL;
  waku_destroy((void *)wakuPtr, on_response, &result);
  jobject response = to_jni_result(env, result);
  free_cb_result(result);
  return response;
}

jobject Java_com_mobile_WakuModule_wakuConnect(JNIEnv *env, jobject thiz, jlong wakuPtr, jstring peerMultiAddr, jint timeoutMs) {
  cb_result *result = NULL;
  const char *peer = (*env)->GetStringUTFChars(env, peerMultiAddr, 0);
  waku_connect((void *)wakuPtr, peer, timeoutMs, on_response, &result);
  jobject response = to_jni_result(env, result);
  free_cb_result(result);
  (*env)->ReleaseStringUTFChars(env, peerMultiAddr, peer);
  return response;
}
