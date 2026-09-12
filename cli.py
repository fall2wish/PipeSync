#!/usr/bin/env python3
import os
import sys
import argparse
import json

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

import engine

def main():
    parser = argparse.ArgumentParser(description="PipeSync CLI - High Performance 2PC Verify & Purge Data Pipeline")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    subparsers.add_parser("version", help="Show PipeSync version and librclone status")

    import tempfile
    default_db = os.path.join(tempfile.gettempdir(), "pipesync_wal.db")

    serve_parser = subparsers.add_parser("serve", help="Start Syncthing-style Web Console & background sync daemon")
    serve_parser.add_argument("--port", type=int, default=8384, help="Web GUI port (default: 8384)")
    serve_parser.add_argument("--host", default="127.0.0.1", help="Host address to bind to")
    serve_parser.add_argument("--config", help="Path to config file")
    serve_parser.add_argument("--db", default=default_db, help="Path to SQLite WAL database")

    run_parser = subparsers.add_parser("run", help="Run a synchronization pipeline")
    run_parser.add_argument("--source", required=True, help="Local source directory to scan and sync")
    run_parser.add_argument("--dest", required=True, help="Remote destination directory")
    run_parser.add_argument("--db", default=default_db, help="Path to SQLite WAL database")
    run_parser.add_argument("--plugin", default=os.path.join(BASE_DIR, "plugins", "installed", "org.pipesync.media-cleaner"), help="Path to plugin directory")

    status_parser = subparsers.add_parser("status", help="Inspect pipeline task database")
    status_parser.add_argument("--db", default=default_db, help="Path to SQLite WAL database")

    plugins_parser = subparsers.add_parser("plugins", help="Inspect installed plugins and verification status")
    plugins_parser.add_argument("--dir", default=os.path.join(BASE_DIR, "plugins"), help="Plugins directory")

    copilot_parser = subparsers.add_parser("copilot", help="AI Copilot rule generator and sandbox validation")
    copilot_parser.add_argument("--prompt", default="Organize media by YYYY-MM-DD", help="Natural language prompt")

    subparsers.add_parser("android", help="Display Android native WebKit host project details and jniLibs status")

    phone_parser = subparsers.add_parser("pull-phone", help="Pull and synchronize files from connected phone via 2PC verification")
    phone_parser.add_argument("--device", default="192.168.1.227:44825", help="ADB serial or IP:port of phone")
    phone_parser.add_argument("--source", default="/sdcard/Browser", help="Source folder path on phone")
    phone_parser.add_argument("--dest", default="/mnt/f/bak/phone/Browser", help="Destination folder on PC")
    phone_parser.add_argument("--db", default=default_db, help="Path to SQLite WAL database")

    args = parser.parse_args()

    if args.command == "version":
        rclone = engine.ffi_bridge.LibrcloneEngine()
        ver = rclone.execute_rpc("core/version", {})
        rclone.shutdown()
        print("PipeSync Version: 1.0.0 (Dart 3.x / FFI / QuickJS Hybrid)")
        print(f"Librclone CGo/FFI: {ver.get('version')} ({ver.get('os')}/{ver.get('arch')})")
        return

    if args.command == "run":
        hook_path = os.path.join(args.plugin, "hooks.js")
        if not os.path.exists(hook_path):
            print(f"Error: hook script not found at {hook_path}")
            sys.exit(1)
        with open(hook_path, "r") as f:
            hook_script = f.read()

        manifest_path = os.path.join(args.plugin, "manifest.json")
        manifest = {}
        if os.path.exists(manifest_path):
            with open(manifest_path, "r") as f:
                manifest = json.load(f)

        profile = {
            "id": manifest.get("id", "default_profile"),
            "name": manifest.get("name", "Default Profile"),
            "protocol": "smb",
            "remoteBasePath": args.dest
        }

        print("[*] Starting PipeSync 2PC Verify & Purge Pipeline...")
        print(f"[*] Profile: {profile.get('name')} ({profile.get('id')})")
        print(f"[*] Source:  {args.source}")
        print(f"[*] Dest:    {args.dest}")
        print(f"[*] SQLite:  {args.db}")

        rclone = engine.ffi_bridge.LibrcloneEngine()
        sandbox = engine.script_sandbox.ScriptSandbox()
        pal = engine.platform_pal.PlatformAbstractionLayer()
        orchestrator = engine.orchestrator.PipelineOrchestrator(args.db, rclone, sandbox, pal)

        def on_stage_change(task_id, stage):
            print(f"    -> [Task {task_id[:8]}] State: {stage.value}")

        orchestrator.add_stage_listener(on_stage_change)

        results = orchestrator.execute_pipeline(profile, args.source, hook_script)
        rclone.shutdown()

        print("\n[+] Execution Finished. Results:")
        for r in results:
            print(f"    - Task: {r.get('task_id', 'N/A')[:8]} | Status: {r.get('status')} | Target: {r.get('target_path', 'N/A')}")
        return

    if args.command == "status":
        import sqlite3
        if not os.path.exists(args.db):
            print(f"Database does not exist: {args.db}")
            return
        conn = sqlite3.connect(args.db)
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        cur.execute("SELECT task_id, profile_id, local_path, target_path, stage, local_sha256, remote_sha256, updated_at FROM pipeline_tasks ORDER BY updated_at DESC")
        rows = cur.fetchall()
        conn.close()
        print(f"Tasks in DB ({len(rows)} total):")
        for row in rows:
            print(f"[{row['stage']}] {row['task_id'][:8]} | {row['target_path']} | Local:{row['local_sha256'][:10]}... | Remote:{str(row['remote_sha256'])[:10]}...")
        return

    if args.command == "serve":
        binary_path = os.path.join(BASE_DIR, "build", "pipesync")
        cmd = []
        if os.path.exists(binary_path) and os.access(binary_path, os.X_OK):
            cmd = [binary_path, "serve", "--port", str(args.port), "--host", args.host, "--db", args.db]
            if args.config:
                cmd.extend(["--config", args.config])
        else:
            cmd = ["dart", os.path.join(BASE_DIR, "dart", "bin", "pipesync.dart"), "serve", "--port", str(args.port), "--host", args.host, "--db", args.db]
            if args.config:
                cmd.extend(["--config", args.config])
        import subprocess
        try:
            subprocess.run(cmd)
        except KeyboardInterrupt:
            print("\n[*] PipeSync daemon stopped.")
        return

    if args.command == "plugins":
        import hashlib
        reg_file = os.path.join(args.dir, "registry.json")
        if not os.path.exists(reg_file):
            print(f"Registry not found: {reg_file}")
            return
        with open(reg_file, "r") as f:
            reg = json.load(f)
        plugins = reg.get("plugins", [])
        print(f"Installed Plugins ({len(plugins)} found in {args.dir}):")
        for p_info in plugins:
            plugin_dir = os.path.join(args.dir, p_info.get("installedPath", ""))
            mf_path = os.path.join(plugin_dir, "manifest.json")
            if not os.path.exists(mf_path):
                continue
            with open(mf_path, "r") as mf_f:
                mf = json.load(mf_f)
            hook_file = os.path.join(plugin_dir, mf.get("entrypoints", {}).get("hookScript", "hooks.js"))
            verified = False
            if os.path.exists(hook_file):
                with open(hook_file, "rb") as hf:
                    actual_sha = hashlib.sha256(hf.read()).hexdigest()
                expected_sha = mf.get("integrity", {}).get("hookScriptSha256", "")
                verified = (actual_sha.lower() == expected_sha.lower())
            status_label = "VERIFIED [OK]" if verified else "FAIL"
            print(f"- {mf.get('name')} ({p_info.get('id')}) v{mf.get('version')}")
            print(f"  Enabled: {p_info.get('enabled')} | Integrity: {status_label}")
            print(f"  Description: {mf.get('description')}")
            print(f"  Permissions: {', '.join(mf.get('permissions', []))}")
        return

    if args.command == "copilot":
        binary_path = os.path.join(BASE_DIR, "build", "pipesync")
        if os.path.exists(binary_path) and os.access(binary_path, os.X_OK):
            import subprocess
            subprocess.run([binary_path, "copilot", "--prompt", args.prompt])
        else:
            import subprocess
            subprocess.run(["dart", os.path.join(BASE_DIR, "dart", "bin", "pipesync.dart"), "copilot", "--prompt", args.prompt])
        return

    if args.command == "android":
        manifest_path = os.path.join(BASE_DIR, "android", "app", "src", "main", "AndroidManifest.xml")
        exists = os.path.exists(manifest_path)
        x86_rclone = os.path.exists(os.path.join(BASE_DIR, "android", "app", "src", "main", "jniLibs", "x86_64", "librclone.so"))
        arm_rclone = os.path.exists(os.path.join(BASE_DIR, "android", "app", "src", "main", "jniLibs", "arm64-v8a", "librclone.so"))
        print("════════════════════════════════════════════════════════════════")
        print("      PipeSync Android Native Host & Embedded WebKit Info       ")
        print("════════════════════════════════════════════════════════════════")
        print(f"[*] Project Path:    {os.path.join(BASE_DIR, 'android')}")
        print(f"[*] Manifest:        {'VALID [OK]' if exists else 'MISSING'}")
        print("[*] Storage Engine:  MANAGE_EXTERNAL_STORAGE (Direct POSIX)")
        print("[*] Background Svc:  TransferForegroundService (dataSync 5.5h Relay)")
        print("[*] MediaStore Sync: MediaScanner Dirty Cache Auto-Flush")
        print("[*] WebKit Bridge:   PipeSyncNativeBridge (window.PipeSyncNative)")
        print(f"[*] Native Libs:     x86_64: {'[OK]' if x86_rclone else '[MISSING]'} | arm64-v8a: {'[OK]' if arm_rclone else '[MISSING]'}")
        print("\nTo build Android APK with Embedded WebKit:")
        print("  cd android && ./gradlew assembleRelease")
        print("  (or open the 'android' folder in Android Studio)")
        return

    if args.command == "pull-phone":
        from scripts.sync_phone import sync_browser_folder
        sync_browser_folder(device_serial=args.device, phone_dir=args.source, dest_dir=args.dest, db_path=args.db)
        return

    parser.print_help()

if __name__ == "__main__":
    main()
