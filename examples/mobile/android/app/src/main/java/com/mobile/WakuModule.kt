package com.mobile
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.Promise
import android.util.Log
import java.math.BigInteger

class WakuPtr(val error: Boolean, val errorMessage: String, val ptr: Long)

class WakuResult(val error: Boolean, val message: String)

class WakuModule(reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {
    override fun getName() = "WakuModule"

    external fun wakuSetup()
    external fun wakuNew(configJson: String): WakuPtr
    external fun wakuStart(ctx: Long): WakuResult
    external fun wakuVersion(ctx: Long): WakuResult
    external fun wakuStop(ctx: Long): WakuResult
    external fun wakuDestroy(ctx: Long): WakuResult
    external fun wakuConnect(ctx: Long, peerMultiAddr: String, timeoutMs: Int): WakuResult

    @ReactMethod
    fun setup(promise: Promise) {
        wakuSetup()
        promise.resolve(null)
    }

    @ReactMethod
    fun new(promise: Promise) {
        // TODO: config should be parameter
        val response = wakuNew("{\"host\":\"0.0.0.0\", \"port\":42342, \"key\":\"1122334455667788990011223344556677889900112233445566778899001122\", \"relay\":true}")
        if (response.error) {
            promise.reject("waku_new", response.errorMessage)
        } else {
            promise.resolve(BigInteger.valueOf(response.ptr).toString())
        }
    }

    @ReactMethod
    fun start(ctx: String, promise: Promise) {
        val wakuPtr = BigInteger(ctx).toLong()
        val response = wakuStart(wakuPtr)
        if (response.error) {
            promise.reject("waku_start", response.message)
        } else {
            promise.resolve(null)
        }
    }

    @ReactMethod
    fun version(ctx: String, promise: Promise) {
        val wakuPtr = BigInteger(ctx).toLong()
        val response = wakuVersion(wakuPtr)
        if (response.error) {
            promise.reject("waku_version", response.message)
        } else {
            promise.resolve(response.message)
        }
    }

    @ReactMethod
    fun stop(ctx: String, promise: Promise) {
        val wakuPtr = BigInteger(ctx).toLong()
        val response = wakuStop(wakuPtr)
        if (response.error) {
            promise.reject("waku_stop", response.message)
        } else {
            promise.resolve(null)
        }
    }

    @ReactMethod
    fun destroy(ctx: String, promise: Promise) {
        val wakuPtr = BigInteger(ctx).toLong()
        val response = wakuDestroy(wakuPtr)
        if (response.error) {
            promise.reject("waku_destroy", response.message)
        } else {
            promise.resolve(null)
        }
    }

    @ReactMethod
    fun connect(ctx: String, peerMultiAddr: String, timeoutMs: Int, promise: Promise) {
        val wakuPtr = BigInteger(ctx).toLong()
        val response = wakuConnect(wakuPtr, peerMultiAddr, timeoutMs)
        if (response.error) {
            promise.reject("waku_connect", response.message)
        } else {
            promise.resolve(null)
        }
    }
}
