package com.emtek.cpd;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.res.AssetManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.ConsoleMessage;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Full-screen WebView shell for the Child Present Detection cabin-safety HMI.
 *
 * External control (Remotive bridge / adb) — either path works:
 *
 *   # 1) Activity intent (singleTask → onNewIntent)
 *   adb shell am start -n com.emtek.cpd/.MainActivity \
 *     -a com.emtek.cpd.SET_STATE --ei state 1 --ez sound true
 *
 *   # 2) Explicit broadcast (more reliable while activity is already resumed)
 *   adb shell am broadcast -a com.emtek.cpd.SET_STATE \
 *     --ei state 1 --ez sound true -n com.emtek.cpd/.MainActivity
 *
 * state: 0|3 = none, 1 = child detected, 2 = escalation
 * sound: optional boolean (default false)
 */
public class MainActivity extends Activity {

    private static final String TAG = "ChildPresentDetection";

    public static final String ACTION_SET_STATE = "com.emtek.cpd.SET_STATE";
    public static final String EXTRA_STATE = "state";
    public static final String EXTRA_SOUND = "sound";

    private static final String APP_SCHEME = "https";
    private static final String APP_HOST = "appassets.androidplatform.net";
    private static final String START_URL =
            APP_SCHEME + "://" + APP_HOST + "/index.html";

    private WebView webView;
    private boolean pageReady = false;
    private Integer pendingState = null;
    private Boolean pendingSound = null;

