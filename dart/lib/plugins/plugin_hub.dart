// lib/plugins/plugin_hub.dart
import "dart:convert";
import "dart:io";
import "package:crypto/crypto.dart";
import "package:path/path.dart" as p;

class PluginManifest {
  final String id;
  final String name;
  final String version;
  final String minAppVersion;
  final String description;
  final Map<String, dynamic> author;
  final List<String> permissions;
  final String hookScriptRelativePath;
  final String? wasmModuleRelativePath;
  final String expectedHookScriptSha256;
  final String? expectedWasmSha256;

  PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.minAppVersion,
    required this.description,
    required this.author,
    required this.permissions,
    required this.hookScriptRelativePath,
    this.wasmModuleRelativePath,
    required this.expectedHookScriptSha256,
    this.expectedWasmSha256,
  });

  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    final entrypoints = json["entrypoints"] as Map<String, dynamic>? ?? {};
    final integrity = json["integrity"] as Map<String, dynamic>? ?? {};

    return PluginManifest(
      id: json["id"]?.toString() ?? "",
      name: json["name"]?.toString() ?? "",
      version: json["version"]?.toString() ?? "",
      minAppVersion: json["minAppVersion"]?.toString() ?? "",
      description: json["description"]?.toString() ?? "",
      author: (json["author"] as Map<String, dynamic>?) ?? {},
      permissions: (json["permissions"] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      hookScriptRelativePath: entrypoints["hookScript"]?.toString() ?? "hooks.js",
      wasmModuleRelativePath: entrypoints["wasmModule"]?.toString(),
      expectedHookScriptSha256: integrity["hookScriptSha256"]?.toString() ?? "",
      expectedWasmSha256: integrity["wasmModuleSha256"]?.toString(),
    );
  }
}

class InstalledPlugin {
  final String id;
  final bool enabled;
  final String installedPath;
  final PluginManifest manifest;
  final String hookScriptContent;
  final bool integrityVerified;

  InstalledPlugin({
    required this.id,
    required this.enabled,
    required this.installedPath,
    required this.manifest,
    required this.hookScriptContent,
    required this.integrityVerified,
  });
}

class PluginHub {
  final String pluginsDirectory;

  PluginHub({required this.pluginsDirectory});

  Future<String> _computeFileSha256(String filePath) async {
    final file = File(filePath);
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<List<InstalledPlugin>> loadInstalledPlugins() async {
    final registryFile = File(p.join(pluginsDirectory, "registry.json"));
    if (!registryFile.existsSync()) {
      return [];
    }

    final rawRegistry = jsonDecode(await registryFile.readAsString()) as Map<String, dynamic>;
    final pluginEntries = (rawRegistry["plugins"] as List<dynamic>?) ?? [];
    final List<InstalledPlugin> result = [];

    for (final entry in pluginEntries) {
      if (entry is! Map<String, dynamic>) continue;
      final id = entry["id"]?.toString() ?? "";
      final enabled = entry["enabled"] as bool? ?? false;
      final relPath = entry["installedPath"]?.toString() ?? "";
      final pluginDir = p.join(pluginsDirectory, relPath);

      final manifestFile = File(p.join(pluginDir, "manifest.json"));
      if (!manifestFile.existsSync()) continue;

      final manifestJson = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final manifest = PluginManifest.fromJson(manifestJson);

      final hookFile = File(p.join(pluginDir, manifest.hookScriptRelativePath));
      if (!hookFile.existsSync()) continue;

      final hookContent = await hookFile.readAsString();
      final actualSha256 = await _computeFileSha256(hookFile.path);

      // Verify integrity
      final integrityVerified = actualSha256.toLowerCase() == manifest.expectedHookScriptSha256.toLowerCase();

      result.add(InstalledPlugin(
        id: id,
        enabled: enabled,
        installedPath: pluginDir,
        manifest: manifest,
        hookScriptContent: hookContent,
        integrityVerified: integrityVerified,
      ));
    }

    return result;
  }
}
