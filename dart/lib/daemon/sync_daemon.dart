// lib/daemon/sync_daemon.dart
import "dart:async";
import "dart:convert";
import "dart:io";
import "package:path/path.dart" as p;

import "../core/ffi/librclone_bindings.dart";
import "../core/pipeline/pipeline_orchestrator.dart";
import "../core/scripting/script_sandbox.dart";
import "../platform/platform_abstraction.dart";
import "../plugins/plugin_hub.dart";

class SyncedFolderConfig {
  final String id;
  String label;
  String path;
  String mode; // "2pc_purge", "send_only", "desktop_pull"
  String remoteTarget;
  String plugin;
  bool isPaused;
  bool autoWatch;
  int scanIntervalSec;

  SyncedFolderConfig({
    required this.id,
    required this.label,
    required this.path,
    this.mode = "2pc_purge",
    required this.remoteTarget,
    this.plugin = "org.pipesync.media-cleaner",
    this.isPaused = false,
    this.autoWatch = true,
    this.scanIntervalSec = 60,
  });

  Map<String, dynamic> toJson() => {
    "id": id,
    "label": label,
    "path": path,
    "mode": mode,
    "remoteTarget": remoteTarget,
    "plugin": plugin,
    "isPaused": isPaused,
    "autoWatch": autoWatch,
    "scanIntervalSec": scanIntervalSec,
  };

  factory SyncedFolderConfig.fromJson(Map<String, dynamic> j) => SyncedFolderConfig(
    id: j["id"]?.toString() ?? "folder_${DateTime.now().millisecondsSinceEpoch}",
    label: j["label"]?.toString() ?? "Synced Folder",
    path: j["path"]?.toString() ?? "",
    mode: j["mode"]?.toString() ?? "2pc_purge",
    remoteTarget: j["remoteTarget"]?.toString() ?? "",
    plugin: j["plugin"]?.toString() ?? "org.pipesync.media-cleaner",
    isPaused: j["isPaused"] as bool? ?? false,
    autoWatch: j["autoWatch"] as bool? ?? true,
    scanIntervalSec: j["scanIntervalSec"] as int? ?? 60,
  );
}

class RemoteDeviceConfig {
  final String id;
  String name;
  String protocol; // "smb", "webdav", "sftp", "desktop_pull"
  String address;
  bool isLocal;
  bool connected;
  String lastSeen;

  RemoteDeviceConfig({
    required this.id,
    required this.name,
    required this.protocol,
    required this.address,
    this.isLocal = false,
    this.connected = true,
    this.lastSeen = "刚刚",
  });

  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "protocol": protocol,
    "address": address,
    "isLocal": isLocal,
    "connected": connected,
    "lastSeen": lastSeen,
  };

  factory RemoteDeviceConfig.fromJson(Map<String, dynamic> j) => RemoteDeviceConfig(
    id: j["id"]?.toString() ?? "dev_${DateTime.now().millisecondsSinceEpoch}",
    name: j["name"]?.toString() ?? "Remote Device",
    protocol: j["protocol"]?.toString() ?? "smb",
    address: j["address"]?.toString() ?? "",
    isLocal: j["isLocal"] as bool? ?? false,
    connected: j["connected"] as bool? ?? true,
    lastSeen: j["lastSeen"]?.toString() ?? "刚刚",
  );
}

class PipeSyncDaemon {
  final String configFilePath;
  final String dbPath;
  final IRcloneEngine rclone;
  final IScriptSandbox sandbox;
  final PlatformAbstractionLayer pal;
  late final PipelineOrchestrator orchestrator;
  late final PluginHub pluginHub;

  final String nodeId;
  final List<SyncedFolderConfig> folders = [];
  final List<RemoteDeviceConfig> devices = [];
  final Map<String, StreamSubscription> _watchers = {};
  final Map<String, bool> _folderSyncing = {};

  int totalBytesSynced = 0;
  int totalPurgedCount = 0;
  bool isSyncing = false;

  PipeSyncDaemon({
    required this.configFilePath,
    required this.dbPath,
    required this.rclone,
    required this.sandbox,
    PlatformAbstractionLayer? pal,
    String? pluginsDir,
  })  : pal = pal ?? PlatformAbstractionLayer(),
        nodeId = "PIPESYNC-${Platform.localHostname.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '')}-A9F2" {
    orchestrator = PipelineOrchestrator(
      dbPath: dbPath,
      rcloneEngine: rclone,
      sandbox: sandbox,
      pal: this.pal,
    );

    final pDir = pluginsDir ?? p.canonicalize(p.join(Directory.current.path, "plugins"));
    pluginHub = PluginHub(pluginsDirectory: Directory(pDir).existsSync() ? pDir : p.join(Directory.current.path, "..", "plugins"));

    _loadConfig();
    _startWatchers();
  }

