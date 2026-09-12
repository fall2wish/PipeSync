// bin/pipesync.dart
import "dart:async";
import "dart:convert";
import "dart:io";
import "package:args/args.dart";
import "package:path/path.dart" as p;

import "../lib/core/ffi/librclone_bindings.dart";
import "../lib/core/pipeline/pipeline_orchestrator.dart";
import "../lib/core/scripting/script_sandbox.dart";
import "../lib/platform/platform_abstraction.dart";
import "../lib/plugins/plugin_hub.dart";
import "../lib/copilot/ai_copilot.dart";
import "../lib/daemon/sync_daemon.dart";
import "../lib/web/web_server.dart";

void main(List<String> arguments) async {
  final parser = ArgParser();
  parser.addFlag("help", abbr: "h", negatable: false, help: "Show usage information");

  // Version Command
  parser.addCommand("version");

  // Serve Command (Syncthing-like Web GUI & Daemon)
  final serveCommand = parser.addCommand("serve");
  serveCommand.addOption("port", abbr: "p", defaultsTo: "8384", help: "Web GUI port (default: 8384)");
  serveCommand.addOption("host", abbr: "h", defaultsTo: "127.0.0.1", help: "Host address to bind to");
  serveCommand.addOption("config", abbr: "c", help: "Path to configuration file");
  serveCommand.addOption("db", help: "Path to SQLite WAL database");
  serveCommand.addFlag("no-browser", defaultsTo: false, help: "Do not open browser automatically");

  // Run Command
  final runCommand = parser.addCommand("run");
  runCommand.addOption("source", abbr: "s", mandatory: true, help: "Local source directory");
  runCommand.addOption("dest", abbr: "d", mandatory: true, help: "Remote destination directory");
  runCommand.addOption("db", help: "Path to SQLite WAL database");
  runCommand.addOption("plugin", abbr: "p", help: "Path to plugin directory");

  // Status Command
  final statusCommand = parser.addCommand("status");
  statusCommand.addOption("db", help: "Path to SQLite WAL database");

  // Plugins Command
  final pluginsCommand = parser.addCommand("plugins");
  pluginsCommand.addOption("dir", help: "Plugins directory path");

  // Copilot Command
  final copilotCommand = parser.addCommand("copilot");
  copilotCommand.addOption("prompt", help: "Natural language description of rule");

  // Android Command
  parser.addCommand("android");

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    print("Argument error: $e\n");
    print(parser.usage);
    exit(1);
  }

  if (results["help"] == true || results.command == null || results.command!.name == "help") {
    print("PipeSync CLI - High Performance 2PC Verify & Purge Data Pipeline");
    print("Available commands: version, serve, run, status, plugins, copilot, android\n");
    print(parser.usage);
    return;
  }

  final commandName = results.command!.name;

  if (commandName == "version") {
    try {
      final engine = LibrcloneEngine();
      final ver = await engine.executeRpc("core/version", {});
      engine.shutdown();
      print("PipeSync Version: 1.0.0 (Dart 3.x / FFI / QuickJS Hybrid)");
      print("Librclone CGo/FFI: ${ver['version']} (${ver['os']}/${ver['arch']})");
    } catch (e) {
      print("Error loading librclone native library: $e");
    }
    return;
  }

  if (commandName == "serve") {
    final cmd = results.command!;
    final port = int.tryParse(cmd["port"].toString()) ?? 8384;
    final host = cmd["host"] as String? ?? "127.0.0.1";
    final homeDir = Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"] ?? Directory.systemTemp.path;
    final defaultCfg = p.join(homeDir, ".pipesync", "config.json");
    final defaultDb = p.join(homeDir, ".pipesync", "pipesync_wal.db");
    final configPath = cmd["config"] as String? ?? defaultCfg;
    final dbPath = cmd["db"] as String? ?? defaultDb;

    print("════════════════════════════════════════════════════════════════");
    print("        PipeSync Daemon & Syncthing-Style Web Console           ");
    print("════════════════════════════════════════════════════════════════");
    print("[*] Engine:    Librclone CGo/FFI + QuickJS Sandboxing");
    print("[*] Security:  2PC Verify & Purge (Zero Implicit Data Loss)");
    print("[*] Config:    $configPath");
    print("[*] Database:  $dbPath (SQLite WAL)");

    final daemon = PipeSyncDaemon(
      configFilePath: configPath,
      dbPath: dbPath,
      rclone: LibrcloneEngine(),
      sandbox: QuickJsSandbox(),
    );

    final webServer = PipeSyncWebServer(
      daemon: daemon,
      port: port,
      host: host,
    );

    final actualPort = await webServer.start();
    final url = "http://$host:$actualPort";

    if (actualPort != port) {
      print("[!] Notice:   Port $port was already in use (e.g. by Syncthing). Bound to $actualPort.");
    }
    print("[+] Node ID:   ${daemon.nodeId}");
    print("[+] Web GUI:   $url");
    print("[+] Status:    Watching ${daemon.folders.length} folder(s) | Connected to ${daemon.devices.length} device(s)");
    print("────────────────────────────────────────────────────────────────");
    print("Open $url in your web browser to manage folders, devices, and AI rules.");
    print("Press Ctrl+C to stop the daemon.\n");

    ProcessSignal.sigint.watch().listen((_) async {
      print("\n[*] Shutting down PipeSync daemon...");
      await webServer.stop();
      daemon.shutdown();
      exit(0);
    });

    await Completer().future;
    return;
  }

  if (commandName == "run") {
    final cmd = results.command!;
    final sourceDir = cmd["source"] as String;
    final destDir = cmd["dest"] as String;
    final tempDb = p.join(Directory.systemTemp.path, "pipesync_wal.db");
    final dbPath = cmd["db"] as String? ?? tempDb;

    final defaultPlugin = p.canonicalize(p.join(Directory.current.path, "..", "plugins", "installed", "org.pipesync.media-cleaner"));
    final altPlugin = p.canonicalize(p.join(Directory.current.path, "plugins", "installed", "org.pipesync.media-cleaner"));
    final pluginPath = cmd["plugin"] as String? ?? (Directory(defaultPlugin).existsSync() ? defaultPlugin : altPlugin);

    final hookFile = File(p.join(pluginPath, "hooks.js"));
    if (!hookFile.existsSync()) {
      print("Error: hook script not found at ${hookFile.path}");
      exit(1);
    }
    final hookScript = await hookFile.readAsString();

    Map<String, dynamic> manifest = {};
    final manifestFile = File(p.join(pluginPath, "manifest.json"));
    if (manifestFile.existsSync()) {
      manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    }

    final profile = {
      "id": manifest["id"] ?? "default_profile",
      "name": manifest["name"] ?? "Default Profile",
      "protocol": "smb",
      "remoteBasePath": destDir,
    };

    print("[*] Starting PipeSync 2PC Verify & Purge Pipeline (Dart 3.x)...");
    print("[*] Profile: ${profile['name']} (${profile['id']})");
    print("[*] Source:  $sourceDir");
    print("[*] Dest:    $destDir");
    print("[*] SQLite:  $dbPath");

    final rclone = LibrcloneEngine();
    final sandbox = QuickJsSandbox();
    final pal = PlatformAbstractionLayer();
    final orchestrator = PipelineOrchestrator(
      dbPath: dbPath,
      rcloneEngine: rclone,
      sandbox: sandbox,
      pal: pal,
    );

    orchestrator.stageStream.listen((stage) {
      print("    -> State: ${stage.value}");
    });

    final taskResults = await orchestrator.executePipeline(
      profile: profile,
      sourceDir: sourceDir,
      hookScript: hookScript,
    );

    rclone.shutdown();

    print("\n[+] Execution Finished. Results:");
    for (final r in taskResults) {
      print("    - Task: ${r['taskId'] ?? 'N/A'} | Status: ${r['status']} | Target: ${r['targetPath'] ?? 'N/A'}");
    }
    return;
  }

  if (commandName == "status") {
    final cmd = results.command!;
    final tempDb = p.join(Directory.systemTemp.path, "pipesync_wal.db");
    final dbPath = cmd["db"] as String? ?? tempDb;

    final dbFile = File(dbPath);
    if (!dbFile.existsSync()) {
      print("Database does not exist: $dbPath");
      return;
    }

    final orchestrator = PipelineOrchestrator(
      dbPath: dbPath,
      rcloneEngine: LibrcloneEngine(),
      sandbox: QuickJsSandbox(),
    );

    final tasks = orchestrator.listTasks();
    print("Tasks in DB (${tasks.length} total):");
    for (final t in tasks) {
      final remoteHashPreview = t.remoteSha256 != null && t.remoteSha256!.length >= 10
          ? "${t.remoteSha256!.substring(0, 10)}..."
          : (t.remoteSha256 ?? "null");
      final localHashPreview = t.localSha256.length >= 10
          ? "${t.localSha256.substring(0, 10)}..."
          : t.localSha256;
      print("[${t.stage.value}] ${t.taskId} | ${t.targetPath} | Local:$localHashPreview | Remote:$remoteHashPreview");
    }
    return;
  }

  if (commandName == "plugins") {
    final cmd = results.command!;
    final defaultDir = p.canonicalize(p.join(Directory.current.path, "..", "plugins"));
    final altDir = p.canonicalize(p.join(Directory.current.path, "plugins"));
    final pluginsDir = cmd["dir"] as String? ?? (Directory(defaultDir).existsSync() ? defaultDir : altDir);

    final hub = PluginHub(pluginsDirectory: pluginsDir);
    final installed = await hub.loadInstalledPlugins();

    print("Installed Plugins (${installed.length} found in $pluginsDir):");
    for (final p in installed) {
      final integrityLabel = p.integrityVerified ? "VERIFIED [OK]" : "TAMPERED/INVALID [FAIL]";
      print("- ${p.manifest.name} (${p.id}) v${p.manifest.version}");
      print("  Enabled: ${p.enabled} | Integrity: $integrityLabel");
      print("  Description: ${p.manifest.description}");
      print("  Permissions: ${p.manifest.permissions.join(', ')}");
    }
    return;
  }

  if (commandName == "copilot") {
    print("[*] PipeSync AI Copilot Rule Generator");
    final generated = AICopilotRuleGenerator.generateRuleTemplate(
      filterTmpFiles: true,
      filterHiddenFiles: true,
      dateFormatPattern: "yyyy-MM-dd",
      prefixFolder: "organized_photos",
    );
    print("\nGenerated IIFE PreHook Rule:\n");
    print(generated);

    final sandbox = QuickJsSandbox();
    final isValid = await AICopilotRuleGenerator.validateGeneratedScript(
      sandbox: sandbox,
      scriptSource: generated,
    );
    print("\nSandbox Syntax & Execution Validation: ${isValid ? 'PASSED [OK]' : 'FAILED [ERROR]'}");
    return;
  }

  if (commandName == "android") {
    final androidDir = p.canonicalize(p.join(Directory.current.path, "android"));
    final manifestFile = File(p.join(androidDir, "app", "src", "main", "AndroidManifest.xml"));
    final manifestExists = manifestFile.existsSync();
    print("════════════════════════════════════════════════════════════════");
    print("      PipeSync Android Native Host & Embedded WebKit Info       ");
    print("════════════════════════════════════════════════════════════════");
    print("[*] Project Path:    $androidDir");
    print("[*] Manifest:        ${manifestExists ? 'VALID [OK]' : 'MISSING'}");
    print("[*] Storage Engine:  MANAGE_EXTERNAL_STORAGE (Direct POSIX)");
    print("[*] Background Svc:  TransferForegroundService (dataSync 5.5h Relay)");
    print("[*] MediaStore Sync: MediaScanner Dirty Cache Auto-Flush");
    print("[*] WebKit Bridge:   PipeSyncNativeBridge (window.PipeSyncNative)");
    print("[*] Native Libs:     librclone.so & libpipesync_quickjs.so (arm64-v8a, x86_64)");
    print("\nTo build Android APK with Embedded WebKit:");
    print("  cd android && ./gradlew assembleRelease");
    print("  (or open the 'android' folder in Android Studio)");
    return;
  }
}
