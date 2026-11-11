package com.imapp.opoinstall;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.opoinstall.api.OpoData;
import com.opoinstall.api.OpoError;
import com.opoinstall.api.OpoInstall;
import com.opoinstall.api.ResultCallBack;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Opo（opoinstall.com）Android 端桥接。
 *
 * 2026-11-11 新建：客户账号在 Opo 体系，官方没有 Flutter 插件；
 * 旧用的 openinstall_flutter_plugin 内置的是**老版** SDK（com.openinstall.*），
 * 与 Opo 不同产品、appKey 不通用，初始化直接报「appKey错误」→ INIT_ERROR。
 *
 * 原生 API 对应关系（OpoInstall_v2.1.0.jar）：
 *   initialize(Context)                       → 读 AndroidManifest 的 com.opoinstall.APP_KEY
 *   start(Activity)                           → 触发采集与服务端交互，必须 Activity 就绪后调用
 *   getInstallParam(timeout, cb)              → 首装参数（onResult(OpoData) / onError(OpoError)）
 *   registerDeepLinkCallback(Application, cb) → 拉起参数（含冷启动）
 *   handleDeepLink(Intent, cb)                → 运行中被 scheme 拉起
 *   register()                                → 上报注册事件
 *   getOpId()                                 → 设备标识，全 0 表示未激活成功
 */
