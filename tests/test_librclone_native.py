import os
import sys
import unittest
import tempfile
import hashlib

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

import engine
from engine.ffi_bridge import LibrcloneEngine, RcloneBridgeException

class TestLibrcloneNative(unittest.TestCase):
    def setUp(self):
        self.engine = LibrcloneEngine()

    def tearDown(self):
        self.engine.shutdown()

    def test_version_rpc(self):
        res = self.engine.execute_rpc("core/version", {})
        self.assertIn("version", res)
        self.assertIn("v1.66.0-pipesync-embedded", res["version"])

    def test_copyfile_and_hashsum(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            src = os.path.join(tmpdir, "test_file.bin")
            dst = os.path.join(tmpdir, "backup", "test_file.bin")
            payload = b"PipeSync High Performance Native FFI 2PC Test"
            with open(src, "wb") as f:
                f.write(payload)

            expected_sha256 = hashlib.sha256(payload).hexdigest()

            # Execute copy
            copy_res = self.engine.execute_rpc("operations/copyfile", {
                "srcFs": tmpdir,
                "srcRemote": "test_file.bin",
                "dstFs": os.path.join(tmpdir, "backup"),
                "dstRemote": "test_file.bin"
            })
            self.assertEqual(copy_res, {})
            self.assertTrue(os.path.exists(dst))

            # Execute hashsum
            hash_res = self.engine.execute_rpc("operations/hashsum", {
                "htype": "sha256",
                "fs": os.path.join(tmpdir, "backup"),
                "remote": "test_file.bin"
            })
            self.assertEqual(hash_res.get("hash"), expected_sha256)

            # Execute stat
            stat_res = self.engine.execute_rpc("operations/stat", {
                "fs": os.path.join(tmpdir, "backup"),
                "remote": "test_file.bin"
            })
            self.assertEqual(stat_res["item"]["size"], len(payload))
            self.assertFalse(stat_res["item"]["isDir"])

    def test_error_handling(self):
        with self.assertRaises(RcloneBridgeException) as cm:
            self.engine.execute_rpc("operations/copyfile", {
                "srcFs": "/nonexistent_dir_12345",
                "srcRemote": "ghost.bin",
                "dstFs": "/tmp",
                "dstRemote": "ghost.bin"
            })
        self.assertEqual(cm.exception.status_code, 404)

if __name__ == "__main__":
    unittest.main()
