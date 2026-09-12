#!/usr/bin/env python3
"""
PipeSync Phone-to-Desktop 2PC Synchronization Runner
Transfers files from Android phone (/sdcard/Browser) to Windows Desktop (F:\bak\phone\Browser)
using Two-Phase Commit (2PC) with strict SHA-256 integrity verification.
"""

import os
import sys
import subprocess
import hashlib
import sqlite3
import time
import uuid

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADB_PATH = os.path.expanduser("~/.local/platform-tools/adb")

def run_adb(device_serial, cmd_args):
    cmd = [ADB_PATH, "-s", device_serial] + cmd_args
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if res.returncode != 0:
        raise RuntimeError(f"ADB command failed: {cmd}\nStderr: {res.stderr}")
    return res.stdout

def compute_local_sha256(filepath):
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def get_phone_sha256(device_serial, remote_file):
    out = run_adb(device_serial, ["shell", f"sha256sum '{remote_file}'"])
    parts = out.strip().split()
    if parts:
        return parts[0].strip().lower()
    raise ValueError(f"Could not compute sha256 for {remote_file}")

def init_db(db_path):
    os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS pipeline_tasks (
            task_id TEXT PRIMARY KEY,
            source_device TEXT NOT NULL,
            source_path TEXT NOT NULL,
            target_path TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            source_sha256 TEXT NOT NULL,
            target_sha256 TEXT,
            stage TEXT NOT NULL,
            error_message TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    """)
    conn.commit()
    return conn

def sync_browser_folder(device_serial="192.168.1.227:44825",
                        phone_dir="/sdcard/Browser",
                        dest_dir="/mnt/f/bak/phone/Browser",
                        db_path=None):
    if db_path is None:
        db_path = os.path.join(dest_dir, ".pipesync", "pipesync_wal.db")

    conn = init_db(db_path)
    os.makedirs(dest_dir, exist_ok=True)
    staging_dir = os.path.join(dest_dir, ".pipesync_staging")
    os.makedirs(staging_dir, exist_ok=True)

    print("════════════════════════════════════════════════════════════════")
    print("      PipeSync 2PC Verify & Purge Data Synchronization Engine   ")
    print("════════════════════════════════════════════════════════════════")
    print(f"[*] Source Device: {device_serial} (Android PKX110)")
    print(f"[*] Source Path:   {phone_dir}")
    print(f"[*] Target Path:   {dest_dir} (F:\\bak\\phone\\Browser)")
    print(f"[*] SQLite WAL:    {db_path}")
    print("────────────────────────────────────────────────────────────────")

    # Step 1: List files on phone
    ls_out = run_adb(device_serial, ["shell", f"ls -1 '{phone_dir}'"])
    filenames = [f.strip() for f in ls_out.splitlines() if f.strip() and not f.startswith(".")]

    print(f"[*] Found {len(filenames)} candidate files on phone in {phone_dir}:")
    for f in filenames:
        print(f"    - {f}")
    print("────────────────────────────────────────────────────────────────")

    results = []
    total_bytes = 0

    for idx, filename in enumerate(filenames, start=1):
        remote_file = f"{phone_dir}/{filename}"
        final_dest_file = os.path.join(dest_dir, filename)
        staging_file = os.path.join(staging_dir, f"{filename}.staging.{uuid.uuid4().hex[:8]}")
        task_id = str(uuid.uuid4())

        print(f"\n[{idx}/{len(filenames)}] Processing: {filename}")

        # Phase 1: Pre-Hook & Remote Hash Sampling
        print(f"    [Stage 1: PRE_HOOK] Fetching source metadata & computing remote SHA-256...")
        remote_sha = get_phone_sha256(device_serial, remote_file)
        
        # Get file size
        stat_out = run_adb(device_serial, ["shell", f"stat -c %s '{remote_file}' 2>/dev/null || wc -c < '{remote_file}'"])
        file_size = int(stat_out.strip().split()[0])
        print(f"    -> Size: {file_size:,} bytes | Source SHA-256: {remote_sha[:12]}...{remote_sha[-8:]}")

        conn.execute("""
            INSERT INTO pipeline_tasks 
            (task_id, source_device, source_path, target_path, file_size, source_sha256, stage)
            VALUES (?, ?, ?, ?, ?, ?, 'TRANSFERRING')
        """, (task_id, device_serial, remote_file, final_dest_file, file_size, remote_sha))
        conn.commit()

        # Phase 2: Controlled Transfer to Staging Area
        print(f"    [Stage 2: TRANSFERRING] Streaming to staging area: {os.path.basename(staging_file)}...")
        pull_cmd = [ADB_PATH, "-s", device_serial, "pull", remote_file, staging_file]
        pull_res = subprocess.run(pull_cmd, capture_output=True, text=True)
        if pull_res.returncode != 0:
            err = f"ADB pull failed: {pull_res.stderr.strip()}"
            print(f"    [!] Transfer Failed: {err}")
            conn.execute("UPDATE pipeline_tasks SET stage='RETRY_BACKOFF', error_message=? WHERE task_id=?", (err, task_id))
            conn.commit()
            results.append({"file": filename, "status": "FAILED", "error": err})
            continue

        staged_size = os.path.getsize(staging_file)
        print(f"    -> Staged transfer complete ({staged_size:,} bytes)")

        # Phase 3: Two-Phase Verification (Verify SHA-256)
        print(f"    [Stage 3: VERIFYING] Verifying cryptographic hash alignment...")
        local_sha = compute_local_sha256(staging_file)
        print(f"    -> Local Staged SHA-256:  {local_sha}")
        print(f"    -> Remote Source SHA-256: {remote_sha}")

        if local_sha.lower() != remote_sha.lower() or staged_size != file_size:
            err = f"Hash/Size Mismatch! Staged({staged_size}b, {local_sha}) vs Source({file_size}b, {remote_sha})"
            print(f"    [!] VERIFICATION FAILED: {err}")
            print("    [!] ABORTING: Removing corrupted staging file. Source file is PRESERVED.")
            os.remove(staging_file)
            conn.execute("UPDATE pipeline_tasks SET stage='ISOLATED_ERROR', target_sha256=?, error_message=? WHERE task_id=?", (local_sha, err, task_id))
            conn.commit()
            results.append({"file": filename, "status": "ISOLATED_ERROR", "error": err})
            continue

        print(f"    -> [✓] 2PC Verification PASSED: Cryptographic integrity 100% matches!")

        # Phase 4: Atomic Commit
        print(f"    [Stage 4: COMMITTED] Atomically committing to destination...")
        if os.path.exists(final_dest_file):
            os.remove(final_dest_file)
        os.rename(staging_file, final_dest_file)

        # Preserve remote timestamp if possible
        try:
            mod_time = int(run_adb(device_serial, ["shell", f"stat -c %Y '{remote_file}'"]).strip())
            os.utime(final_dest_file, (mod_time, mod_time))
        except Exception:
            pass

        conn.execute("""
            UPDATE pipeline_tasks 
            SET stage='COMMITTED', target_sha256=?, updated_at=CURRENT_TIMESTAMP 
            WHERE task_id=?
        """, (local_sha, task_id))
        conn.commit()

        total_bytes += file_size
        results.append({
            "file": filename,
            "status": "COMMITTED",
            "size": file_size,
            "sha256": local_sha
        })
        print(f"    -> [✓] Successfully committed to {final_dest_file}")

    # Clean up staging directory if empty
    try:
        os.rmdir(staging_dir)
    except Exception:
        pass

    conn.close()

    print("\n════════════════════════════════════════════════════════════════")
    print("                 2PC SYNCHRONIZATION SUMMARY                    ")
    print("════════════════════════════════════════════════════════════════")
    print(f"Total Files Synchronized: {len([r for r in results if r['status'] == 'COMMITTED'])} / {len(filenames)}")
    print(f"Total Bytes Transferred:  {total_bytes:,} bytes ({total_bytes / (1024*1024):.2f} MB)")
    print("----------------------------------------------------------------")
    for r in results:
        status_symbol = "✓" if r["status"] == "COMMITTED" else "✗"
        print(f"[{status_symbol}] {r['file']:<30} | {r.get('size', 0):>10,} bytes | {r.get('sha256', 'N/A')[:16]}... | {r['status']}")
    print("════════════════════════════════════════════════════════════════\n")

    return results

if __name__ == "__main__":
    device = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.227:44825"
    sync_browser_folder(device_serial=device)
