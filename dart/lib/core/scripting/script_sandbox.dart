// lib/core/scripting/script_sandbox.dart
import "dart:async";
import "dart:convert";
import "dart:ffi" as ffi;
import "dart:io";
import "package:ffi/ffi.dart";
import "package:path/path.dart" as p;

class ScriptExecutionResult {
  final bool isSuccess;
  final List<Map<String, String>> transformedPlan;
  final String? executionError;

  ScriptExecutionResult.success(this.transformedPlan)
      : isSuccess = true,
        executionError = null;

  ScriptExecutionResult.failure(this.executionError)
      : isSuccess = false,
        transformedPlan = const [];
}

abstract interface class IScriptSandbox {
  Future<ScriptExecutionResult> runPreHook({
    required String scriptSource,
    required Map<String, dynamic> executionContext,
    int timeoutMs = 5000,
  });
  void release();
}

// Native QuickJS FFI Binding Structures
final class QuickJSExecutionResultNative extends ffi.Struct {
  external ffi.Pointer<Utf8> outputJson;
  @ffi.Int()
  external int status;
}

typedef QuickJSRunPreHookC = QuickJSExecutionResultNative Function(
  ffi.Pointer<Utf8> scriptSource,
  ffi.Pointer<Utf8> executionContextJson,
  ffi.Int32 memoryLimitBytes,
  ffi.Int32 timeoutMs,
);
typedef QuickJSRunPreHookDart = QuickJSExecutionResultNative Function(
  ffi.Pointer<Utf8> scriptSource,
  ffi.Pointer<Utf8> executionContextJson,
  int memoryLimitBytes,
  int timeoutMs,
);

typedef QuickJSFreeResultC = ffi.Void Function(QuickJSExecutionResultNative result);
typedef QuickJSFreeResultDart = void Function(QuickJSExecutionResultNative result);

class QuickJsSandbox implements IScriptSandbox {
  static const int maxMemoryLimit = 16 * 1024 * 1024; // 16 MB

  static ffi.DynamicLibrary? nativeQjsLib;
  static QuickJSRunPreHookDart? _nativeRunPreHook;
  static QuickJSFreeResultDart? _nativeFreeResult;
  static bool _nativeLoadAttempted = false;

  static void _initNativeLibrary() {
    if (_nativeLoadAttempted) return;
    _nativeLoadAttempted = true;

    String libName;
    if (Platform.isWindows) {
      libName = "libpipesync_quickjs.dll";
    } else if (Platform.isMacOS) {
      libName = "libpipesync_quickjs.dylib";
    } else {
      libName = "libpipesync_quickjs.so";
    }

    final candidates = [
      p.join(Directory.current.path, "native", libName),
      p.join(Directory.current.path, "..", "native", libName),
      p.join(Directory.current.path, libName),
      p.join(Platform.script.toFilePath(), "..", "..", "native", libName),
    ];

    for (final cand in candidates) {
      if (File(cand).existsSync()) {
        try {
          final dylib = ffi.DynamicLibrary.open(p.canonicalize(cand));
          _nativeRunPreHook = dylib.lookupFunction<QuickJSRunPreHookC, QuickJSRunPreHookDart>("QuickJS_RunPreHookNative");
          _nativeFreeResult = dylib.lookupFunction<QuickJSFreeResultC, QuickJSFreeResultDart>("QuickJS_FreeNativeResult");
          nativeQjsLib = dylib;
          return;
        } catch (_) {}
      }
    }
  }

  @override
  Future<ScriptExecutionResult> runPreHook({
    required String scriptSource,
    required Map<String, dynamic> executionContext,
    int timeoutMs = 5000,
  }) async {
    _initNativeLibrary();

    // Preferred Native QuickJS FFI execution
    if (_nativeRunPreHook != null && _nativeFreeResult != null) {
      return _runPreHookNative(
        scriptSource: scriptSource,
        executionContext: executionContext,
        timeoutMs: timeoutMs,
      );
    }

    // Graceful fallback to Node-based execution runner
    return _runPreHookNodeFallback(
      scriptSource: scriptSource,
      executionContext: executionContext,
      timeoutMs: timeoutMs,
    );
  }

