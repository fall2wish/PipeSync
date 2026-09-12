import "dart:async";
import "dart:ffi" as ffi;
import "dart:io";
import "package:crypto/crypto.dart";
import "package:path/path.dart" as p;
import "package:sqlite3/open.dart";
import "package:sqlite3/sqlite3.dart";

import "../ffi/librclone_bindings.dart";
import "../scripting/script_sandbox.dart";
import "../../platform/platform_abstraction.dart";
import "pipeline_contract.dart";

class PipelineOrchestrator implements IPipelineOrchestrator, ITransactionalVerificationManager {
  final String dbPath;
  final IRcloneEngine rcloneEngine;
  final IScriptSandbox sandbox;
  final PlatformAbstractionLayer pal;
  final StreamController<TaskStage> _stageController = StreamController<TaskStage>.broadcast();

  static bool _sqliteConfigured = false;
  static void ensureSqliteLoaded() {
    if (_sqliteConfigured) return;
    _sqliteConfigured = true;
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        final candidates = [
          "native/libsqlite3.so",
          "../native/libsqlite3.so",
          "/lib/x86_64-linux-gnu/libsqlite3.so.0",
          "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0",
          "/lib/aarch64-linux-gnu/libsqlite3.so.0",
          "/usr/lib/aarch64-linux-gnu/libsqlite3.so.0",
          "libsqlite3.so.0",
          "libsqlite3.so",
        ];
        for (final c in candidates) {
          try {
            return ffi.DynamicLibrary.open(c);
          } catch (_) {}
        }
        return ffi.DynamicLibrary.process();
      });
    }
  }

  PipelineOrchestrator({
    required this.dbPath,
    required this.rcloneEngine,
    required this.sandbox,
    PlatformAbstractionLayer? pal,
  }) : pal = pal ?? PlatformAbstractionLayer() {
    ensureSqliteLoaded();
    _initDatabase();
  }

  @override
  Stream<TaskStage> get stageStream => _stageController.stream;

  Database _openDb() {
    final parentDir = Directory(p.dirname(p.canonicalize(dbPath)));
    if (!parentDir.existsSync()) {
      parentDir.createSync(recursive: true);
    }
    final db = sqlite3.open(dbPath);
    db.execute("PRAGMA journal_mode = WAL;");
    return db;
  }

  void _initDatabase() {
    final db = _openDb();
    try {
      db.execute('''
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
      ''');
    } finally {
      db.dispose();
    }
  }

  void _updateTaskStage(
    String taskId,
    TaskStage stage, {
    String? remoteSha256,
    String? errorMessage,
    int? retryCount,
  }) {
    final db = _openDb();
    try {
      final stmt = db.prepare('''
        UPDATE pipeline_tasks
        SET stage = ?,
            remote_sha256 = COALESCE(?, remote_sha256),
            error_message = ?,
            retry_count = COALESCE(?, retry_count),
            updated_at = CURRENT_TIMESTAMP
        WHERE task_id = ?
      ''');
      stmt.execute([stage.value, remoteSha256, errorMessage, retryCount, taskId]);
      stmt.dispose();
      _stageController.add(stage);
    } finally {
      db.dispose();
    }
  }

  Future<String> computeSha256(String filePath) async {
    final file = File(filePath);
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString();
  }

  List<Map<String, dynamic>> scanDirectory(String sourceDir) {
    final List<Map<String, dynamic>> results = [];
    final dir = Directory(sourceDir);
    if (!dir.existsSync()) {
      return results;
    }

    final entities = dir.listSync(recursive: true, followLinks: false);
    for (final entity in entities) {
      if (entity is File) {
        final stat = entity.statSync();
        final name = p.basename(entity.path);
        final mime = name.toLowerCase().endsWith(".jpg") || name.toLowerCase().endsWith(".jpeg")
            ? "image/jpeg"
            : "application/octet-stream";

        results.add({
          "path": entity.path,
          "name": name,
          "size": stat.size,
          "lastModifiedMs": stat.modified.millisecondsSinceEpoch,
          "mimeType": mime,
        });
      }
    }
    return results;
  }

  @override
  Future<List<Map<String, dynamic>>> executePipeline({
    required Map<String, dynamic> profile,
    required String sourceDir,
    required String hookScript,
    void Function(Map<String, dynamic>)? postHookFn,
  }) async {
    final profileId = profile["id"]?.toString() ?? "default_profile";
    final remoteBase = profile["remoteBasePath"]?.toString() ?? "backup";

    // -------------------------------------------------------------
    // 阶段一：前置扫描与 Hook 拦截（Pre-Execution）
    // -------------------------------------------------------------
    final scannedFiles = scanDirectory(sourceDir);
    final pipeContext = {
      "system": {
        "platform": pal.platform,
        "appVersion": "1.0.0",
      },
      "profile": {
        "id": profileId,
        "name": profile["name"]?.toString() ?? "SyncProfile",
        "protocol": profile["protocol"]?.toString() ?? "smb",
        "remoteBasePath": remoteBase,
      },
      "files": scannedFiles,
    };

    final sandboxResult = await sandbox.runPreHook(
      scriptSource: hookScript,
      executionContext: pipeContext,
    );

    if (!sandboxResult.isSuccess) {
      return [
        {"status": TaskStage.aborted.value, "error": sandboxResult.executionError}
      ];
    }

    final List<Map<String, dynamic>> taskDescriptors = [];
    final db = _openDb();
    try {
      final insertStmt = db.prepare('''
        INSERT INTO pipeline_tasks
        (task_id, profile_id, local_path, target_path, file_size, local_sha256, stage)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      ''');

      for (final item in sandboxResult.transformedPlan) {
        final localPath = item["sourcePath"] ?? "";
        final targetRel = item["targetRelativePath"] ?? "";
        final file = File(localPath);
        if (!file.existsSync()) continue;

        final size = file.lengthSync();
        final localHash = await computeSha256(localPath);
        final taskId = "task_${DateTime.now().millisecondsSinceEpoch}_${taskDescriptors.length}";

        insertStmt.execute([
          taskId,
          profileId,
          localPath,
          targetRel,
          size,
          localHash,
          TaskStage.pending.value,
        ]);

        taskDescriptors.add({
          "taskId": taskId,
          "localPath": localPath,
          "targetRel": targetRel,
          "fileSize": size,
          "localSha256": localHash,
        });
      }
      insertStmt.dispose();
    } finally {
      db.dispose();
    }

    final List<Map<String, dynamic>> results = [];

    // Process tasks sequentially according to 2PC transaction machine
    for (final task in taskDescriptors) {
      final taskId = task["taskId"].toString();
      final localPath = task["localPath"].toString();
      final targetRel = task["targetRel"].toString();
      final localSize = task["fileSize"] as int;
      final localHash = task["localSha256"].toString();

      // -------------------------------------------------------------
      // 阶段二：受控并发传输与进度捕获（Transferring）
      // -------------------------------------------------------------
      _updateTaskStage(taskId, TaskStage.transferring);

      final targetFullPath = p.join(remoteBase, targetRel);
      final transferParams = {
        "srcFs": p.dirname(p.canonicalize(localPath)),
        "srcRemote": p.basename(localPath),
        "dstFs": p.dirname(p.canonicalize(targetFullPath)),
        "dstRemote": p.basename(targetFullPath),
      };

      const maxRetries = 3;
      bool transferSuccess = false;
      String lastErr = "";

      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          await rcloneEngine.executeRpc("operations/copyfile", transferParams);
          transferSuccess = true;
          break;
        } catch (e) {
          lastErr = e.toString();
          if (attempt < maxRetries) {
            await Future.delayed(Duration(milliseconds: 50 * (1 << (attempt - 1))));
          }
        }
      }

      if (!transferSuccess) {
        _updateTaskStage(taskId, TaskStage.retryBackoff, errorMessage: lastErr, retryCount: maxRetries);
        results.add({
          "taskId": taskId,
          "status": TaskStage.retryBackoff.value,
          "error": lastErr,
        });
        continue;
      }

      // -------------------------------------------------------------
      // 阶段三：双向哈希对齐强校验（Verifying）
      // -------------------------------------------------------------
      _updateTaskStage(taskId, TaskStage.verifying);

      final hashParams = {
        "htype": "sha256",
        "fs": p.dirname(p.canonicalize(targetFullPath)),
        "remote": p.basename(targetFullPath),
      };
      final statParams = {
        "fs": p.dirname(p.canonicalize(targetFullPath)),
        "remote": p.basename(targetFullPath),
      };

      String remoteHash = "";
      int remoteSize = -1;

      try {
        final hashRes = await rcloneEngine.executeRpc("operations/hashsum", hashParams);
        final statRes = await rcloneEngine.executeRpc("operations/stat", statParams);
        remoteHash = hashRes["hash"]?.toString() ?? "";
        final itemMap = statRes["item"];
        if (itemMap is Map && itemMap.containsKey("size")) {
          remoteSize = int.tryParse(itemMap["size"].toString()) ?? -1;
        }
      } catch (e) {
        final errMsg = "Verification fetch error: $e";
        _updateTaskStage(taskId, TaskStage.isolatedError, errorMessage: errMsg);
        results.add({
          "taskId": taskId,
          "status": TaskStage.isolatedError.value,
          "error": errMsg,
        });
        continue;
      }

      // Check 2PC condition: VerifyPass = (Hash_local == Hash_remote) && (Size_local == Size_remote)
      final verifyPass = (localHash == remoteHash) && (localSize == remoteSize);

      if (!verifyPass) {
        final errMsg = "Hash/Size mismatch! Local($localSize b, $localHash) vs Remote($remoteSize b, $remoteHash)";
        _updateTaskStage(taskId, TaskStage.isolatedError, remoteSha256: remoteHash, errorMessage: errMsg);
        results.add({
          "taskId": taskId,
          "status": TaskStage.isolatedError.value,
          "error": errMsg,
        });
        continue;
      }

      // -------------------------------------------------------------
      // 阶段四：安全物理清除与媒体库重对齐（Purging）
      // -------------------------------------------------------------
      _updateTaskStage(taskId, TaskStage.purging, remoteSha256: remoteHash);

      // Atomic unlink
      await pal.atomicUnlink(localPath);

      // MediaStore resync to eliminate ghost thumbnails
      await pal.cleanUpMediaStore(localPath);

      // -------------------------------------------------------------
      // 阶段五：后置业务扩展与事务提交（Post-Execution & Committed）
      // -------------------------------------------------------------
      _updateTaskStage(taskId, TaskStage.postHook);
      if (postHookFn != null) {
        try {
          postHookFn({
            "taskId": taskId,
            "localPath": localPath,
            "targetPath": targetFullPath,
            "sha256": localHash,
            "size": localSize,
          });
        } catch (_) {}
      }

      _updateTaskStage(taskId, TaskStage.committed);
      results.add({
        "taskId": taskId,
        "status": TaskStage.committed.value,
        "targetPath": targetFullPath,
        "sha256": localHash,
      });
    }

    return results;
  }

  @override
  Future<bool> verifyFileIntegrity({
    required String localFilePath,
    required String remoteRemoteName,
    required String remoteRelativePath,
    required String expectedSha256,
  }) async {
    final hashRes = await rcloneEngine.executeRpc("operations/hashsum", {
      "htype": "sha256",
      "fs": remoteRemoteName,
      "remote": remoteRelativePath,
    });
    return hashRes["hash"] == expectedSha256;
  }

  @override
  Future<void> executeAtomicPurge({required String localFilePath}) async {
    await pal.atomicUnlink(localFilePath);
    await pal.cleanUpMediaStore(localFilePath);
  }

  @override
  Future<void> abortPipeline(String profileId) async {
    final db = _openDb();
    try {
      db.execute('''
        UPDATE pipeline_tasks
        SET stage = 'ABORTED', updated_at = CURRENT_TIMESTAMP
        WHERE profile_id = ? AND stage IN ('PENDING', 'PRE_HOOK', 'TRANSFERRING', 'VERIFYING')
      ''', [profileId]);
    } finally {
      db.dispose();
    }
  }

  PipelineTaskRecord? getTaskStatus(String taskId) {
    final db = _openDb();
    try {
      final stmt = db.prepare("SELECT * FROM pipeline_tasks WHERE task_id = ?");
      final rows = stmt.select([taskId]);
      if (rows.isEmpty) {
        stmt.dispose();
        return null;
      }
      final r = rows.first;
      final record = PipelineTaskRecord(
        taskId: r["task_id"].toString(),
        profileId: r["profile_id"].toString(),
        localPath: r["local_path"].toString(),
        targetPath: r["target_path"].toString(),
        fileSize: r["file_size"] as int,
        localSha256: r["local_sha256"].toString(),
        remoteSha256: r["remote_sha256"]?.toString(),
        stage: TaskStage.fromString(r["stage"].toString()),
        retryCount: r["retry_count"] as int,
        errorMessage: r["error_message"]?.toString(),
        createdAt: r["created_at"].toString(),
        updatedAt: r["updated_at"].toString(),
      );
      stmt.dispose();
      return record;
    } finally {
      db.dispose();
    }
  }

  List<PipelineTaskRecord> listTasks() {
    final db = _openDb();
    try {
      final rows = db.select("SELECT * FROM pipeline_tasks ORDER BY updated_at DESC");
      return rows.map((r) => PipelineTaskRecord(
        taskId: r["task_id"].toString(),
        profileId: r["profile_id"].toString(),
        localPath: r["local_path"].toString(),
        targetPath: r["target_path"].toString(),
        fileSize: r["file_size"] as int,
        localSha256: r["local_sha256"].toString(),
        remoteSha256: r["remote_sha256"]?.toString(),
        stage: TaskStage.fromString(r["stage"].toString()),
        retryCount: r["retry_count"] as int,
        errorMessage: r["error_message"]?.toString(),
        createdAt: r["created_at"].toString(),
        updatedAt: r["updated_at"].toString(),
      )).toList();
    } finally {
      db.dispose();
    }
  }

  void close() {
    _stageController.close();
  }
}
