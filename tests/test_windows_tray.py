#!/usr/bin/env python3
import os
import sys
import unittest
from unittest.mock import MagicMock

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOWS_DIR = os.path.join(BASE_DIR, "windows")

class TestWindowsTrayAndAutostart(unittest.TestCase):

    def test_win32_tray_c_source(self):
        """Verify Win32 C implementation of tray, autostart registry toggle, and process supervision."""
        c_path = os.path.join(WINDOWS_DIR, "tray", "pipesync_tray.c")
        self.assertTrue(os.path.exists(c_path), "pipesync_tray.c must exist")

        with open(c_path, "r", encoding="utf-8") as f:
            code = f.read()

        # Check Tray Shell integration
        self.assertIn("Shell_NotifyIconW", code)
        self.assertIn("NOTIFYICONDATAW", code)
        self.assertIn("WM_TRAYICON", code)
        self.assertIn("WM_RBUTTONUP", code)

        # Check Autostart Registry manipulation
        self.assertIn("CurrentVersion\\\\Run", code)
        self.assertIn("RUN_VALUE_NAME", code)
        self.assertIn("RegOpenKeyExW", code)
        self.assertIn("RegSetValueExW", code)
        self.assertIn("RegDeleteValueW", code)
        self.assertIn("IsAutostartEnabled", code)
        self.assertIn("ToggleAutostart", code)

        # Check Context Menu & Status
        self.assertIn("ID_TRAY_STATUS", code)
        self.assertIn("ID_TRAY_CONSOLE", code)
        self.assertIn("ID_TRAY_AUTOSTART", code)
        self.assertIn("MF_CHECKED", code)
        self.assertIn("MF_UNCHECKED", code)

        # Check Background process supervision without black window
        self.assertIn("CreateProcessW", code)
        self.assertIn("CREATE_NO_WINDOW", code)
        self.assertIn("GetExitCodeProcess", code)

    def test_windows_tray_python_manager(self):
        """Verify WindowsAutostartManager logic with mocked winreg."""
        tray_py_path = os.path.join(WINDOWS_DIR, "tray", "pipesync_tray.py")
        self.assertTrue(os.path.exists(tray_py_path))

        # Test with mock winreg
        mock_winreg = MagicMock()
        mock_key = MagicMock()
        mock_winreg.HKEY_CURRENT_USER = "HKEY_CURRENT_USER"
        mock_winreg.KEY_READ = 1
        mock_winreg.KEY_SET_VALUE = 2
        mock_winreg.REG_SZ = 1

        mock_winreg.OpenKey.return_value.__enter__.return_value = mock_key
        mock_winreg.QueryValueEx.return_value = (r'"C:\PipeSync\pipesync_tray.exe" --minimized', 1)

        sys.modules['winreg'] = mock_winreg
        try:
            from windows.tray.pipesync_tray import WindowsAutostartManager
            # Mock sys.platform to win32
            original_platform = sys.platform
            sys.platform = "win32"
            try:
                # Query autostart
                self.assertTrue(WindowsAutostartManager.is_autostart_enabled())
                mock_winreg.QueryValueEx.assert_called()

                # Enable autostart
                self.assertTrue(WindowsAutostartManager.set_autostart(True, r'"C:\pipesync.exe"'))
                mock_winreg.SetValueEx.assert_called()

                # Disable autostart
                self.assertTrue(WindowsAutostartManager.set_autostart(False))
                mock_winreg.DeleteValue.assert_called()
            finally:
                sys.platform = original_platform
        finally:
            if 'winreg' in sys.modules:
                del sys.modules['winreg']

    def test_cmakelists_and_documentation(self):
        """Verify CMakeLists.txt defines PipeSyncTray and README-Windows.txt exists."""
        cmakelists_path = os.path.join(BASE_DIR, "CMakeLists.txt")
        with open(cmakelists_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("PipeSyncTray", content)
        self.assertIn("windows/tray/pipesync_tray.c", content)

        readme_win = os.path.join(WINDOWS_DIR, "README-Windows.txt")
        self.assertTrue(os.path.exists(readme_win))
        with open(readme_win, "r", encoding="utf-8") as f:
            readme_text = f.read()
        self.assertIn("PipeSyncTray.exe", readme_text)
        self.assertIn("开机自动启动", readme_text)

if __name__ == "__main__":
    unittest.main()