public class OpoInstallPlugin
        implements FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private static final String TAG = "OpoInstallBridge";
    private static final String METHOD_CHANNEL = "im_app/opoinstall";
    private static final String EVENT_CHANNEL = "im_app/opoinstall/wakeup";

    private final Handler main = new Handler(Looper.getMainLooper());

    private Context appContext;
    private Activity activity;

    private MethodChannel methodChannel;
    private EventChannel eventChannel;

    private EventChannel.EventSink sink;
    /** 冷启动的拉起参数可能早于 Dart 订阅到达，先缓存，订阅时补发一次 */
    private Map<String, Object> pendingWakeup;

    private OpoInstall sdk;
    private String initError = "";

    // ==================== FlutterPlugin ====================

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        appContext = binding.getApplicationContext();
        methodChannel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
        methodChannel.setMethodCallHandler(this);
        eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL);
        eventChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                sink = events;
                if (pendingWakeup != null) {
                    events.success(pendingWakeup);
                    pendingWakeup = null;
                }
            }

            @Override
            public void onCancel(Object arguments) {
                sink = null;
            }
        });
        // 引擎创建即初始化（比等 Activity 就绪更早，首装归因窗口更稳）。
        // appKey 缺失时 initialize 会抛 IllegalArgumentException —— 绝不外抛，
        // 记下原因，等 Dart 调 getInstallParam 时作为 errorMsg 回传。
        try {
            initializeSdk(false, false);
        } catch (Throwable t) {
            initError = String.valueOf(t.getMessage());
            Log.e(TAG, "initialize failed", t);
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (methodChannel != null) {
            methodChannel.setMethodCallHandler(null);
            methodChannel = null;
        }
        if (eventChannel != null) {
            eventChannel.setStreamHandler(null);
            eventChannel = null;
        }
        sink = null;
        appContext = null;
    }

    // ==================== ActivityAware ====================

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        // start() 需要 Activity：触发设备采集 + 与服务器交互
        try {
            if (sdk != null && activity != null) sdk.start(activity);
        } catch (Throwable t) {
            Log.e(TAG, "start failed", t);
        }
        // 冷启动本身就是被 scheme 拉起时，首个 Intent 也要交给 SDK
        handleIntent(activity != null ? activity.getIntent() : null);

        binding.addOnNewIntentListener(new PluginRegistry.NewIntentListener() {
            @Override
            public boolean onNewIntent(Intent intent) {
                handleIntent(intent);
                return false; // 不拦截：微信/推送等其它插件仍要收到
            }
        });
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        activity = null;
    }

    // ==================== MethodCallHandler ====================

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "initialize": {
                boolean debug = Boolean.TRUE.equals(call.argument("debug"));
                boolean disableSim = Boolean.TRUE.equals(call.argument("disableSimulatorCheck"));
                try {
                    initializeSdk(debug, disableSim);
                    result.success(safeVersion());
                } catch (Throwable t) {
                    initError = String.valueOf(t.getMessage());
                    // 不抛错：让 Dart 侧走「拿不到参数」的降级分支，避免影响启动
                    result.success("");
                }
                break;
            }
            case "getVersion":
                result.success(safeVersion());
                break;
            case "getOpId":
                result.success(safeOpid());
                break;
            case "start":
                try {
                    if (sdk != null && activity != null) sdk.start(activity);
                    result.success(null);
                } catch (Throwable t) {
                    result.error("START_FAILED", String.valueOf(t.getMessage()), null);
                }
                break;
            case "register":
                try {
                    if (sdk != null) sdk.register();
                    result.success(null);
                } catch (Throwable t) {
                    result.error("REGISTER_FAILED", String.valueOf(t.getMessage()), null);
                }
                break;
            case "getInstallParam": {
                if (sdk == null) {
                    result.success(errorMap(-1,
                            "SDK 未初始化：" + (initError.isEmpty() ? "未知原因" : initError), false));
                    break;
                }
                int timeout = 10;
                Object t = call.argument("timeout");
                if (t instanceof Number) timeout = ((Number) t).intValue();
                final MethodChannel.Result pending = result;
                final AtomicBoolean replied = new AtomicBoolean(false);
                try {
                    sdk.getInstallParam(timeout, new ResultCallBack<OpoData>() {
                        @Override
                        public void onResult(OpoData data) {
                            if (replied.compareAndSet(false, true)) {
                                postSuccess(pending, mapFromData(data));
                            }
                        }

                        @Override
                        public void onError(OpoError error) {
                            if (replied.compareAndSet(false, true)) {
                                postSuccess(pending, mapFromError(error));
                            }
                        }
                    });
                } catch (Throwable th) {
                    if (replied.compareAndSet(false, true)) {
                        pending.success(errorMap(-1, String.valueOf(th.getMessage()), false));
                    }
                }
                break;
            }
            case "handleDeepLink":
                if (activity == null) {
                    result.success(null);
                } else {
                    handleIntent(activity.getIntent());
                    result.success(null);
                }
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    // ==================== 内部实现 ====================

    private void initializeSdk(boolean debug, boolean disableSimulatorCheck) {
        if (sdk != null) return;
        OpoInstall.setDebug(debug);
        sdk = OpoInstall.initialize(appContext);
        if (disableSimulatorCheck) {
            // 仅诊断包调用：默认 SDK 在模拟器上会拒绝统计，排障时关掉才能看到真实错误
            try {
                sdk.disableCheckSimulator();
            } catch (Throwable t) {
                Log.w(TAG, "disableCheckSimulator failed", t);
            }
        }
        try {
            sdk.registerDeepLinkCallback((Application) appContext.getApplicationContext(),
                    new ResultCallBack<OpoData>() {
                        @Override
                        public void onResult(OpoData data) {
                            emitWakeup(mapFromData(data));
                        }

                        @Override
                        public void onError(OpoError error) {
                            emitWakeup(mapFromError(error));
                        }
                    });
        } catch (Throwable t) {
            Log.w(TAG, "registerDeepLinkCallback failed", t);
        }
        Log.i(TAG, "SDK initialized, version=" + safeVersion());
    }

    private void handleIntent(@Nullable Intent intent) {
        if (sdk == null || intent == null) return;
        try {
            sdk.handleDeepLink(intent, new ResultCallBack<OpoData>() {
                @Override
                public void onResult(OpoData data) {
                    emitWakeup(mapFromData(data));
                }

                @Override
                public void onError(OpoError error) {
                    // 普通启动（LAUNCHER Intent）也会回调错误，属正常，不打扰 Dart
                    if (error.getErrorCode() != OpoError.INVALID_INTENT) {
                        emitWakeup(mapFromError(error));
                    }
                }
            });
        } catch (Throwable t) {
            Log.w(TAG, "handleDeepLink failed", t);
        }
    }

    private void emitWakeup(final Map<String, Object> data) {
        main.post(new Runnable() {
            @Override
            public void run() {
                if (sink != null) {
                    sink.success(data);
                } else {
                    pendingWakeup = data;
                }
            }
        });
    }

    private void postSuccess(final MethodChannel.Result result, final Map<String, Object> data) {
        main.post(new Runnable() {
            @Override
            public void run() {
                result.success(data);
            }
        });
    }

    private String safeVersion() {
        try {
            return OpoInstall.getVersion();
        } catch (Throwable t) {
            return "";
        }
    }

    private String safeOpid() {
        try {
            return sdk != null ? sdk.getOpoid() : "";
        } catch (Throwable t) {
            return "";
        }
    }

    private Map<String, Object> mapFromData(OpoData data) {
        Map<String, Object> m = new HashMap<>();
        m.put("ok", true);
        m.put("bindData", data != null && data.getBindData() != null ? data.getBindData() : "");
        m.put("channelCode",
                data != null && data.getChannelCode() != null ? data.getChannelCode() : "");
        m.put("opid", safeOpid());
        m.put("errorCode", 0);
        m.put("errorMsg", "");
        m.put("shouldRetry", false);
        return m;
    }

    private Map<String, Object> mapFromError(OpoError error) {
        return errorMap(error.getErrorCode(), error.getErrorMsg(), error.shouldRetry());
    }

    private Map<String, Object> errorMap(int code, String msg, boolean shouldRetry) {
        Map<String, Object> m = new HashMap<>();
        m.put("ok", false);
        m.put("bindData", "");
        m.put("channelCode", "");
        m.put("opid", safeOpid());
        m.put("errorCode", code);
        m.put("errorMsg", msg == null ? "" : msg);
        m.put("shouldRetry", shouldRetry);
        return m;
    }
}