  Future<ScriptExecutionResult> _runPreHookNative({
    required String scriptSource,
    required Map<String, dynamic> executionContext,
    int timeoutMs = 5000,
  }) async {
    final scriptPtr = scriptSource.toNativeUtf8();
    final contextJson = jsonEncode(executionContext);
    final contextPtr = contextJson.toNativeUtf8();

    try {
      final nativeRes = _nativeRunPreHook!(scriptPtr, contextPtr, maxMemoryLimit, timeoutMs);
      final rawOut = nativeRes.outputJson.toDartString();
      final status = nativeRes.status;
      _nativeFreeResult!(nativeRes);

      if (rawOut.isEmpty) {
        return ScriptExecutionResult.failure("Empty response from native QuickJS runtime (code: $status)");
      }

      final dynamic parsed = jsonDecode(rawOut);
      if (parsed is Map<String, dynamic>) {
        if (parsed.containsKey("error")) {
          return ScriptExecutionResult.failure(parsed["error"].toString());
        }
        if (parsed.containsKey("plan") && parsed["plan"] is List) {
          final List<Map<String, String>> plan = [];
          for (final item in parsed["plan"]) {
            if (item is Map) {
              plan.add({
                "sourcePath": item["sourcePath"]?.toString() ?? "",
                "targetRelativePath": item["targetRelativePath"]?.toString() ?? "",
              });
            }
          }
          return ScriptExecutionResult.success(plan);
        }
      }

      return ScriptExecutionResult.failure("Invalid JSON structure from native QuickJS runtime");
    } catch (e) {
      return ScriptExecutionResult.failure("QuickJS Native Error: $e");
    } finally {
      calloc.free(scriptPtr);
      calloc.free(contextPtr);
    }
  }

  Future<ScriptExecutionResult> _runPreHookNodeFallback({
    required String scriptSource,
    required Map<String, dynamic> executionContext,
    int timeoutMs = 5000,
  }) async {
    final sanitizedContext = jsonEncode(executionContext);
    final jsRunnerCode = '''
const crypto = require('crypto');
const PipeContext = $sanitizedContext;
PipeContext.utils = {
  log: function(msg) { if (process.env.VERBOSE) console.error('[PipeContext.log]', msg); },
  warn: function(msg) { if (process.env.VERBOSE) console.error('[PipeContext.warn]', msg); },
  sha256: function(str) { return crypto.createHash('sha256').update(str).digest('hex'); },
  formatDate: function(ts, pattern) {
    const d = new Date(ts);
    const yyyy = d.getUTCFullYear();
    const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
    const dd = String(d.getUTCDate()).padStart(2, '0');
    if (pattern === 'yyyy-MM-dd') return yyyy + '-' + mm + '-' + dd;
    return d.toISOString();
  }
};
try {
  const result = eval(${jsonEncode(scriptSource)});
  if (!Array.isArray(result)) {
    process.stdout.write(JSON.stringify({ error: "Hook script must return an array" }));
    process.exit(0);
  }
  process.stdout.write(JSON.stringify({ success: true, plan: result }));
} catch (e) {
  process.stdout.write(JSON.stringify({ error: e.toString() }));
}
''';

    try {
      final memoryMb = (maxMemoryLimit / (1024 * 1024)).round();
      final process = await Process.start(
        "node",
        ["--max-old-space-size=$memoryMb", "-e", jsRunnerCode],
      );

      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();

      final exitCode = await process.exitCode.timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          throw TimeoutException("Execution timeout exceeded $timeoutMs ms");
        },
      );

      final stdoutText = await stdoutFuture;
      final stderrText = await stderrFuture;

      if (exitCode != 0 && stdoutText.trim().isEmpty) {
        return ScriptExecutionResult.failure("Process terminated with code $exitCode: ${stderrText.trim()}");
      }

      if (stdoutText.trim().isEmpty) {
        return ScriptExecutionResult.failure("Empty response from script runner");
      }

      final dynamic parsed = jsonDecode(stdoutText);
      if (parsed is Map<String, dynamic>) {
        if (parsed.containsKey("error")) {
          return ScriptExecutionResult.failure(parsed["error"].toString());
        }
        if (parsed.containsKey("plan") && parsed["plan"] is List) {
          final List<Map<String, String>> plan = [];
          for (final item in parsed["plan"]) {
            if (item is Map) {
              plan.add({
                "sourcePath": item["sourcePath"]?.toString() ?? "",
                "targetRelativePath": item["targetRelativePath"]?.toString() ?? "",
              });
            }
          }
          return ScriptExecutionResult.success(plan);
        }
      }

      return ScriptExecutionResult.failure("Invalid response format from script runner");
    } on TimeoutException catch (e) {
      return ScriptExecutionResult.failure(e.message ?? "Execution timeout");
    } catch (e) {
      return ScriptExecutionResult.failure(e.toString());
    }
  }

  @override
  void release() {}
}
