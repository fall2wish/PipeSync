import "dart:convert";
import "dart:io";
import "package:crypto/crypto.dart";
import "package:path/path.dart" as p;
import "package:test/test.dart";

import "../lib/core/ffi/librclone_bindings.dart";
import "../lib/core/pipeline/pipeline_contract.dart";
import "../lib/core/pipeline/pipeline_orchestrator.dart";
import "../lib/core/scripting/script_sandbox.dart";
import "../lib/platform/platform_abstraction.dart";
import "../lib/plugins/plugin_hub.dart";
import "../lib/copilot/ai_copilot.dart";
import "../lib/daemon/sync_daemon.dart";
import "../lib/web/web_server.dart";

void main() {
  group("Milestone 1: Librclone CGo/C-Shared FFI & Worker Isolate", () {
    late LibrcloneEngine engine;

    setUp(() {
      engine = LibrcloneEngine();
    });

    tearDown(() {
      engine.shutdown();
    });

    test("core/version returns valid version and platform info", () async {
      final res = await engine.executeRpc("core/version", {});
      expect(res["version"], contains("v1.66.0-pipesync-embedded"));
      expect(res["os"], isNotEmpty);
      expect(res["arch"], equals("amd64"));
    });

    test("core/stats reports transfer metrics", () async {
      final res = await engine.executeRpc("core/stats", {});
      expect(res.containsKey("bytes"), isTrue);
    });

    test("operations/copyfile and operations/hashsum verify data integrity", () async {
      final tempDir = Directory.systemTemp.createTempSync("pipesync_rclone_test_");
      final srcFile = File(p.join(tempDir.path, "test_file.txt"));
      const content = "Hello PipeSync Librclone FFI Engine!";
      await srcFile.writeAsString(content);

      final dstPath = p.join(tempDir.path, "sub", "copied_file.txt");

      // Copy via RPC
      final copyRes = await engine.executeRpc("operations/copyfile", {
        "srcFs": tempDir.path,
        "srcRemote": "test_file.txt",
        "dstFs": p.join(tempDir.path, "sub"),
        "dstRemote": "copied_file.txt",
      });
      expect(copyRes, isNotNull);

      // Verify copied file exists
      final dstFile = File(dstPath);
      expect(await dstFile.exists(), isTrue);
      expect(await dstFile.readAsString(), equals(content));

      // Hashsum via RPC
      final hashRes = await engine.executeRpc("operations/hashsum", {
        "htype": "sha256",
        "fs": p.join(tempDir.path, "sub"),
        "remote": "copied_file.txt",
      });

      final expectedHash = sha256.convert(utf8.encode(content)).toString();
      expect(hashRes["hash"], equals(expectedHash));

      tempDir.deleteSync(recursive: true);
    });

    test("executeRpcInWorker executes RPC in dedicated Dart Isolate", () async {
      final res = await engine.executeRpcInWorker("core/version", {});
      expect(res["version"], contains("v1.66.0"));
    });

    test("RPC error triggers RcloneBridgeException", () async {
      expect(
        () => engine.executeRpc("operations/non_existent_method", {}),
        throwsA(isA<RcloneBridgeException>()),
      );
    });
  });

  group("Milestone 4: QuickJS Embedded Sandbox & PipeContext", () {
    late QuickJsSandbox sandbox;

    setUp(() {
      sandbox = QuickJsSandbox();
    });

    test("Executes IIFE and correctly handles file filtering and date renaming", () async {
      final script = '''
        (() => {
          const finalQueue = [];
          for (const item of PipeContext.files) {
            if (item.name.endsWith(".tmp") || item.name.startsWith(".")) {
              PipeContext.utils.log("Skipping " + item.name);
              continue;
            }
            const dateStr = PipeContext.utils.formatDate(item.lastModifiedMs, "yyyy-MM-dd");
            finalQueue.push({
              sourcePath: item.path,
              targetRelativePath: dateStr + "/" + item.name
            });
          }
          return finalQueue;
        })();
      ''';

      final context = {
        "system": {"platform": "linux", "appVersion": "1.0.0"},
        "profile": {"id": "test_p", "name": "Test", "protocol": "smb", "remoteBasePath": "dest"},
        "files": [
          {
            "path": "/storage/voice_01.m4a",
            "name": "voice_01.m4a",
            "size": 2048,
            "lastModifiedMs": 1715000000000,
            "mimeType": "audio/mp4"
          },
          {
            "path": "/storage/temp.tmp",
            "name": "temp.tmp",
            "size": 512,
            "lastModifiedMs": 1715000000000,
            "mimeType": "application/octet-stream"
          },
          {
            "path": "/storage/.hidden",
            "name": ".hidden",
            "size": 128,
            "lastModifiedMs": 1715000000000,
            "mimeType": "application/octet-stream"
          }
        ]
      };

      final result = await sandbox.runPreHook(
        scriptSource: script,
        executionContext: context,
      );

      expect(result.isSuccess, isTrue);
      expect(result.transformedPlan.length, equals(1));
      expect(result.transformedPlan[0]["sourcePath"], equals("/storage/voice_01.m4a"));
      expect(result.transformedPlan[0]["targetRelativePath"], contains("voice_01.m4a"));
    });

    test("Syntax error in sandbox fails gracefully without crashing", () async {
      final result = await sandbox.runPreHook(
        scriptSource: "(() => { return nonExistentVar.foo(); })();",
        executionContext: {},
      );

      expect(result.isSuccess, isFalse);
      expect(result.executionError, isNotNull);
    });

    test("Infinite loop triggers timeout interrupt", () async {
      final result = await sandbox.runPreHook(
        scriptSource: "(() => { while (true) {} })();",
        executionContext: {},
        timeoutMs: 500,
      );

      expect(result.isSuccess, isFalse);
      expect(result.executionError, contains("timeout"));
    });
  });

  group("Milestone 2: Strong 2PC Verify & Purge Transaction Engine", () {
    late Directory tempSrc;
    late Directory tempDst;
    late String dbPath;
    late LibrcloneEngine rclone;
    late QuickJsSandbox sandbox;
    late PlatformAbstractionLayer pal;
    late PipelineOrchestrator orchestrator;

    setUp(() {
      tempSrc = Directory.systemTemp.createTempSync("pipesync_src_");
      tempDst = Directory.systemTemp.createTempSync("pipesync_dst_");
      dbPath = p.join(tempDst.path, "tasks.db");
      rclone = LibrcloneEngine();
      sandbox = QuickJsSandbox();
      pal = PlatformAbstractionLayer();
      orchestrator = PipelineOrchestrator(
        dbPath: dbPath,
        rcloneEngine: rclone,
        sandbox: sandbox,
        pal: pal,
      );
    });

    tearDown(() {
      rclone.shutdown();
      if (tempSrc.existsSync()) tempSrc.deleteSync(recursive: true);
      if (tempDst.existsSync()) tempDst.deleteSync(recursive: true);
    });

    test("Happy Path: Full 5-stage 2PC executes, verifies hashes, and purges safely", () async {
      final file1 = File(p.join(tempSrc.path, "audio1.m4a"));
      final file2 = File(p.join(tempSrc.path, "audio2.m4a"));
      final tmpFile = File(p.join(tempSrc.path, "discard.tmp"));

      await file1.writeAsString("Audio Recording Track 1");
      await file2.writeAsString("Audio Recording Track 2 with longer text data");
      await tmpFile.writeAsString("temporary file");

      final hookScript = '''
        (() => {
          const res = [];
          for (const f of PipeContext.files) {
            if (f.name.endsWith(".tmp")) continue;
            res.push({
              sourcePath: f.path,
              targetRelativePath: "archive/" + f.name
            });
          }
          return res;
        })();
      ''';

      final stagesRecorded = <TaskStage>[];
      orchestrator.stageStream.listen(stagesRecorded.add);

      final results = await orchestrator.executePipeline(
        profile: {
          "id": "test_profile",
          "name": "Audio Backup",
          "protocol": "smb",
          "remoteBasePath": tempDst.path,
        },
        sourceDir: tempSrc.path,
        hookScript: hookScript,
      );

      expect(results.length, equals(2));
      expect(results.every((r) => r["status"] == "COMMITTED"), isTrue);

      // Verify source files are purged
      expect(await file1.exists(), isFalse);
      expect(await file2.exists(), isFalse);
      // Temporary file should remain
      expect(await tmpFile.exists(), isTrue);

      // Destination files must exist with exact contents
      final dst1 = File(p.join(tempDst.path, "archive", "audio1.m4a"));
      final dst2 = File(p.join(tempDst.path, "archive", "audio2.m4a"));
      expect(await dst1.exists(), isTrue);
      expect(await dst2.exists(), isTrue);
      expect(await dst1.readAsString(), equals("Audio Recording Track 1"));

      // Verify SQLite records
      final tasks = orchestrator.listTasks();
      expect(tasks.length, equals(2));
      for (final t in tasks) {
        expect(t.stage, equals(TaskStage.committed));
        expect(t.localSha256, equals(t.remoteSha256));
      }
    });

    test("Integrity Mismatch Abort: Preserves local file and logs ISOLATED_ERROR", () async {
      final file = File(p.join(tempSrc.path, "sensitive_record.m4a"));
      await file.writeAsString("Critical Uncorrupted Data");

      // Mock engine that returns wrong hash for verification
      final mockEngine = MockTamperedRcloneEngine(rclone);
      final testOrchestrator = PipelineOrchestrator(
        dbPath: dbPath,
        rcloneEngine: mockEngine,
        sandbox: sandbox,
        pal: pal,
      );

      final hookScript = '''
        (() => {
          return PipeContext.files.map(f => ({ sourcePath: f.path, targetRelativePath: f.name }));
        })();
      ''';

      final results = await testOrchestrator.executePipeline(
        profile: {
          "id": "tamper_test",
          "name": "Tamper Test",
          "remoteBasePath": tempDst.path,
        },
        sourceDir: tempSrc.path,
        hookScript: hookScript,
      );

      expect(results.length, equals(1));
      expect(results[0]["status"], equals(TaskStage.isolatedError.value));

      // CRITICAL: Local file MUST NOT be deleted when hashes mismatch!
      expect(await file.exists(), isTrue);

      final tasks = testOrchestrator.listTasks();
      expect(tasks.length, equals(1));
      expect(tasks[0].stage, equals(TaskStage.isolatedError));
      expect(tasks[0].errorMessage, contains("mismatch"));
    });
  });

  group("Milestone 3 & 5: Platform Abstraction & Desktop Pull Mode", () {
    late PlatformAbstractionLayer pal;

    setUp(() {
      pal = PlatformAbstractionLayer();
    });

    tearDown(() async {
      await pal.stopLocalDesktopPullServer();
    });

    test("Storage permission and MediaStore clean logic", () async {
      expect(pal.checkStoragePermission(), isTrue);
      final res = await pal.cleanUpMediaStore("/storage/emulated/0/Recordings/sample.m4a");
      expect(res.contentResolverDeleted, isTrue);
      expect(res.mediaScannerDispatched, isTrue);
    });

    test("Desktop Pull HTTP Server serves local files to desktop clients", () async {
      final tempDir = Directory.systemTemp.createTempSync("pipesync_pull_");
      final testFile = File(p.join(tempDir.path, "shared_recording.m4a"));
      await testFile.writeAsString("Voice Recording Data for Desktop Pull");

      final port = await pal.startLocalDesktopPullServer(port: 0, rootDirectory: tempDir.path);
      expect(port, isPositive);

      final client = HttpClient();
      final req = await client.getUrl(Uri.parse("http://127.0.0.1:$port/shared_recording.m4a"));
      final resp = await req.close();
      expect(resp.statusCode, equals(HttpStatus.ok));

      final body = await resp.transform(utf8.decoder).join();
      expect(body, equals("Voice Recording Data for Desktop Pull"));

      client.close();
      tempDir.deleteSync(recursive: true);
    });
  });

  group("Plugin Hub & AI Copilot", () {
    test("PluginHub loads manifest and verifies integrity", () async {
      final pluginsDir = p.canonicalize(p.join(Directory.current.path, "..", "plugins"));
      final altDir = p.canonicalize(p.join(Directory.current.path, "plugins"));
      final dir = Directory(pluginsDir).existsSync() ? pluginsDir : altDir;

      final hub = PluginHub(pluginsDirectory: dir);
      final plugins = await hub.loadInstalledPlugins();

      expect(plugins.isNotEmpty, isTrue);
      final cleaner = plugins.firstWhere((p) => p.id == "org.pipesync.media-cleaner");
      expect(cleaner.enabled, isTrue);
      expect(cleaner.integrityVerified, isTrue);
      expect(cleaner.manifest.permissions, contains("READ_METADATA"));
    });

    test("AI Copilot generates valid IIFE rule template and validates in sandbox", () async {
      final template = AICopilotRuleGenerator.generateRuleTemplate(
        filterTmpFiles: true,
        filterHiddenFiles: true,
        dateFormatPattern: "yyyy-MM-dd",
        prefixFolder: "media",
      );

      expect(template, contains("PipeContext.files"));
      expect(template, contains("formatDate"));

      final sandbox = QuickJsSandbox();
      final isValid = await AICopilotRuleGenerator.validateGeneratedScript(
        sandbox: sandbox,
        scriptSource: template,
      );
      expect(isValid, isTrue);
    });
  });

  group("Syncthing Experience: Daemon, Watcher & Web Console API", () {
    late Directory tempDaemonDir;
    late String configPath;
    late String dbPath;
    late PipeSyncDaemon daemon;
    late PipeSyncWebServer webServer;
    late int serverPort;

    setUp(() async {
      tempDaemonDir = Directory.systemTemp.createTempSync("pipesync_daemon_test_");
      configPath = p.join(tempDaemonDir.path, "config.json");
      dbPath = p.join(tempDaemonDir.path, "pipesync_test.db");

      daemon = PipeSyncDaemon(
        configFilePath: configPath,
        dbPath: dbPath,
        rclone: LibrcloneEngine(),
        sandbox: QuickJsSandbox(),
      );

      webServer = PipeSyncWebServer(
        daemon: daemon,
        port: 0,
        host: "127.0.0.1",
      );

      serverPort = await webServer.start();
    });

    tearDown(() async {
      await webServer.stop();
      daemon.shutdown();
      if (tempDaemonDir.existsSync()) {
        tempDaemonDir.deleteSync(recursive: true);
      }
    });

    test("GET / returns high-fidelity Syncthing management console HTML", () async {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse("http://127.0.0.1:$serverPort/"));
      final resp = await req.close();
      expect(resp.statusCode, equals(HttpStatus.ok));
      expect(resp.headers.contentType?.mimeType, equals("text/html"));

      final body = await resp.transform(utf8.decoder).join();
      expect(body, contains("PipeSync - 数据管道管理控制台"));
      expect(body, contains("2PC Verification & Purge Audit Trail"));
      expect(body, contains("androidNoticeBanner"));
      expect(body, contains("PipeSyncNative"));
      expect(body, contains("androidQuickPaths"));
      expect(body, contains(daemon.nodeId));
      client.close();
    });

    test("REST API: system status, folder lifecycle, and 2PC rescan trigger", () async {
      final client = HttpClient();

      // 1. GET /api/v1/system/status
      final statusReq = await client.getUrl(Uri.parse("http://127.0.0.1:$serverPort/api/v1/system/status"));
      final statusResp = await statusReq.close();
      expect(statusResp.statusCode, equals(HttpStatus.ok));
      final statusJson = jsonDecode(await statusResp.transform(utf8.decoder).join());
      expect(statusJson["nodeId"], equals(daemon.nodeId));
      expect(statusJson["version"], equals("1.0.0"));

      // 2. GET /api/v1/folders (default folder should exist)
      final foldersReq = await client.getUrl(Uri.parse("http://127.0.0.1:$serverPort/api/v1/folders"));
      final foldersResp = await foldersReq.close();
      final foldersJson = jsonDecode(await foldersResp.transform(utf8.decoder).join()) as List;
      expect(foldersJson.isNotEmpty, isTrue);
      expect(foldersJson[0]["id"], isNotEmpty);

      // 3. POST /api/v1/folders (add new folder)
      final newSrc = p.join(tempDaemonDir.path, "custom_recordings");
      final newDst = p.join(tempDaemonDir.path, "nas_archive");
      Directory(newSrc).createSync();
      Directory(newDst).createSync();

      final addReq = await client.postUrl(Uri.parse("http://127.0.0.1:$serverPort/api/v1/folders"));
      addReq.headers.contentType = ContentType.json;
      addReq.write(jsonEncode({
        "label": "Voice Memos",
        "path": newSrc,
        "mode": "2pc_purge",
        "remoteTarget": newDst,
        "plugin": "org.pipesync.media-cleaner",
      }));
      final addResp = await addReq.close();
      expect(addResp.statusCode, equals(HttpStatus.ok));
      final addJson = jsonDecode(await addResp.transform(utf8.decoder).join());
      expect(addJson["success"], isTrue);
      final createdFolderId = addJson["id"];

      // 4. Create a test file and trigger rescan
      final testAudio = File(p.join(newSrc, "recording_sample.m4a"));
      await testAudio.writeAsString("Voice Memo 2026-09-12 Syncthing Experience");

      final rescanReq = await client.postUrl(Uri.parse("http://127.0.0.1:$serverPort/api/v1/folders/$createdFolderId/rescan"));
      final rescanResp = await rescanReq.close();
      expect(rescanResp.statusCode, equals(HttpStatus.ok));

      // Wait a moment for async sync to commit
      await Future.delayed(const Duration(milliseconds: 300));

      // Verify file was copied and purged from local source
      expect(await testAudio.exists(), isFalse);

      // 5. GET /api/v1/tasks reflects committed 2PC transaction
      final tasksReq = await client.getUrl(Uri.parse("http://127.0.0.1:$serverPort/api/v1/tasks"));
      final tasksResp = await tasksReq.close();
      final tasksJson = jsonDecode(await tasksResp.transform(utf8.decoder).join()) as List;
      expect(tasksJson.isNotEmpty, isTrue);

      // 6. Pause folder
      final pauseReq = await client.postUrl(Uri.parse("http://127.0.0.1:$serverPort/api/v1/folders/$createdFolderId/pause"));
      final pauseResp = await pauseReq.close();
      expect(pauseResp.statusCode, equals(HttpStatus.ok));

      // 7. Remove folder
      final deleteReq = await client.deleteUrl(Uri.parse("http://127.0.0.1:$serverPort/api/v1/folders/$createdFolderId"));
      final deleteResp = await deleteReq.close();
      expect(deleteResp.statusCode, equals(HttpStatus.ok));

      client.close();
    });

    test("REST API: AI Copilot script generation and test run", () async {
      final client = HttpClient();

      // Generate script
      final genReq = await client.postUrl(Uri.parse("http://127.0.0.1:$serverPort/api/v1/copilot/generate"));
      genReq.headers.contentType = ContentType.json;
      genReq.write(jsonEncode({"prompt": "Organize voice recordings"}));
      final genResp = await genReq.close();
      expect(genResp.statusCode, equals(HttpStatus.ok));
      final genJson = jsonDecode(await genResp.transform(utf8.decoder).join());
      expect(genJson["success"], isTrue);
      final script = genJson["script"] as String;

      // Test script in QuickJS sandbox
      final testReq = await client.postUrl(Uri.parse("http://127.0.0.1:$serverPort/api/v1/copilot/test"));
      testReq.headers.contentType = ContentType.json;
      testReq.write(jsonEncode({"script": script}));
      final testResp = await testReq.close();
      expect(testResp.statusCode, equals(HttpStatus.ok));
      final testJson = jsonDecode(await testResp.transform(utf8.decoder).join());
      expect(testJson["success"], isTrue);

      client.close();
    });
  });
}

class MockTamperedRcloneEngine implements IRcloneEngine {
  final IRcloneEngine realEngine;
  MockTamperedRcloneEngine(this.realEngine);

  @override
  Future<Map<String, dynamic>> executeRpc(String method, Map<String, dynamic> params) async {
    if (method == "operations/hashsum") {
      // Intentionally return fake tampered hash to simulate network bit rot or corrupted remote
      return {"hash": "0000000000000000000000000000000000000000000000000000000000000000"};
    }
    return realEngine.executeRpc(method, params);
  }

  @override
  Future<Map<String, dynamic>> executeRpcInWorker(String method, Map<String, dynamic> params) =>
      realEngine.executeRpcInWorker(method, params);

  @override
  void shutdown() => realEngine.shutdown();
}
