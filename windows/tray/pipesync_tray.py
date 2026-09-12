#!/usr/bin/env python3
"""
PipeSync Windows System Tray Controller & Autostart Manager (Python Implementation)
Provides cross-environment support and verification for Windows registry startup and tray operations.
"""
import os
import sys
import webbrowser

RUN_KEY_PATH = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_VALUE_NAME = "PipeSync"
DEFAULT_CONSOLE_URL = "http://127.0.0.1:8384"

class WindowsAutostartManager:
    @staticmethod
    def is_autostart_enabled() -> bool:
        if sys.platform != "win32":
            return False
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY_PATH, 0, winreg.KEY_READ) as key:
                val, _ = winreg.QueryValueEx(key, RUN_VALUE_NAME)
                return bool(val)
        except (FileNotFoundError, OSError):
            return False

    @staticmethod
    def set_autostart(enabled: bool, command_line: str = None) -> bool:
        if sys.platform != "win32":
            return False
        import winreg
        try:
            if enabled:
                if not command_line:
                    exe_path = sys.executable
                    script_path = os.path.abspath(__file__)
                    command_line = f'"{exe_path}" "{script_path}" --minimized'
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY_PATH, 0, winreg.KEY_SET_VALUE) as key:
                    winreg.SetValueEx(key, RUN_VALUE_NAME, 0, winreg.REG_SZ, command_line)
                return True
            else:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY_PATH, 0, winreg.KEY_SET_VALUE) as key:
                    try:
                        winreg.DeleteValue(key, RUN_VALUE_NAME)
                    except FileNotFoundError:
                        pass
                return True
        except OSError as e:
            print(f"Error updating autostart registry: {e}")
            return False

    @staticmethod
    def toggle_autostart(command_line: str = None) -> bool:
        current = WindowsAutostartManager.is_autostart_enabled()
        WindowsAutostartManager.set_autostart(not current, command_line)
        return WindowsAutostartManager.is_autostart_enabled()

def open_console():
    webbrowser.open(DEFAULT_CONSOLE_URL)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--status":
        status = "ENABLED" if WindowsAutostartManager.is_autostart_enabled() else "DISABLED"
        print(f"PipeSync Windows Autostart: {status}")
    elif len(sys.argv) > 1 and sys.argv[1] == "--toggle":
        new_state = WindowsAutostartManager.toggle_autostart()
        print(f"PipeSync Windows Autostart changed to: {'ENABLED' if new_state else 'DISABLED'}")
    else:
        open_console()
