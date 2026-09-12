// lib/core/ffi/librclone_bindings.dart
import "dart:convert";
import "dart:ffi" as ffi;
import "dart:io";
import "dart:isolate";
import "package:ffi/ffi.dart";
import "package:path/path.dart" as p;

final class RcloneRPCResultNative extends ffi.Struct {
  external ffi.Pointer<Utf8> output;
  @ffi.Int()
  external int status;
}

typedef RcloneInitializeC = ffi.Void Function();
typedef RcloneInitializeDart = void Function();

typedef RcloneFinalizeC = ffi.Void Function();
typedef RcloneFinalizeDart = void Function();

typedef RcloneRPCC = RcloneRPCResultNative Function(
  ffi.Pointer<Utf8> method,
  ffi.Pointer<Utf8> input,
);
typedef RcloneRPCDart = RcloneRPCResultNative Function(
  ffi.Pointer<Utf8> method,
  ffi.Pointer<Utf8> input,
);

typedef RcloneFreeStringC = ffi.Void Function(ffi.Pointer<Utf8> str);
typedef RcloneFreeStringDart = void Function(ffi.Pointer<Utf8> str);

abstract interface class IRcloneEngine {
  Future<Map<String, dynamic>> executeRpc(String method, Map<String, dynamic> params);
  Future<Map<String, dynamic>> executeRpcInWorker(String method, Map<String, dynamic> params);
  void shutdown();
}

class LibrcloneEngine implements IRcloneEngine {
  late final String libPath;
  late final ffi.DynamicLibrary _library;
  late final RcloneInitializeDart _initialize;
  late final RcloneFinalizeDart _finalize;
  late final RcloneRPCDart _rpc;
  late final RcloneFreeStringDart _freeString;

  static String resolveDefaultLibraryPath() {
    String libName;
    if (Platform.isWindows) {
      libName = "librclone.dll";
    } else if (Platform.isMacOS) {
      libName = "librclone.dylib";
    } else {
      libName = "librclone.so";
    }

    final candidates = [
      p.join(Directory.current.path, "native", libName),
      p.join(Directory.current.path, "..", "native", libName),
      p.join(Directory.current.path, libName),
    ];

    for (final cand in candidates) {
      if (File(cand).existsSync()) {
        return p.canonicalize(cand);
      }
    }
    // Fallback to relative native directory
    return p.join("native", libName);
  }

  LibrcloneEngine([String? dynamicLibPath]) {
    libPath = dynamicLibPath ?? resolveDefaultLibraryPath();
    _library = ffi.DynamicLibrary.open(libPath);
    _initialize = _library.lookupFunction<RcloneInitializeC, RcloneInitializeDart>("RcloneInitialize");
    _finalize = _library.lookupFunction<RcloneFinalizeC, RcloneFinalizeDart>("RcloneFinalize");
    _rpc = _library.lookupFunction<RcloneRPCC, RcloneRPCDart>("RcloneRPC");
    _freeString = _library.lookupFunction<RcloneFreeStringC, RcloneFreeStringDart>("RcloneFreeString");
    _initialize();
  }

  @override
  Future<Map<String, dynamic>> executeRpc(String method, Map<String, dynamic> params) async {
    final methodPtr = method.toNativeUtf8();
    final paramsJson = jsonEncode(params);
    final inputPtr = paramsJson.toNativeUtf8();

    try {
      final nativeResult = _rpc(methodPtr, inputPtr);
      final rawResponse = nativeResult.output.toDartString();
      final statusCode = nativeResult.status;

      _freeString(nativeResult.output);

      if (statusCode != 200) {
        throw RcloneBridgeException(statusCode, rawResponse);
      }

      return jsonDecode(rawResponse) as Map<String, dynamic>;
    } finally {
      calloc.free(methodPtr);
      calloc.free(inputPtr);
    }
  }

  @override
  Future<Map<String, dynamic>> executeRpcInWorker(String method, Map<String, dynamic> params) async {
    final currentLibPath = libPath;
    return await Isolate.run(() async {
      final workerEngine = LibrcloneEngine(currentLibPath);
      try {
        return await workerEngine.executeRpc(method, params);
      } finally {
        workerEngine.shutdown();
      }
    });
  }

  @override
  void shutdown() {
    _finalize();
  }
}

class RcloneBridgeException implements Exception {
  final int statusCode;
  final String details;
  RcloneBridgeException(this.statusCode, this.details);

  @override
  String toString() => "RcloneBridgeException(code: $statusCode, details: $details)";
}
