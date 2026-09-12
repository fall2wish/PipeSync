import ctypes
import json
import os
import sys
from typing import Dict, Any

class RcloneRPCResultNative(ctypes.Structure):
    _fields_ = [
        ("output", ctypes.c_void_p),
        ("status", ctypes.c_int)
    ]

class RcloneBridgeException(Exception):
    def __init__(self, status_code: int, details: str):
        super().__init__(f"RcloneBridgeException(code: {status_code}, details: {details})")
        self.status_code = status_code
        self.details = details

class LibrcloneEngine:
    def __init__(self, lib_path: str = None):
        if lib_path is None:
            base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            if sys.platform == "win32":
                lib_name = "librclone.dll"
            elif sys.platform == "darwin":
                lib_name = "librclone.dylib"
            else:
                lib_name = "librclone.so"
            lib_path = os.path.join(base_dir, "native", lib_name)

        if not os.path.exists(lib_path):
            raise FileNotFoundError(f"Native shared library not found at: {lib_path}")

        self._lib = ctypes.CDLL(lib_path)

        self._initialize = self._lib.RcloneInitialize
        self._initialize.argtypes = []
        self._initialize.restype = None

        self._finalize = self._lib.RcloneFinalize
        self._finalize.argtypes = []
        self._finalize.restype = None

        self._rpc = self._lib.RcloneRPC
        self._rpc.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        self._rpc.restype = RcloneRPCResultNative

        self._free_string = self._lib.RcloneFreeString
        self._free_string.argtypes = [ctypes.c_void_p]
        self._free_string.restype = None

        self._initialize()
        self._is_active = True

    def execute_rpc(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        if not self._is_active:
            raise RuntimeError("LibrcloneEngine has been finalized")

        method_bytes = method.encode('utf-8')
        input_bytes = json.dumps(params).encode('utf-8')

        result = self._rpc(method_bytes, input_bytes)
        raw_output = ""
        if result.output:
            raw_output = ctypes.string_at(result.output).decode('utf-8')
            self._free_string(result.output)

        status_code = result.status

        if status_code != 200:
            raise RcloneBridgeException(status_code, raw_output)

        try:
            return json.loads(raw_output) if raw_output else {}
        except json.JSONDecodeError:
            return {"raw": raw_output}

    def shutdown(self):
        if self._is_active:
            self._finalize()
            self._is_active = False

    def __del__(self):
        try:
            self.shutdown()
        except Exception:
            pass
