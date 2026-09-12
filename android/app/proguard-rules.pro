# Keep JavascriptInterface methods
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# Keep PipeSync Native Bridge
-keep class com.pipesync.app.bridge.** { *; }
-keep class com.pipesync.app.platform.android.** { *; }
