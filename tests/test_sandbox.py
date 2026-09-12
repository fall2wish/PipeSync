import os
import sys
import unittest

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

import engine
from engine.script_sandbox import ScriptSandbox

class TestScriptSandbox(unittest.TestCase):
    def setUp(self):
        self.sandbox = ScriptSandbox()

    def test_pre_hook_filtering_and_renaming(self):
        hook_script = """(() => {
            const finalQueue = [];
            for (const item of PipeContext.files) {
                if (item.name.endsWith(".tmp") || item.name.startsWith(".")) {
                    PipeContext.utils.log(`Discarding transient file: ${item.name}`);
                    continue;
                }
                const formattedDate = PipeContext.utils.formatDate(item.lastModifiedMs, "yyyy-MM-dd");
                finalQueue.push({
                    sourcePath: item.path,
                    targetRelativePath: `${formattedDate}/${item.name}`
                });
            }
            return finalQueue;
        })();"""

        context = {
            "system": {"platform": "android", "appVersion": "1.0.0"},
            "profile": {"id": "p1", "name": "Test", "protocol": "smb", "remoteBasePath": "dest"},
            "files": [
                {"path": "/storage/pic1.jpg", "name": "pic1.jpg", "size": 1000, "lastModifiedMs": 1715000000000, "mimeType": "image/jpeg"},
                {"path": "/storage/temp.tmp", "name": "temp.tmp", "size": 200, "lastModifiedMs": 1715000000000, "mimeType": "application/octet-stream"},
                {"path": "/storage/.hidden", "name": ".hidden", "size": 100, "lastModifiedMs": 1715000000000, "mimeType": "application/octet-stream"}
            ]
        }

        res = self.sandbox.run_pre_hook(hook_script, context)
        self.assertTrue(res.is_success)
        self.assertEqual(len(res.transformed_plan), 1)
        self.assertEqual(res.transformed_plan[0]["sourcePath"], "/storage/pic1.jpg")
        self.assertEqual(res.transformed_plan[0]["targetRelativePath"], "2024-05-06/pic1.jpg")

    def test_timeout_protection(self):
        infinite_loop = "while(true){}"
        res = self.sandbox.run_pre_hook(infinite_loop, {}, timeout_ms=300)
        self.assertFalse(res.is_success)
        self.assertIn("timeout", res.execution_error.lower())

    def test_syntax_error(self):
        bad_syntax = "const a = ;"
        res = self.sandbox.run_pre_hook(bad_syntax, {})
        self.assertFalse(res.is_success)
        self.assertIsNotNone(res.execution_error)

if __name__ == "__main__":
    unittest.main()
