// lib/core/pipeline/pipeline_contract.dart
import "dart:async";

enum TaskStage {
  pending("PENDING"),
  preHook("PRE_HOOK"),
  transferring("TRANSFERRING"),
  verifying("VERIFYING"),
  purging("PURGING"),
  postHook("POST_HOOK"),
  committed("COMMITTED"),
  aborted("ABORTED"),
  retryBackoff("RETRY_BACKOFF"),
  isolatedError("ISOLATED_ERROR"),
  purgedStaleIndex("PURGED_STALE_INDEX");

  final String value;
  const TaskStage(this.value);

  static TaskStage fromString(String val) {
    for (final s in TaskStage.values) {
      if (s.value == val || s.name.toLowerCase() == val.toLowerCase()) {
        return s;
      }
    }
    return TaskStage.pending;
  }
}

class PipelineFileDescriptor {
  final String localPath;
  final String targetPath;
  final int fileSizeBytes;
  final String preCalculatedSha256;

  PipelineFileDescriptor({
    required this.localPath,
    required this.targetPath,
    required this.fileSizeBytes,
    required this.preCalculatedSha256,
  });
}

class PipelineTaskRecord {
  final String taskId;
  final String profileId;
  final String localPath;
  final String targetPath;
  final int fileSize;
  final String localSha256;
  final String? remoteSha256;
  final TaskStage stage;
  final int retryCount;
  final String? errorMessage;
  final String createdAt;
  final String updatedAt;

  PipelineTaskRecord({
    required this.taskId,
    required this.profileId,
    required this.localPath,
    required this.targetPath,
    required this.fileSize,
    required this.localSha256,
    this.remoteSha256,
    required this.stage,
    required this.retryCount,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    "taskId": taskId,
    "profileId": profileId,
    "localPath": localPath,
    "targetPath": targetPath,
    "fileSize": fileSize,
    "localSha256": localSha256,
    "remoteSha256": remoteSha256,
    "stage": stage.value,
    "retryCount": retryCount,
    "errorMessage": errorMessage,
    "createdAt": createdAt,
    "updatedAt": updatedAt,
  };
}

abstract interface class IPipelineOrchestrator {
  Stream<TaskStage> get stageStream;
  Future<List<Map<String, dynamic>>> executePipeline({
    required Map<String, dynamic> profile,
    required String sourceDir,
    required String hookScript,
    void Function(Map<String, dynamic>)? postHookFn,
  });
  Future<void> abortPipeline(String profileId);
}

abstract interface class ITransactionalVerificationManager {
  Future<bool> verifyFileIntegrity({
    required String localFilePath,
    required String remoteRemoteName,
    required String remoteRelativePath,
    required String expectedSha256,
  });

  Future<void> executeAtomicPurge({
    required String localFilePath,
  });
}
