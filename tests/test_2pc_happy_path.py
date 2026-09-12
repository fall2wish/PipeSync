import os
import sys
import unittest
import tempfile
import hashlib

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

import engine
from engine.orchestrator import PipelineOrchestrator, TaskStage

class Test2PCHappyPath(unittest.TestCase):
    def test_full_pipeline_success(self):
        with tempfile.TemporaryDirectory() as base_tmp:
            src_dir = os.path.join(base_tmp, "source")
            dst_dir = os.path.join(base_tmp, "remote_dest")
            db_path = os.path.join(base_tmp, "tasks_wal.db")
            os.makedirs(src_dir, exist_ok=True)
            os.makedirs(dst_dir, exist_ok=True)

            # Create test files
            # 1. Valid image file
            file1_path = os.path.join(src_dir, "photo_01.jpg")
            with open(file1_path, "wb") as f:
                f.write(b"JPEG_BINARY_DATA_SAMPLE_2026")
            file1_hash = hashlib.sha256(b"JPEG_BINARY_DATA_SAMPLE_2026").hexdigest()

            # 2. Transient temp file (should be filtered out by preHook)
            tmp_path = os.path.join(src_dir, "download.tmp")
            with open(tmp_path, "wb") as f:
                f.write(b"TEMPORARY_DATA")

            # PreHook script
            hook_script = """(() => {
                const finalQueue = [];
                for (const item of PipeContext.files) {
                    if (item.name.endsWith(".tmp")) {
                        continue;
                    }
                    const dateStr = PipeContext.utils.formatDate(item.lastModifiedMs, "yyyy-MM-dd");
                    finalQueue.push({
                        sourcePath: item.path,
                        targetRelativePath: `${dateStr}/${item.name}`
                    });
                }
                return finalQueue;
            })();"""

            rclone = engine.ffi_bridge.LibrcloneEngine()
            sandbox = engine.script_sandbox.ScriptSandbox()
            pal = engine.platform_pal.PlatformAbstractionLayer(platform="android")
            orchestrator = PipelineOrchestrator(db_path, rclone, sandbox, pal)

            stages_emitted = []
            orchestrator.add_stage_listener(lambda tid, st: stages_emitted.append(st))

            profile = {
                "id": "profile_media_test",
                "name": "Media Sync Profile",
                "protocol": "smb",
                "remoteBasePath": dst_dir
            }

            results = orchestrator.execute_pipeline(profile, src_dir, hook_script)
            rclone.shutdown()

            # Assertions
            self.assertEqual(len(results), 1)
            task_res = results[0]
            self.assertEqual(task_res["status"], TaskStage.COMMITTED)
            self.assertEqual(task_res["sha256"], file1_hash)

            # Assert stages went through full 2PC
            self.assertIn(TaskStage.TRANSFERRING, stages_emitted)
            self.assertIn(TaskStage.VERIFYING, stages_emitted)
            self.assertIn(TaskStage.PURGING, stages_emitted)
            self.assertIn(TaskStage.COMMITTED, stages_emitted)

            # Assert destination file exists and is identical
            target_dest_file = task_res["target_path"]
            self.assertTrue(os.path.exists(target_dest_file))
            with open(target_dest_file, "rb") as f:
                self.assertEqual(f.read(), b"JPEG_BINARY_DATA_SAMPLE_2026")

            # Assert local source file was safely unlinked
            self.assertFalse(os.path.exists(file1_path))

            # Assert transient temp file was NOT touched/deleted
            self.assertTrue(os.path.exists(tmp_path))

            # Assert Android MediaStore cleanup was recorded
            self.assertEqual(len(pal.media_store_sync_log), 1)
            self.assertEqual(pal.media_store_sync_log[0]["path"], file1_path)

if __name__ == "__main__":
    unittest.main()
