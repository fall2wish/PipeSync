#!/usr/bin/env python3
import os
import xml.etree.ElementTree as ET
import unittest

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANDROID_DIR = os.path.join(BASE_DIR, "android")

class TestAndroidWebKitIntegration(unittest.TestCase):

    def test_android_manifest_structure(self):
        """Verify AndroidManifest.xml conforms to Android 14/15 dataSync & storage requirements."""
        manifest_path = os.path.join(ANDROID_DIR, "app/src/main/AndroidManifest.xml")
        self.assertTrue(os.path.exists(manifest_path), "AndroidManifest.xml must exist")

        tree = ET.parse(manifest_path)
        root = tree.getroot()

        self.assertEqual(root.attrib.get("package"), "com.pipesync.app")

        # Check permissions
        permissions = [elem.attrib.get("{http://schemas.android.com/apk/res/android}name") 
                       for elem in root.findall("uses-permission")]
        self.assertIn("android.permission.INTERNET", permissions)
        self.assertIn("android.permission.WAKE_LOCK", permissions)
        self.assertIn("android.permission.FOREGROUND_SERVICE", permissions)
        self.assertIn("android.permission.FOREGROUND_SERVICE_DATA_SYNC", permissions)
        self.assertIn("android.permission.MANAGE_EXTERNAL_STORAGE", permissions)
        self.assertIn("android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", permissions)

        # Check Service declaration with dataSync foregroundServiceType
        app_elem = root.find("application")
        self.assertIsNotNone(app_elem)
        services = app_elem.findall("service")
        data_sync_service = None
        for svc in services:
            svc_name = svc.attrib.get("{http://schemas.android.com/apk/res/android}name")
            if "TransferForegroundService" in svc_name:
                data_sync_service = svc
                break

        self.assertIsNotNone(data_sync_service, "TransferForegroundService must be declared")
        fg_type = data_sync_service.attrib.get("{http://schemas.android.com/apk/res/android}foregroundServiceType")
        self.assertEqual(fg_type, "dataSync", "TransferForegroundService must declare foregroundServiceType=dataSync")

        # Check MainActivity
        activities = app_elem.findall("activity")
        main_activity = None
        for act in activities:
            act_name = act.attrib.get("{http://schemas.android.com/apk/res/android}name")
            if "MainActivity" in act_name:
                main_activity = act
                break
        self.assertIsNotNone(main_activity, "MainActivity must be declared")

    def test_android_bridge_and_service_code(self):
        """Verify Kotlin native bridge and foreground service source code."""
        bridge_path = os.path.join(ANDROID_DIR, "app/src/main/kotlin/com/pipesync/app/bridge/PipeSyncNativeBridge.kt")
        self.assertTrue(os.path.exists(bridge_path))
        with open(bridge_path, "r", encoding="utf-8") as f:
            bridge_content = f.read()

        self.assertIn("@JavascriptInterface", bridge_content)
        self.assertIn("isStoragePermissionGranted", bridge_content)
        self.assertIn("requestStoragePermission", bridge_content)
        self.assertIn("isBatteryOptimizationIgnored", bridge_content)
        self.assertIn("requestIgnoreBatteryOptimizations", bridge_content)
        self.assertIn("cleanUpMediaStore", bridge_content)
        self.assertIn("ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION", bridge_content)

        service_path = os.path.join(ANDROID_DIR, "app/src/main/kotlin/com/pipesync/app/platform/android/TransferForegroundService.kt")
        self.assertTrue(os.path.exists(service_path))
        with open(service_path, "r", encoding="utf-8") as f:
            service_content = f.read()

        self.assertIn("FOREGROUND_SERVICE_TYPE_DATA_SYNC", service_content)
        self.assertIn("SAFE_RELAY_INTERVAL_MS", service_content)
        self.assertIn("onTimeout", service_content)
        self.assertIn("PARTIAL_WAKE_LOCK", service_content)
        self.assertIn("WIFI_MODE_FULL_HIGH_PERF", service_content)

        activity_path = os.path.join(ANDROID_DIR, "app/src/main/kotlin/com/pipesync/app/MainActivity.kt")
        self.assertTrue(os.path.exists(activity_path))
        with open(activity_path, "r", encoding="utf-8") as f:
            activity_content = f.read()

        self.assertIn("addJavascriptInterface", activity_content)
        self.assertIn("PipeSyncNative", activity_content)
        self.assertIn("TransferForegroundService.start", activity_content)

    def test_android_jni_libraries(self):
        """Verify native .so libraries are packaged into jniLibs."""
        x86_rclone = os.path.join(ANDROID_DIR, "app/src/main/jniLibs/x86_64/librclone.so")
        x86_qjs = os.path.join(ANDROID_DIR, "app/src/main/jniLibs/x86_64/libpipesync_quickjs.so")
        arm_rclone = os.path.join(ANDROID_DIR, "app/src/main/jniLibs/arm64-v8a/librclone.so")
        arm_qjs = os.path.join(ANDROID_DIR, "app/src/main/jniLibs/arm64-v8a/libpipesync_quickjs.so")

        self.assertTrue(os.path.exists(x86_rclone), "x86_64 librclone.so must exist")
        self.assertTrue(os.path.exists(x86_qjs), "x86_64 libpipesync_quickjs.so must exist")
        self.assertTrue(os.path.exists(arm_rclone), "arm64-v8a librclone.so must exist")
        self.assertTrue(os.path.exists(arm_qjs), "arm64-v8a libpipesync_quickjs.so must exist")

    def test_syncthing_gui_android_integration(self):
        """Verify syncthing_gui.dart includes Android WebKit bridge hooks and native controls."""
        gui_path = os.path.join(BASE_DIR, "dart/lib/web/syncthing_gui.dart")
        with open(gui_path, "r", encoding="utf-8") as f:
            gui_content = f.read()

        self.assertIn("PipeSyncNative", gui_content)
        self.assertIn("checkAndroidNative", gui_content)
        self.assertIn("isStoragePermissionGranted", gui_content)
        self.assertIn("requestStoragePermission", gui_content)
        self.assertIn("requestIgnoreBatteryOptimizations", gui_content)
        self.assertIn("cleanUpMediaStore", gui_content)
        self.assertIn("androidNoticeBanner", gui_content)
        self.assertIn("/storage/emulated/0/DCIM/Camera", gui_content)

if __name__ == "__main__":
    unittest.main()
