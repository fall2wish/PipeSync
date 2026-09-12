import os
import sqlite3
import hashlib
import json
import time
import uuid
import logging
from enum import Enum
from typing import Dict, Any, List, Optional, Callable

from engine.ffi_bridge import LibrcloneEngine, RcloneBridgeException
from engine.script_sandbox import ScriptSandbox, ScriptExecutionResult
from engine.platform_pal import PlatformAbstractionLayer

logger = logging.getLogger("PipeSync.Orchestrator")

class TaskStage(str, Enum):
    PENDING = "PENDING"
    PRE_HOOK = "PRE_HOOK"
    TRANSFERRING = "TRANSFERRING"
    VERIFYING = "VERIFYING"
    PURGING = "PURGING"
    POST_HOOK = "POST_HOOK"
    COMMITTED = "COMMITTED"
    ABORTED = "ABORTED"
    RETRY_BACKOFF = "RETRY_BACKOFF"
    ISOLATED_ERROR = "ISOLATED_ERROR"
    PURGED_STALE_INDEX = "PURGED_STALE_INDEX"

class PipelineOrchestrator:
    def __init__(self, db_path: str, rclone_engine: LibrcloneEngine, sandbox: ScriptSandbox, pal: PlatformAbstractionLayer = None):
        self.db_path = db_path
        self.rclone_engine = rclone_engine
        self.sandbox = sandbox
        self.pal = pal or PlatformAbstractionLayer()
        self.stage_listeners: List[Callable[[str, TaskStage], None]] = []

        self._init_db()

    def add_stage_listener(self, listener: Callable[[str, TaskStage], None]):
        self.stage_listeners.append(listener)

    def _emit_stage(self, task_id: str, stage: TaskStage):
        for listener in self.stage_listeners:
            try:
                listener(task_id, stage)
            except Exception as e:
                logger.error(f"Error in stage listener: {e}")

    def _init_db(self):
        os.makedirs(os.path.dirname(os.path.abspath(self.db_path)), exist_ok=True)
        conn = sqlite3.connect(self.db_path)
        # Enable WAL mode for high concurrency & crash resilience
        conn.execute("PRAGMA journal_mode = WAL;")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS pipeline_tasks (
                task_id TEXT PRIMARY KEY,
                profile_id TEXT NOT NULL,
                local_path TEXT NOT NULL,
                target_path TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                local_sha256 TEXT NOT NULL,
                remote_sha256 TEXT,
                stage TEXT NOT NULL,
                retry_count INTEGER DEFAULT 0,
                error_message TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        conn.commit()
        conn.close()

    def _update_task_stage(self, task_id: str, stage: TaskStage, remote_sha256: str = None, error_message: str = None):
        conn = sqlite3.connect(self.db_path)
        cur = conn.cursor()
        cur.execute("""
            UPDATE pipeline_tasks 
            SET stage = ?, 
                remote_sha256 = COALESCE(?, remote_sha256),
                error_message = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE task_id = ?
        """, (stage.value, remote_sha256, error_message, task_id))
        conn.commit()
        conn.close()
        self._emit_stage(task_id, stage)

    def compute_sha256(self, filepath: str) -> str:
        h = hashlib.sha256()
        with open(filepath, "rb") as f:
            while chunk := f.read(65536):
                h.update(chunk)
        return h.hexdigest()

    def scan_directory(self, source_dir: str) -> List[Dict[str, Any]]:
        scanned = []
        if not os.path.exists(source_dir):
            return scanned

        for root, _, files in os.walk(source_dir):
            for file in files:
                full_path = os.path.join(root, file)
                stat = os.stat(full_path)
                mime = "image/jpeg" if file.lower().endswith((".jpg", ".jpeg")) else "application/octet-stream"
                scanned.append({
                    "path": full_path,
                    "name": file,
                    "size": stat.st_size,
                    "lastModifiedMs": int(stat.st_mtime * 1000),
                    "mimeType": mime
                })
        return scanned

    def execute_pipeline(self, profile: Dict[str, Any], source_dir: str, hook_script: str, post_hook_fn: Optional[Callable] = None) -> List[Dict[str, Any]]:
        profile_id = profile.get("id", "default_profile")
        remote_base = profile.get("remoteBasePath", "backup")

        # -------------------------------------------------------------
        # 阶段一：前置扫描与 Hook 拦截（Pre-Execution）
        # -------------------------------------------------------------
        scanned_files = self.scan_directory(source_dir)
        pipe_context = {
            "system": {
                "platform": self.pal.platform,
                "appVersion": "1.0.0"
            },
            "profile": {
                "id": profile_id,
                "name": profile.get("name", "SyncProfile"),
                "protocol": profile.get("protocol", "smb"),
                "remoteBasePath": remote_base
            },
            "files": scanned_files
        }

        sandbox_result = self.sandbox.run_pre_hook(hook_script, pipe_context)
        if not sandbox_result.is_success:
            logger.error(f"Pre-hook aborted: {sandbox_result.execution_error}")
            return [{"status": TaskStage.ABORTED, "error": sandbox_result.execution_error}]

        # Enqueue transformed plan into SQLite WAL
        task_descriptors = []
        conn = sqlite3.connect(self.db_path)
        for item in sandbox_result.transformed_plan:
            local_path = item["sourcePath"]
            target_rel = item["targetRelativePath"]
            if not os.path.exists(local_path):
                continue
            
            size = os.path.getsize(local_path)
            local_hash = self.compute_sha256(local_path)
            task_id = str(uuid.uuid4())

            conn.execute("""
                INSERT INTO pipeline_tasks 
                (task_id, profile_id, local_path, target_path, file_size, local_sha256, stage)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, (task_id, profile_id, local_path, target_rel, size, local_hash, TaskStage.PENDING.value))

            task_descriptors.append({
                "task_id": task_id,
                "local_path": local_path,
                "target_rel": target_rel,
                "file_size": size,
                "local_sha256": local_hash
            })
        conn.commit()
        conn.close()

        results = []

        # Process each item according to 2PC transaction machine
        for task in task_descriptors:
            task_id = task["task_id"]
            local_path = task["local_path"]
            target_rel = task["target_rel"]
            local_size = task["file_size"]
            local_hash = task["local_sha256"]

            # -------------------------------------------------------------
            # 阶段二：受控并发传输与进度捕获（Transferring）
            # -------------------------------------------------------------
            self._update_task_stage(task_id, TaskStage.TRANSFERRING)

            target_full_path = os.path.join(remote_base, target_rel)
            transfer_params = {
                "srcFs": os.path.dirname(local_path),
                "srcRemote": os.path.basename(local_path),
                "dstFs": os.path.dirname(target_full_path),
                "dstRemote": os.path.basename(target_full_path)
            }

            max_retries = 3
            transfer_success = False
            last_err = ""
            for attempt in range(1, max_retries + 1):
                try:
                    self.rclone_engine.execute_rpc("operations/copyfile", transfer_params)
                    transfer_success = True
                    break
                except Exception as e:
                    last_err = str(e)
                    logger.warning(f"Transfer attempt {attempt} failed for {local_path}: {e}")
                    if attempt < max_retries:
                        time.sleep(0.05 * (2 ** (attempt - 1))) # Exponential backoff

            if not transfer_success:
                self._update_task_stage(task_id, TaskStage.RETRY_BACKOFF, error_message=last_err)
                results.append({"task_id": task_id, "status": TaskStage.RETRY_BACKOFF, "error": last_err})
                continue

            # -------------------------------------------------------------
            # 阶段三：双向哈希对齐强校验（Verifying）
            # -------------------------------------------------------------
            self._update_task_stage(task_id, TaskStage.VERIFYING)

            hash_params = {
                "htype": "sha256",
                "fs": os.path.dirname(target_full_path),
                "remote": os.path.basename(target_full_path)
            }
            stat_params = {
                "fs": os.path.dirname(target_full_path),
                "remote": os.path.basename(target_full_path)
            }

            try:
                remote_hash_res = self.rclone_engine.execute_rpc("operations/hashsum", hash_params)
                remote_stat_res = self.rclone_engine.execute_rpc("operations/stat", stat_params)
                remote_hash = remote_hash_res.get("hash", "")
                remote_size = remote_stat_res.get("item", {}).get("size", -1)
            except Exception as e:
                self._update_task_stage(task_id, TaskStage.ISOLATED_ERROR, error_message=f"Verification fetch error: {e}")
                results.append({"task_id": task_id, "status": TaskStage.ISOLATED_ERROR, "error": str(e)})
                continue

            # Check 2PC condition: VerifyPass = (Hash_local == Hash_remote) && (Size_local == Size_remote)
            verify_pass = (local_hash == remote_hash) and (local_size == remote_size)

            if not verify_pass:
                # 任何哈希不匹配或大小偏差均会瞬间引发事务中止（Abort），本地原始数据绝对保留完整
                err_msg = f"Hash/Size mismatch! Local({local_size}b, {local_hash}) vs Remote({remote_size}b, {remote_hash})"
                logger.critical(f"2PC Verification failed: {err_msg}")
                self._update_task_stage(task_id, TaskStage.ISOLATED_ERROR, remote_sha256=remote_hash, error_message=err_msg)
                results.append({"task_id": task_id, "status": TaskStage.ISOLATED_ERROR, "error": err_msg})
                continue

            # -------------------------------------------------------------
            # 阶段四：安全物理清除与媒体库重对齐（Purging）
            # -------------------------------------------------------------
            self._update_task_stage(task_id, TaskStage.PURGING, remote_sha256=remote_hash)

            # Atomic unlink
            self.pal.atomic_unlink(local_path)

            # Android MediaStore resync to eliminate ghost thumbnails
            media_res = self.pal.clean_up_media_store(local_path)

            # -------------------------------------------------------------
            # 阶段五：后置业务扩展与事务提交（Post-Execution & Committed）
            # -------------------------------------------------------------
            self._update_task_stage(task_id, TaskStage.POST_HOOK)
            if post_hook_fn:
                try:
                    post_hook_fn({
                        "taskId": task_id,
                        "localPath": local_path,
                        "targetPath": target_full_path,
                        "sha256": local_hash,
                        "size": local_size
                    })
                except Exception as e:
                    logger.warning(f"PostHook execution warning: {e}")

            self._update_task_stage(task_id, TaskStage.COMMITTED)
            results.append({
                "task_id": task_id,
                "status": TaskStage.COMMITTED,
                "target_path": target_full_path,
                "sha256": local_hash
            })

        return results

    def get_task_status(self, task_id: str) -> Optional[Dict[str, Any]]:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        cur.execute("SELECT * FROM pipeline_tasks WHERE task_id = ?", (task_id,))
        row = cur.fetchone()
        conn.close()
        return dict(row) if row else None
