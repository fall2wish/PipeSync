// lib/web/web_server.dart
import "dart:async";
import "dart:convert";
import "dart:io";

import "../copilot/ai_copilot.dart";
import "../daemon/sync_daemon.dart";
import "syncthing_gui.dart";

class PipeSyncWebServer {
  final PipeSyncDaemon daemon;
  final int port;
  final String host;
  HttpServer? _server;
  final DateTime _startTime = DateTime.now();

  PipeSyncWebServer({
    required this.daemon,
    this.port = 8384,
    this.host = "0.0.0.0",
  });

  Future<int> start() async {
    HttpServer? server;
    int targetPort = port;
    for (int i = 0; i < 20; i++) {
      try {
        server = await HttpServer.bind(host, targetPort);
        break;
      } catch (e) {
        if (e is SocketException && (e.osError?.errorCode == 98 || e.osError?.errorCode == 10048)) {
          targetPort++;
          continue;
        }
        rethrow;
      }
    }
    if (server == null) {
      throw SocketException("Failed to bind to $host on ports $port..$targetPort");
    }
    _server = server;

    server.listen((HttpRequest req) async {
      // CORS headers for flexibility
      req.response.headers.add("Access-Control-Allow-Origin", "*");
      req.response.headers.add("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
      req.response.headers.add("Access-Control-Allow-Headers", "Content-Type");

      if (req.method == "OPTIONS") {
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
        return;
      }

      try {
        await _handleRequest(req);
      } catch (e) {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({"error": e.toString()}));
        await req.response.close();
      }
    });

    return server.port;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final path = req.uri.path;

    // Web GUI Main Dashboard
    if (path == "/" || path == "/index.html") {
      req.response.headers.contentType = ContentType.html;
      req.response.write(renderSyncthingHtml(
        nodeId: daemon.nodeId,
        platform: daemon.pal.platform,
      ));
      await req.response.close();
      return;
    }

    // System Status
    if (path == "/api/v1/system/status" && req.method == "GET") {
      final uptimeDur = DateTime.now().difference(_startTime);
      final uptimeStr = "${uptimeDur.inHours}h ${uptimeDur.inMinutes % 60}m ${uptimeDur.inSeconds % 60}s";

      final statusData = {
        "nodeId": daemon.nodeId,
        "platform": daemon.pal.platform,
        "version": "1.0.0",
        "uptime": uptimeStr,
        "isSyncing": daemon.isSyncing,
        "purgedCount": daemon.totalPurgedCount,
        "bandwidth": daemon.isSyncing ? "1.2 MB/s / 1.2 MB/s" : "0 B/s / 0 B/s",
      };
      _sendJson(req, statusData);
      return;
    }

    // Folders API
    if (path == "/api/v1/folders" && req.method == "GET") {
      final list = daemon.folders.map((f) {
        final dir = Directory(f.path);
        int count = 0;
        int size = 0;
        if (dir.existsSync()) {
          for (final e in dir.listSync(recursive: true, followLinks: false)) {
            if (e is File) {
              count++;
              size += e.lengthSync();
            }
          }
        }
        final sizeFmt = size > 1048576
            ? "${(size / 1048576).toStringAsFixed(1)} MB"
            : (size > 1024 ? "${(size / 1024).toStringAsFixed(1)} KB" : "$size B");

        return {
          "id": f.id,
          "label": f.label,
          "path": f.path,
          "mode": f.mode,
          "remoteTarget": f.remoteTarget,
          "plugin": f.plugin,
          "isPaused": f.isPaused,
          "autoWatch": f.autoWatch,
          "fileCount": count,
          "totalSizeFormatted": sizeFmt,
          "isSyncing": daemon.isSyncing,
          "progress": daemon.isSyncing ? 65 : 100,
        };
      }).toList();
      _sendJson(req, list);
      return;
    }

    if (path == "/api/v1/folders" && req.method == "POST") {
      final body = await _readJsonBody(req);
      final id = "folder_${DateTime.now().millisecondsSinceEpoch}";
      final newFolder = SyncedFolderConfig(
        id: id,
        label: body["label"]?.toString() ?? "New Folder",
        path: body["path"]?.toString() ?? "",
        mode: body["mode"]?.toString() ?? "2pc_purge",
        remoteTarget: body["remoteTarget"]?.toString() ?? "",
        plugin: body["plugin"]?.toString() ?? "org.pipesync.media-cleaner",
      );
      daemon.addFolder(newFolder);
      _sendJson(req, {"success": true, "id": id});
      return;
    }

    if (path.startsWith("/api/v1/folders/") && req.method == "DELETE") {
      final folderId = path.substring("/api/v1/folders/".length);
      daemon.removeFolder(folderId);
      _sendJson(req, {"success": true});
      return;
    }

    if (path.startsWith("/api/v1/folders/") && path.endsWith("/rescan") && req.method == "POST") {
      final parts = path.split("/");
      final folderId = parts[4];
      // Run sync asynchronously
      unawaited(daemon.syncFolder(folderId));
      _sendJson(req, {"success": true, "status": "SYNC_STARTED"});
      return;
    }

    if (path.startsWith("/api/v1/folders/") && path.endsWith("/pause") && req.method == "POST") {
      final parts = path.split("/");
      final folderId = parts[4];
      daemon.togglePause(folderId);
      _sendJson(req, {"success": true});
      return;
    }

    // Devices API
    if (path == "/api/v1/devices" && req.method == "GET") {
      _sendJson(req, daemon.devices.map((d) => d.toJson()).toList());
      return;
    }

    if (path == "/api/v1/devices" && req.method == "POST") {
      final body = await _readJsonBody(req);
      final newDev = RemoteDeviceConfig(
        id: "dev_${DateTime.now().millisecondsSinceEpoch}",
        name: body["name"]?.toString() ?? "New Device",
        protocol: body["protocol"]?.toString() ?? "smb",
        address: body["address"]?.toString() ?? "",
      );
      daemon.addDevice(newDev);
      _sendJson(req, {"success": true, "id": newDev.id});
      return;
    }

    // Tasks API
    if (path == "/api/v1/tasks" && req.method == "GET") {
      final tasks = daemon.orchestrator.listTasks();
      _sendJson(req, tasks.map((t) => t.toMap()).toList());
      return;
    }

    // Copilot API
    if (path == "/api/v1/copilot/generate" && req.method == "POST") {
      final script = AICopilotRuleGenerator.generateRuleTemplate(
        filterTmpFiles: true,
        filterHiddenFiles: true,
        dateFormatPattern: "yyyy-MM",
        prefixFolder: "recordings",
      );
      _sendJson(req, {"success": true, "script": script});
      return;
    }

    if (path == "/api/v1/copilot/test" && req.method == "POST") {
      final body = await _readJsonBody(req);
      final script = body["script"]?.toString() ?? "";
      final isValid = await AICopilotRuleGenerator.validateGeneratedScript(
        sandbox: daemon.sandbox,
        scriptSource: script,
      );
      _sendJson(req, {"success": isValid});
      return;
    }

    // Plugins API
    if (path == "/api/v1/plugins" && req.method == "GET") {
      final installed = await daemon.pluginHub.loadInstalledPlugins();
      _sendJson(req, installed.map((p) => {
        "id": p.id,
        "name": p.manifest.name,
        "version": p.manifest.version,
        "enabled": p.enabled,
        "integrityVerified": p.integrityVerified,
      }).toList());
      return;
    }

    // 404
    req.response.statusCode = HttpStatus.notFound;
    _sendJson(req, {"error": "Not found: $path"});
  }

  void _sendJson(HttpRequest req, dynamic data) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    req.response.close();
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest req) async {
    final text = await utf8.decodeStream(req);
    if (text.trim().isEmpty) return {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