  void _loadConfig() {
    final file = File(configFilePath);
    if (!file.existsSync()) {
      // Create sensible default configuration
      final defaultSrc = p.canonicalize(p.join(Directory.systemTemp.path, "pipesync_default_folder"));
      final defaultDst = p.canonicalize(p.join(Directory.systemTemp.path, "pipesync_default_remote"));
      Directory(defaultSrc).createSync(recursive: true);
      Directory(defaultDst).createSync(recursive: true);

      folders.add(SyncedFolderConfig(
        id: "default_folder",
        label: "默认归档目录 (Default Folder)",
        path: defaultSrc,
        mode: "2pc_purge",
        remoteTarget: defaultDst,
        plugin: "org.pipesync.media-cleaner",
      ));

      devices.add(RemoteDeviceConfig(
        id: "local_this",
        name: Platform.localHostname,
        protocol: "local",
        address: "127.0.0.1:8384",
        isLocal: true,
        connected: true,
      ));

      devices.add(RemoteDeviceConfig(
        id: "default_nas",
        name: "局域网存储 (Windows NAS)",
        protocol: "smb",
        address: defaultDst,
        isLocal: false,
        connected: true,
      ));

      _saveConfig();
      return;
    }

    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final fList = (json["folders"] as List<dynamic>?) ?? [];
      for (final f in fList) {
        if (f is Map<String, dynamic>) folders.add(SyncedFolderConfig.fromJson(f));
      }
      final dList = (json["devices"] as List<dynamic>?) ?? [];
      for (final d in dList) {
        if (d is Map<String, dynamic>) devices.add(RemoteDeviceConfig.fromJson(d));
      }
    } catch (_) {}

    // Ensure local device entry exists
    if (!devices.any((d) => d.isLocal)) {
      devices.insert(0, RemoteDeviceConfig(
        id: "local_this",
        name: Platform.localHostname,
        protocol: "local",
        address: "127.0.0.1:8384",
        isLocal: true,
        connected: true,
      ));
    }
  }

  void _saveConfig() {
    final parent = Directory(p.dirname(p.canonicalize(configFilePath)));
    if (!parent.existsSync()) parent.createSync(recursive: true);

    final data = {
      "nodeId": nodeId,
      "folders": folders.map((f) => f.toJson()).toList(),
      "devices": devices.map((d) => d.toJson()).toList(),
    };
    File(configFilePath).writeAsStringSync(jsonEncode(data));
  }

  void _startWatchers() {
    for (final folder in folders) {
      if (folder.isPaused || !folder.autoWatch) continue;
      _watchFolder(folder);
    }
  }

  void _watchFolder(SyncedFolderConfig folder) {
    final dir = Directory(folder.path);
    if (!dir.existsSync()) return;

    _watchers[folder.id]?.cancel();
    _watchers[folder.id] = dir.watch(events: FileSystemEvent.create | FileSystemEvent.modify).listen((event) {
      if (_folderSyncing[folder.id] == true) return;
      // Debounce: trigger after slight quiet period
      Timer(const Duration(seconds: 2), () {
        syncFolder(folder.id);
      });
    });
  }

  Future<List<Map<String, dynamic>>> syncFolder(String folderId) async {
    final folder = folders.firstWhere((f) => f.id == folderId, orElse: () => throw Exception("Folder not found"));
    if (folder.isPaused) return [];
    if (_folderSyncing[folder.id] == true) return [];

    _folderSyncing[folder.id] = true;
    isSyncing = true;

    try {
      final installed = await pluginHub.loadInstalledPlugins();
      String hookScript = '''
        (() => {
          return PipeContext.files.map(f => ({ sourcePath: f.path, targetRelativePath: f.name }));
        })();
      ''';

      if (folder.plugin != "none") {
        final matched = installed.where((p) => p.id == folder.plugin);
        if (matched.isNotEmpty && matched.first.integrityVerified) {
          hookScript = matched.first.hookScriptContent;
        }
      }

      final profile = {
        "id": folder.id,
        "name": folder.label,
        "protocol": "smb",
        "remoteBasePath": folder.remoteTarget,
      };

      final results = await orchestrator.executePipeline(
        profile: profile,
        sourceDir: folder.path,
        hookScript: hookScript,
      );

      for (final r in results) {
        if (r["status"] == "COMMITTED") {
          totalPurgedCount++;
        }
      }

      return results;
    } finally {
      _folderSyncing[folder.id] = false;
      isSyncing = _folderSyncing.values.any((v) => v);
    }
  }

  void addFolder(SyncedFolderConfig config) {
    folders.add(config);
    _saveConfig();
    if (!config.isPaused && config.autoWatch) {
      _watchFolder(config);
    }
  }

  void removeFolder(String folderId) {
    _watchers[folderId]?.cancel();
    _watchers.remove(folderId);
    folders.removeWhere((f) => f.id == folderId);
    _saveConfig();
  }

  void togglePause(String folderId) {
    final folder = folders.firstWhere((f) => f.id == folderId);
    folder.isPaused = !folder.isPaused;
    if (folder.isPaused) {
      _watchers[folderId]?.cancel();
      _watchers.remove(folderId);
    } else if (folder.autoWatch) {
      _watchFolder(folder);
    }
    _saveConfig();
  }

  void addDevice(RemoteDeviceConfig config) {
    devices.add(config);
    _saveConfig();
  }

  void shutdown() {
    for (final w in _watchers.values) {
      w.cancel();
    }
    _watchers.clear();
    rclone.shutdown();
  }
}
