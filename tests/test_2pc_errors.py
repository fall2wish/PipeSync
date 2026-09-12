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

class CorruptingLibrcloneEngine(engine.ffi_bridge.LibrcloneEngine):
    def execute_rpc(self, method, params):
        res = super().execute_rpc(method, params)
        if method == "operations/hashsum":
            return {"hash": "0000000000000000000000000000000000000000000000000000000000000000"}
        return res

class Test2PCErrors(unittest.TestCase):
    def test_hash_mismatch_triggers_abort_and_preserves_local_file(self):
        with tempfile.TemporaryDirectory() as base_tmp:
            src_dir = os.path.join(base_tmp, "source")
            dst_dir = os.path.join(base_tmp, "remote_dest")
            db_path = os.path.join(base_tmp, "tasks_wal.db")
            os.makedirs(src_dir, exist_ok=True)
            os.makedirs(dst_dir, exist_ok=True)

            critical_file = os.path.join(src_dir, "critical_document.pdf")
            payload = b"CRITICAL_USER_DATA_DO_NOT_LOSE"
            with open(critical_file, "wb") as f:
                f.write(payload)

            hook_script = "(() => { return PipeContext.files.map(f => ({ sourcePath: f.path, targetRelativePath: 'documents/' + f.name })); })();"

            rclone = CorruptingLibrcloneEngine()
            sandbox = engine.script_sandbox.ScriptSandbox()
            pal = engine.platform_pal.PlatformAbstractionLayer()
            orchestrator = PipelineOrchestrator(db_path, rclone, sandbox, pal)

            stages_emitted = []
            orchestrator.add_stage_listener(lambda tid, st: stages_emitted.append(st))

            profile = {
                "id": "profile_corrupt_test",
                "name": "Corrupt Sync Test",
                "protocol": "smb",
                "remoteBasePath": dst_dir
            }

            results = orchestrator.execute_pipeline(profile, src_dir, hook_script)
            rclone.shutdown()

            self.assertEqual(len(results), 1)
            self.assertEqual(results[0]["status"], TaskStage.ISOLATED_ERROR)
            self.assertIn("Hash/Size mismatch", results[0]["error"])

            self.assertNotIn(TaskStage.PURGING, stages_emitted)
            self.assertNotIn(TaskStage.COMMITTED, stages_emitted)
            self.assertIn(TaskStage.ISOLATED_ERROR, stages_emitted)

            # CRITICAL CHECK: Local file MUST remain completely intact!
            self.assertTrue(os.path.exists(critical_file))
            with open(critical_file, "rb") as f:
                self.assertEqual(f.read(), payload)

            task_status = orchestrator.get_task_status(results[0]["task_id"])
            self.assertEqual(task_status["stage"], TaskStage.ISOLATED_ERROR.value)

    def test_pre_hook_syntax_error_aborts_cleanly(self):
        with tempfile.TemporaryDirectory() as base_tmp:
            src_dir = os.path.join(base_tmp, "source")
            dst_dir = os.path.join(base_tmp, "remote_dest")
            db_path = os.path.join(base_tmp, "tasks_wal.db")
            os.makedirs(src_dir, exist_ok=True)

            test_file = os.path.join(src_dir, "file.txt")
            with open(test_file, "w") as f:
                f.write("hello")

            bad_hook = "throw new Error('Sandbox rule crashed');"

            rclone = engine.ffi_bridge.LibrcloneEngine()
            sandbox = engine.script_sandbox.ScriptSandbox()
            pal = engine.platform_pal.PlatformAbstractionLayer()
            orchestrator = PipelineOrchestrator(db_path, rclone, sandbox, pal)

            profile = {"id": "p_bad", "name": "Bad Profile", "protocol": "smb", "remoteBasePath": dst_dir}
            results = orchestrator.execute_pipeline(profile, src_dir, bad_hook)
            rclone.shutdown()

            self.assertEqual(len(results), 1)
            self.assertEqual(results[0]["status"], TaskStage.ABORTED)
            self.assertTrue(os.path.exists(test_file))

if __name__ == "__main__":
    unittest.main()