    private final BroadcastReceiver controlReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            Log.i(TAG, "broadcast received action=" + (intent != null ? intent.getAction() : "null"));
            handleControlIntent(intent);
        }
    };

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(TAG, "onCreate");

        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        webView = new WebView(this);
        setContentView(webView);

        WebView.setWebContentsDebuggingEnabled(true);

        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view,
                                                              WebResourceRequest request) {
                return handleRequest(request.getUrl());
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                Log.i(TAG, "onPageFinished " + url);
                pageReady = true;
                // Ensure CPD API is present, then flush any pending control
                view.evaluateJavascript(
                        "(function(){return !!(window.CPD && window.CPD.setState);})()",
                        value -> {
                            Log.i(TAG, "CPD API ready=" + value);
                            applyPending();
                        });
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest req,
                                        android.webkit.WebResourceError err) {
                Log.w(TAG, "onReceivedError " + req.getUrl() + " : " + err.getDescription());
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage cm) {
                Log.d(TAG, "[web] " + cm.message()
                        + " (" + cm.sourceId() + ":" + cm.lineNumber() + ")");
                return true;
            }
        });

        registerControlReceiver();

        if (savedInstanceState != null) {
            webView.restoreState(savedInstanceState);
        } else {
            webView.loadUrl(START_URL);
        }

        handleControlIntent(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        Log.i(TAG, "onNewIntent action=" + (intent != null ? intent.getAction() : "null")
                + " extras=" + (intent != null && intent.getExtras() != null
                ? intent.getExtras().keySet() : "null"));
        setIntent(intent);
        handleControlIntent(intent);
    }

    @Override
    protected void onResume() {
        super.onResume();
        // Re-apply last intent extras if activity was only resumed
        handleControlIntent(getIntent());
        enterImmersive();
    }

    private void registerControlReceiver() {
        IntentFilter filter = new IntentFilter(ACTION_SET_STATE);
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(controlReceiver, filter, Context.RECEIVER_EXPORTED);
            } else {
                registerReceiver(controlReceiver, filter);
            }
            Log.i(TAG, "control receiver registered for " + ACTION_SET_STATE);
        } catch (Exception e) {
            Log.e(TAG, "registerReceiver failed", e);
        }
    }

    private void handleControlIntent(Intent intent) {
        if (intent == null) return;

        boolean hasAction = ACTION_SET_STATE.equals(intent.getAction());
        boolean hasExtra = intent.hasExtra(EXTRA_STATE);
        if (!hasAction && !hasExtra) {
            return;
        }

        Integer state = extractState(intent);
        if (state == null) {
            Log.w(TAG, "control intent missing/invalid state extra; action="
                    + intent.getAction()
                    + " extras=" + (intent.getExtras() != null ? intent.getExtras() : "null"));
            return;
        }

        boolean sound = false;
        if (intent.hasExtra(EXTRA_SOUND)) {
            Object raw = intent.getExtras() != null ? intent.getExtras().get(EXTRA_SOUND) : null;
            if (raw instanceof Boolean) {
                sound = (Boolean) raw;
            } else if (raw instanceof Number) {
                sound = ((Number) raw).intValue() != 0;
            } else if (raw instanceof String) {
                sound = "true".equalsIgnoreCase((String) raw) || "1".equals(raw);
            }
        }

        Log.i(TAG, "control intent state=" + state + " sound=" + sound
                + " pageReady=" + pageReady);
        applyState(state, sound);
    }

    private static Integer extractState(Intent intent) {
        if (intent == null || intent.getExtras() == null) return null;
        Object raw = intent.getExtras().get(EXTRA_STATE);
        if (raw == null) return null;
        if (raw instanceof Integer) return (Integer) raw;
        if (raw instanceof Number) return ((Number) raw).intValue();
        if (raw instanceof String) return parseStateString((String) raw);
        return parseStateString(String.valueOf(raw));
    }

    private static Integer parseStateString(String s) {
        if (s == null) return null;
        s = s.trim().toLowerCase(Locale.US);
        switch (s) {
            case "0":
            case "3":
            case "none":
            case "clear":
                return 0;
            case "1":
            case "detected":
            case "child":
            case "child_detected":
                return 1;
            case "2":
            case "escalation":
            case "alert":
                return 2;
            default:
                try {
                    return Integer.parseInt(s);
                } catch (NumberFormatException e) {
                    return null;
                }
        }
    }

    private void applyState(int state, boolean sound) {
        if (!pageReady || webView == null) {
            pendingState = state;
            pendingSound = sound;
            Log.i(TAG, "page not ready — queued state=" + state);
            return;
        }
        // Map 0 → none code 0 (JS accepts 0 and 3)
        final int code = state;
        final boolean wantSound = sound;
        final String js = String.format(
                Locale.US,
                "(function(){try{"
                        + "if(!window.CPD){return 'no-cpd';}"
                        + "var ok=CPD.setState(%d,{sound:%s});"
                        + "return 'ok state='+CPD.getState()+' code='+CPD.getStateCode()+' set='+ok;"
                        + "}catch(e){return 'err:'+e;}})()",
                code,
                wantSound ? "true" : "false"
        );

        runOnUiThread(() -> {
            if (webView == null) return;
            Log.i(TAG, "evaluateJavascript state=" + code + " sound=" + wantSound);
            webView.evaluateJavascript(js, value ->
                    Log.i(TAG, "JS result=" + value));
        });
    }

    private void applyPending() {
        if (pendingState != null) {
            int st = pendingState;
            boolean snd = pendingSound != null && pendingSound;
            pendingState = null;
            pendingSound = null;
            applyState(st, snd);
        }
    }

    private WebResourceResponse handleRequest(Uri uri) {
        if (uri == null || !APP_HOST.equals(uri.getHost())) {
            return null;
        }
        String path = uri.getPath();
        if (path == null || path.isEmpty() || "/".equals(path)) {
            path = "index.html";
        } else if (path.startsWith("/")) {
            path = path.substring(1);
        }

        Map<String, String> headers = new HashMap<>();
        headers.put("Access-Control-Allow-Origin", "*");
        headers.put("Cache-Control", "no-store");

        AssetManager am = getAssets();
        try {
            InputStream is = am.open(path);
            String mime = guessMime(path);
            String enc = isTextual(mime) ? "utf-8" : null;
            WebResourceResponse resp = new WebResourceResponse(mime, enc, is);
            resp.setResponseHeaders(headers);
            return resp;
        } catch (IOException notFound) {
            return new WebResourceResponse("text/plain", "utf-8", 404, "Not Found",
                    headers, new ByteArrayInputStream(new byte[0]));
        }
    }

    private static boolean isTextual(String mime) {
        return mime.startsWith("text/")
                || mime.contains("javascript")
                || mime.contains("json")
                || mime.contains("xml")
                || mime.contains("svg");
    }

    private static String guessMime(String path) {
        String p = path.toLowerCase(Locale.US);
        if (p.endsWith(".html") || p.endsWith(".htm")) return "text/html";
        if (p.endsWith(".js") || p.endsWith(".mjs")) return "application/javascript";
        if (p.endsWith(".css")) return "text/css";
        if (p.endsWith(".json")) return "application/json";
        if (p.endsWith(".svg")) return "image/svg+xml";
        if (p.endsWith(".png")) return "image/png";
        if (p.endsWith(".jpg") || p.endsWith(".jpeg")) return "image/jpeg";
        if (p.endsWith(".gif")) return "image/gif";
        if (p.endsWith(".webp")) return "image/webp";
        if (p.endsWith(".ico")) return "image/x-icon";
        if (p.endsWith(".woff2")) return "font/woff2";
        if (p.endsWith(".woff")) return "font/woff";
        if (p.endsWith(".ttf")) return "font/ttf";
        return "application/octet-stream";
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) enterImmersive();
    }

    @SuppressWarnings("deprecation")
    private void enterImmersive() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        if (webView != null) {
            webView.saveState(outState);
        }
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        try {
            unregisterReceiver(controlReceiver);
        } catch (Exception ignored) {
        }
        if (webView != null) {
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
