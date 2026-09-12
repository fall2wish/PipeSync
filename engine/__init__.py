import os
import sys
import importlib.util

def _load_module(mod_name, file_name):
    cur_dir = os.path.dirname(os.path.abspath(__file__))
    file_path = os.path.join(cur_dir, file_name)
    spec = importlib.util.spec_from_file_location(mod_name, file_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = mod
    spec.loader.exec_module(mod)
    return mod

ffi_bridge = _load_module('engine.ffi_bridge', 'ffi_bridge.py')
script_sandbox = _load_module('engine.script_sandbox', 'script_sandbox.py')
platform_pal = _load_module('engine.platform_pal', 'platform_pal.py')
orchestrator = _load_module('engine.orchestrator', 'orchestrator.py')
