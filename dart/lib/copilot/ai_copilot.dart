// lib/copilot/ai_copilot.dart
import "../core/scripting/script_sandbox.dart";

class AICopilotRuleGenerator {
  static const String systemPrompt = '''
You are PipeSync Copilot, an expert AI specialized in generating JavaScript preHook and postHook scripts for PipeSync.
PipeSync uses QuickJS sandbox environment with the following global context:

interface PipeContext {
  readonly system: {
    readonly platform: "android" | "ios" | "windows" | "linux" | "macos";
    readonly appVersion: string;
  };
  readonly profile: {
    readonly id: string;
    readonly name: string;
    readonly protocol: "smb" | "webdav" | "sftp";
    readonly remoteBasePath: string;
  };
  readonly files: ReadonlyArray<{
    readonly path: string;
    readonly name: string;
    readonly size: number;
    readonly lastModifiedMs: number;
    readonly mimeType: string;
  }>;
  readonly utils: {
    log(msg: string): void;
    warn(msg: string): void;
    sha256(content: string): string;
    formatDate(timestampMs: number, formatPattern: string): string;
  };
}

Rules:
1. The script MUST be written as an Immediately Invoked Function Expression (IIFE): (() => { ... return finalQueue; })();
2. The IIFE MUST return an array of objects matching: { sourcePath: string, targetRelativePath: string }.
3. Do NOT use Node.js or browser specific APIs (no require, window, document, process, fetch).
4. Use PipeContext.utils for hashing and date formatting.
5. Filter out unwanted files by omitting them from the final array.
''';

  /// Generates a starter template based on natural language description
  static String generateRuleTemplate({
    bool filterTmpFiles = true,
    bool filterHiddenFiles = true,
    String? dateFormatPattern = "yyyy-MM-dd",
    String? prefixFolder,
  }) {
    final dateSection = dateFormatPattern != null
        ? 'const formattedDate = PipeContext.utils.formatDate(item.lastModifiedMs, "$dateFormatPattern");\n    const targetName = `${prefixFolder != null ? "$prefixFolder/" : ""}\${formattedDate}/\${item.name}`;'
        : 'const targetName = `${prefixFolder != null ? "$prefixFolder/" : ""}\${item.name}`;';

    final filterConditions = <String>[];
    if (filterTmpFiles) {
      filterConditions.add('item.name.endsWith(".tmp") || item.name.endsWith(".crdownload")');
    }
    if (filterHiddenFiles) {
      filterConditions.add('item.name.startsWith(".")');
    }

    final filterBlock = filterConditions.isNotEmpty
        ? '''
    if (${filterConditions.join(" || ")}) {
      PipeContext.utils.log(`[Copilot] Discarding file: \${item.name}`);
      continue;
    }'''
        : '';

    return '''(() => {
  const finalQueue = [];
  for (const item of PipeContext.files) {$filterBlock
    $dateSection
    finalQueue.push({
      sourcePath: item.path,
      targetRelativePath: targetName
    });
  }
  return finalQueue;
})();''';
  }

  /// Validates generated script structure
  static Future<bool> validateGeneratedScript({
    required IScriptSandbox sandbox,
    required String scriptSource,
  }) async {
    final mockContext = {
      "system": {"platform": "windows", "appVersion": "1.0.0"},
      "profile": {"id": "test", "name": "Test Profile", "protocol": "smb", "remoteBasePath": "dest"},
      "files": [
        {
          "path": "/storage/sample.jpg",
          "name": "sample.jpg",
          "size": 1024,
          "lastModifiedMs": 1715000000000,
          "mimeType": "image/jpeg"
        }
      ]
    };

    final result = await sandbox.runPreHook(
      scriptSource: scriptSource,
      executionContext: mockContext,
      timeoutMs: 3000,
    );

    return result.isSuccess && result.transformedPlan.isNotEmpty;
  }
}
