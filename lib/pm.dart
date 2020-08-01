import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Directory, File, Platform, Process, ProcessStartMode, sleep, stdout;
import 'dart:io' as io;
import 'dart:isolate';

import 'package:colorize/colorize.dart';
import 'package:pm3/isolate_process_handler.dart';
import 'package:pm3/log_rotate.dart';
import 'package:pm3/pm_socket.dart';

import 'package:dart_console/dart_console.dart';
import 'package:pm3/util/logging.dart';
import 'package:socket_io/socket_io.dart';

import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:timeago/timeago.dart' as timeago;

class PM3Process {
  Isolate isolate;
  SendPort childSendPort;
  SendPort mainSendPort;
  IsolateProcessHandler handler;
  PM3Process(this.isolate, this.handler, this.childSendPort, this.mainSendPort);
}

class PM3 {
  Map<String, String> env;
  String rootConfig;
  File configFile;
  File pidFile;
  String configPath;
  Directory currentDir;
  Directory configFolder;
  final console = Console();
  int pid;

  List<Map<String, dynamic>> processors = [];
  Map<String, PM3Process> comm = {};
  String pmHost = '127.0.0.1';
  int pmPort = 30100;

  PM3(this.env) {
    // String os = Platform.operatingSystem;
    Map<String, String> envVars = Platform.environment;
    if (Platform.isMacOS) {
      rootConfig = envVars['HOME'];
    } else if (Platform.isLinux) {
      rootConfig = envVars['HOME'];
    } else if (Platform.isWindows) {
      rootConfig = envVars['UserProfile'];
    }
    configFolder = Directory(rootConfig + '/.pm3');
    if (!configFolder.existsSync()) {
      print('creating $configFolder');
      configFolder.createSync(recursive: true);
    }
    configFile = File(configFolder.path + '/dump.pm3');
    currentDir = Directory.current;

    pidFile = File(configFolder.path + '/pm3.pid');
  }

  init() async {}

  mustStateUp() async {
    if (!await checkState()) {
      if (Platform.isMacOS || Platform.isLinux) {
        throw 'PM3 not running, please start it by `nohup pm3 start &`';
      } else if (Platform.isWindows) {
        throw 'PM3 not running, please start it by `pm3 start`';
      }
    }
  }

  logRotate(rotater) async {
    int maxSize = 1024 * 1024 * 500;
    for (var c = 0; c < processors.length; c++) {
      final proc = processors[c];
      final name = proc['name'];
      final p = comm[name];
      if (p == null) {
        continue; //not initialise yet
      }
      if (p.handler.logStd.existsSync()) {
        final fileSize = p.handler.logStd.lengthSync();
        var truncateSize = (maxSize / 2 / (1024 * 1024)).floor();
        // print('logRotate $name size: $fileSize (max $maxSize)');
        if (fileSize > maxSize) {
          print(
              'truncating ${p.handler.logStd.path} cutting off ${truncateSize}M');
          await rotater(p.handler.logStd.path, '${truncateSize}M');
        }
      }

      if (p.handler.logErr.existsSync()) {
        final fileSize = p.handler.logErr.lengthSync();
        var truncateSize = (maxSize / 2 / (1024 * 1024)).floor();
        // print('logRotate $name size: $fileSize (max $maxSize)');
        if (fileSize > maxSize) {
          print(
              'truncating ${p.handler.logStd.path} cutting off ${truncateSize}M');
          await rotater(p.handler.logErr.path, '${truncateSize}M');
        }
      }
    }
  }

  // check if pm3 is alive
  Future<bool> checkState() async {
    if (!pidFile.existsSync()) {
      return false;
    }
    final pidContent = pidFile.readAsStringSync();
    if (pidContent.isEmpty) {
      return false;
    }
    pid = int.parse(pidContent);

    if (Platform.isMacOS || Platform.isLinux) {
      final res = Process.runSync('kill', ['-0', '$pid']);
      // print('check process ${res.exitCode}');
      if (res.exitCode == 0) {
        return true; //running
      }
    } else if (Platform.isWindows) {
      throw 'TODO';
    }
    return false;
  }

  doResurrect(String app) async {
    await mustStateUp();
    print('doResurrect $app');

    final hostURL = 'http://$pmHost:$pmPort';
    // print('connecting to $hostURL');
    IO.Socket socket = IO.io(hostURL, <String, dynamic>{
      'transports': ['websocket'],
    });
    socket.on('connect', (_) {
      // print('connect to pm3');
      socket.emit('resurrect', {'app': app});
    });
    socket.on('resurrectResult', (data) async {
      socket.emit('msg', 'list');
    });
    socket.on('resurrectError', (data) async {
      print('resurrectError: $data');
      socket.disconnect();
    });
    socketHandleList(socket);
  }

  doBoot(List<String> args) async {
    final state = await checkState();
    if (state) {
      print('doBoot skipping, already running...');
      return;
    }
    try {
      await Process.start('pm3', ['start'],
              environment: env, mode: ProcessStartMode.detached)
          .then((Process proc) async {
        print("Boot: pm3 booted");
        await sleep(Duration(seconds: 2));
        Process.runSync('pm3', ['resurrect']);
        // proc.stderr.transform(utf8.decoder).listen((data) {
        //   print('Boot: error: $data');
        // });
        // proc.exitCode.then((exitCode) {
        //   print('Boot: exit: $exitCode');
        // });
      });
    } catch (err) {
      print("Boot: error: $err");
      rethrow;
    }
  }

  doStart(String app, List<String> args) async {
    final state = await checkState();
    print('doStart $app | $args');
    if (!state) {
      if (app.isNotEmpty) {
        console
            .writeLine('PM3 not running, please start it by nohup pm3 start &');
        return;
      }

      pid = io.pid;
      pidFile.writeAsStringSync('$pid');
      // Isolate.spawn(startLogRotate, this);
      startLogRotate(this);
      await startSocketServer(this);
      return;
    } else {
      final hostURL = 'http://$pmHost:$pmPort';
      // print('connecting to $hostURL');
      IO.Socket socket = IO.io(hostURL, <String, dynamic>{
        'transports': ['websocket'],
      });
      socket.on('connect', (_) {
        // print('connect to pm3');
        socket.emit('startApp', {'app': app, 'args': args});
      });
      socket.on('startResult', (data) async {
        socket.emit('msg', 'list');
      });
      socket.on('startError', (data) async {
        print('startError: $data');
        socket.disconnect();
      });
      socketHandleList(socket);
    }
    // console.setBackgroundColor(ConsoleColor.cyan);
  }

  serverDoStartApp(Map<String, dynamic> appConfig) async {
    print('serverDoStartApp conf: ${appConfig}');
    String app = appConfig['app'];
    // List<String> args = appConfig['args'].map((arg) {
    //   String data = arg;
    //   return data;
    // }).toList();
    Map<String, dynamic> listenConf;
    var foundProcess = false;
    for (var c = 0; c < processors.length; c++) {
      if (processors[c]['name'] == app || app == 'all') {
        listenConf = processors[c];
        PM3Process p = comm[listenConf['name']];
        foundProcess = true;

        if (listenConf['ended'] == null || listenConf['ended'] == true) {
          listenConf['ended'] = false;
          p.childSendPort.send('start');
        } else {
          print('app $app is running, ignored');
        }

        if (app != 'all') break;
      }
    }
    if (!foundProcess) {
      throw 'Process missing $app';
    }
  }

  Future<PM3Process> serverDoStart(Map<String, dynamic> appConfig) async {
    print('starting app conf: ${appConfig.keys}');
    Completer completer = new Completer<PM3Process>();
    ReceivePort mainStreamReceiver = ReceivePort();
    Isolate processIsolate;
    String app = appConfig['name'];
    if (app == 'all') {
      throw 'App name "all" is reserved';
    }
    // print('initialise iph $appConfig');
    IsolateProcessHandler handler =
        IsolateProcessHandler(mainStreamReceiver.sendPort, appConfig);

    var existsConf = getProcessConfig(app);
    // print('appconf? $existsConf');
    if (existsConf.containsKey('name') && comm[app] != null) {
      final p = comm[app];
      if (existsConf.containsKey('ended') && existsConf['ended'] == true) {
        print('process $app sending start');
        p.childSendPort.send('start');
      } else {
        print('process $app is not ended, ignored');
      }

      completer.complete(p);
      return p;
    }
    // print('setting mainstreamreceiver');
    mainStreamReceiver.listen((data) async {
      final now = DateTime.now();
      PM3Process p = comm[app];
      // print('mainReceived $data');
      var doSaveAppState = false;
      var listenConf = data is SendPort ? appConfig : getProcessConfig(app);

      int delayRestartMs = listenConf.containsKey('exp_backoff_restart_delay')
          ? int.parse(listenConf['exp_backoff_restart_delay'])
          : 500;

      bool autoRestart = listenConf.containsKey('autorestart')
          ? listenConf['autorestart']
          : true;

      if (data is SendPort) {
        print('isolate spawn with child sendport');
        p = PM3Process(
            processIsolate, handler, data, mainStreamReceiver.sendPort);
        comm[app] = p;
        var foundProcess = false;
        for (var c = 0; c < processors.length; c++) {
          if (processors[c]['name'] == app) {
            processors[c] = listenConf;
            foundProcess = true;
            break;
          }
        }
        if (!foundProcess) {
          processors.add(listenConf);
        }
        await data.send('start');
        completer.complete(p);
      } else if (data is String) {
        print('mainReceived: $app: $data');

        if (data.startsWith('exit:')) {
          int code = int.parse(data.replaceFirst('exit:', ''));
          print(
              'app:$app exit: $code, ended? ${listenConf["ended"]} autoRestart: $autoRestart');
          listenConf['update_time'] = now.toIso8601String();
          listenConf['status'] = 'stopped';
          if (p != null) {
            p.childSendPort.send('config:' + json.encode(listenConf));
            await saveAppState(listenConf);
          }

          if (listenConf['ended'] != true && autoRestart && p != null) {
            print('app:$app restarting in $delayRestartMs ms.');
            Timer(Duration(milliseconds: delayRestartMs), () {
              listenConf = getProcessConfig(app);
              print('app:$app ended? ${listenConf['ended']}');
              if (listenConf['ended'] != true && autoRestart) {
                p.childSendPort.send('start');
              }
            });
          }
        } else if (data.startsWith('started')) {
          print('started $app...');
          var pidStr = data.replaceFirst('started:', '');
          int iPid = int.parse(pidStr);
          // print('restart_time ${listenConf["restart_time"]}');
          int restartCount = listenConf.containsKey('restart_time')
              ? listenConf['restart_time']
              : 0;
          listenConf['pm_uptime'] = now.millisecondsSinceEpoch;
          listenConf['restart_time'] = restartCount + 1;
          listenConf['status'] = 'online';
          listenConf['pid'] = iPid;
          listenConf['ended'] = false;
          print('started $app uptime: ${listenConf["pm_uptime"]}');
          // listenConf['pm_pid_path'] = 'online';
          doSaveAppState = true;
        } else if (data.startsWith('ended')) {
          listenConf['status'] = 'stopped';
          listenConf['ended'] = true; //todo check pm3
          doSaveAppState = true;
        } else if (data.startsWith('deleted')) {
          listenConf['status'] = 'deleted';
          for (var c = 0; c < processors.length; c++) {
            if (processors[c]['name'] == app) {
              processors.removeAt(c);
              comm[app] = null;

              p.childSendPort.send('deleteResult');
              break;
            }
          }
        } else if (data.startsWith('log:')) {
          // print("mainSendPort received log:");
          if (p != null) {
            await p.handler.logClientHandlers.forEach((LogRequester logClient) {
              logClient.clientHandler
                  .emit('log', data.replaceFirst('log:', ''));
            });
            // print("mainSendPort done emit log to clients");
          }
        } else if (data.startsWith('logErr:')) {
          if (p != null) {
            await p.handler.logClientHandlers.forEach((LogRequester logClient) {
              logClient.clientHandler
                  .emit('logErr', data.replaceFirst('logErr:', ''));
            });
          }
        }
      }

      if (doSaveAppState) {
        if (p != null) {
          // print('p is null! savingAppState of $data');
          listenConf['update_time'] = now.toIso8601String();
          p.childSendPort.send('config:' + json.encode(listenConf));
          // save to .pm3/dump.pm3
          await saveAppState(listenConf);
        }
        // print('savingAppState saved of $data');
      }
    });

    print('starting child isolate');
    processIsolate = await Isolate.spawn(startProcess, handler);

    return completer.future;
  }

  Map<String, dynamic> getProcessConfig(String app) {
    for (var c = 0; c < processors.length; c++) {
      if (processors[c]['name'] == app) {
        return processors[c];
      }
    }
    return <String, dynamic>{};
  }

  serverDoDelete(String app) async {
    print('serverDoDelete app:${app}');
    if (!comm.containsKey(app) && app != 'all') {
      throw 'App missing $app';
    }
    int processIndex = -1;
    for (var c = 0; c < processors.length; c++) {
      if (processors[c]['name'] == app || app == 'all') {
        processIndex = c;

        processors[processIndex]['status'] = 'stopped';
        processors[processIndex]['ended'] = true;

        comm[processors[processIndex]['name']].childSendPort.send('delete');
        // await comm[processors[processIndex]['name']].handler
        //   ..delete();

        if (app != 'all') break;
      }
    }
  }

  serverClientDisconnect(Socket handler) async {
    for (var key in comm.keys) {
      final p = comm[key];
      if (p == null) {
        continue;
      }
      for (var h in p.handler.logClientHandlers) {
        if (h == handler) {
          p.handler.logClientHandlers.remove(h);
        }
      }
    }
  }

  //logType: std / error
  serverDoLog(String app, Socket handler, {logType: 'std'}) async {
    print('serverDoLog app:${app}');
    if (!comm.containsKey(app)) {
      throw 'App missing $app';
    }
    print('serverDoLog app: $app sending socket');
    comm[app].handler.logClientHandlers.add(LogRequester(handler));
    if (logType == 'error') {
      await comm[app].childSendPort.send('log:error');
    } else {
      await comm[app].childSendPort.send('log');
    }
  }

  serverDoStop(String app) async {
    print('serverDoStop app:${app}');
    if (!comm.containsKey(app) && app != 'all') {
      throw 'App missing $app';
    }
    int processIndex = -1;
    for (var c = 0; c < processors.length; c++) {
      if (processors[c]['name'] == app || app == 'all') {
        processIndex = c;

        processors[processIndex]['status'] = 'stopped';
        processors[processIndex]['ended'] = true;

        await comm[processors[processIndex]['name']].childSendPort.send('stop');

        if (app != 'all') break;
      }
    }
  }

  serverDoResurrect() async {
    //stop all exists process
    for (var c = 0; c < processors.length; c++) {
      final proc = processors[c];
      await serverDoStop(proc['name']);
    }
    await loadState();
    // print('loadedstate $processors');
    for (var c = 0; c < processors.length; c++) {
      final proc = processors[c];
      await serverDoStart(proc);
    }
  }

  serverDoSave() async {
    print('serverDoSave');
    await saveState();
  }

  serverDoLoad() async {
    print('serverDoLoad');
    await loadState();
  }

  serverDoRestart(String app) async {
    print('serverDoRestart app:${app}');
    if (!comm.containsKey(app) && app != 'all') {
      throw 'App missing $app';
    }
    int processIndex = -1;
    for (var c = 0; c < processors.length; c++) {
      if (processors[c]['name'] == app || app == 'all') {
        processIndex = c;
        processors[processIndex]['status'] = 'stopped';
        processors[processIndex]['ended'] = false;
        await comm[processors[processIndex]['name']]
            .childSendPort
            .send('restart');

        if (app != 'all') break;
      }
    }
  }

  Future doDelete(String app) async {
    await mustStateUp();

    final hostURL = 'http://$pmHost:$pmPort';
    // print('connecting to $hostURL');
    IO.Socket socket = IO.io(hostURL, <String, dynamic>{
      'transports': ['websocket'],
      // 'extraHeaders': {'foo': 'bar'}
    });
    socket.on('connect', (_) {
      socket.emit('delete', app);
    });
    socket.on('deleteResult', (data) async {
      // print('deleteResult from server: $data');
      socket.emit('msg', 'list');
    });
    socket.on('deleteError', (data) async {
      print('deleteError: $data');
      socket.disconnect();
    });
    socketHandleList(socket);
  }

  Future doLog(String app, List<String> args) async {
    await mustStateUp();

    final hostURL = 'http://$pmHost:$pmPort';
    // print('connecting to $hostURL');
    IO.Socket socket = IO.io(hostURL, <String, dynamic>{
      'transports': ['websocket'],
      // 'extraHeaders': {'foo': 'bar'}
    });
    socket.on('connect', (_) {
      socket.emit('log', [app, args]);
    });
    socket.on('log', (data) async {
      stdout.write(data);
      // print(data);
    });
    socket.on('logErr', (data) async {
      Colorize cStr = Colorize(data)..red();
      stdout.write(cStr);
      // print(cStr);
    });
    socket.on('logError', (data) async {
      print('error: $data');
      socket.disconnect();
    });
  }

  Future doRestart(String app) async {
    await mustStateUp();

    final hostURL = 'http://$pmHost:$pmPort';
    // print('connecting to $hostURL');
    IO.Socket socket = IO.io(hostURL, <String, dynamic>{
      'transports': ['websocket'],
      // 'extraHeaders': {'foo': 'bar'}
    });
    socket.on('connect', (_) {
      socket.emit('restart', app);
    });
    socket.on('restartResult', (data) async {
      // print('restartResult from server: $data');
      socket.emit('msg', 'list');
    });
    socket.on('restartError', (data) async {
      print('restartError: $data');
      socket.disconnect();
    });
    socketHandleList(socket);
  }

  Future doStop(String app) async {
    await mustStateUp();

    final hostURL = 'http://$pmHost:$pmPort';
    // print('connecting to $hostURL');
    IO.Socket socket = IO.io(hostURL, <String, dynamic>{
      'transports': ['websocket'],
      // 'extraHeaders': {'foo': 'bar'}
    });
    socket.on('connect', (_) {
      socket.emit('stop', app);
    });
    socket.on('stopResult', (data) async {
      // print('stopResult from server: $data');
      socket.emit('msg', 'list');
    });
    socket.on('stopError', (data) async {
      print('stopError: $data');
      socket.disconnect();
    });
    socketHandleList(socket);
  }

  doStartByConfig(String configFile, List<String> args) async {
    await mustStateUp();
    var appConfig = await loadApp(configFile);

    final hostURL = 'http://$pmHost:$pmPort';
    // print('connecting to $hostURL');
    IO.Socket socket = IO.io(hostURL, <String, dynamic>{
      'transports': ['websocket'],
      // 'extraHeaders': {'foo': 'bar'}
    });
    socket.on('connect', (_) {
      // print('connect to pm3');
      socket.emit('start', appConfig);
    });
    socket.on('startResult', (data) async {
      // print('startResult from server: $data');
      // final List<Map<String, dynamic>> listData = data;
      socket.emit('msg', 'list');
    });
    socket.on('startError', (data) async {
      print('startError: $data');
      socket.disconnect();
    });
    socketHandleList(socket);
  }

  Future doList(String cmd, List<String> args,
      {bool disconnectOnComplete = true}) async {
    Completer completer = Completer();
    await mustStateUp();
    final hostURL = 'http://$pmHost:$pmPort';
    // print('doList: connecting to $hostURL');
    IO.Socket socket = IO.io(hostURL, <String, dynamic>{
      'transports': ['websocket'],
      // 'extraHeaders': {'foo': 'bar'}
    });
    socket.on('connect', (_) {
      print('doList: sendList');
      socket.emit('msg', 'list');
    });

    socketHandleList(socket);

    return completer.future;
  }

  doSave() async {
    Completer completer = Completer();
    await mustStateUp();
    final hostURL = 'http://$pmHost:$pmPort';
    // print('doSave: connecting to $hostURL');
    IO.Socket socket = IO.io(hostURL, <String, dynamic>{
      'transports': ['websocket'],
      // 'extraHeaders': {'foo': 'bar'}
    });
    socket.on('connect', (_) {
      socket.emit('msg', 'save');
    });
    socket.on('saveResult', (data) async {
      // print('startResult from server: $data');
      // final List<Map<String, dynamic>> listData = data;
      socket.emit('msg', 'list');
    });
    socket.on('saveError', (data) async {
      print('saveError: $data');
      socket.disconnect();
    });

    socketHandleList(socket);

    return completer.future;
  }

  doLoad() async {
    Completer completer = Completer();
    await mustStateUp();
    final hostURL = 'http://$pmHost:$pmPort';
    // print('doLoad: connecting to $hostURL');
    IO.Socket socket = IO.io(hostURL, <String, dynamic>{
      'transports': ['websocket'],
      // 'extraHeaders': {'foo': 'bar'}
    });
    socket.on('connect', (_) {
      socket.emit('msg', 'load');
    });
    socket.on('loadResult', (data) async {
      print('loadResult from server: $data');
      // final List<Map<String, dynamic>> listData = data;
      socket.emit('msg', 'list');
    });
    socket.on('loadError', (data) async {
      print('loadError: $data');
      socket.disconnect();
    });

    socketHandleList(socket);

    return completer.future;
  }

  socketHandleList(socket, {disconnectOnComplete = true}) {
    socket.on('list', (data) async {
      // print('list from server: $data');
      List<Map<String, dynamic>> listData = [];
      // print("socketHandleList $data");
      data.forEach((row) {
        Map<String, dynamic> mapped = row;
        listData.add(mapped);
      });

      await displayList(listData);
      if (disconnectOnComplete) {
        socket.disconnect();
      }
    });
  }

  displayList(List<Map<String, dynamic>> info) async {
// console.setBackgroundColor(ConsoleColor.cyan);
    console.setForegroundColor(ConsoleColor.white);
    console.writeLine('List Applications', TextAlignment.center);
    console.resetColorAttributes();
    console.writeLine();

    final consoleWidth = console.windowWidth;
    final colWidths = [
      (0.3 * consoleWidth).toInt(),
      (0.1 * consoleWidth).toInt(),
      (0.1 * consoleWidth).toInt(),
      (0.1 * consoleWidth).toInt(),
      (0.1 * consoleWidth).toInt()
    ];

    writeWithPad('Name', colWidths[0]);
    writeWithPad('Status', colWidths[1]);
    writeWithPad('Uptime', colWidths[2]);
    writeWithPad('Restarted', colWidths[3]);
    writeWithPad('Ended', colWidths[4]);

    console.writeLine();
    if (info.length == 0) {
      console.writeLine('- No applications -', TextAlignment.center);
    }

    final now = DateTime.now();
    for (var c = 0; c < info.length; c++) {
      final p = info[c];

      var ended = (p['ended'] ?? 'false').toString();

      final started = p.containsKey('pm_uptime') && p['pm_uptime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(p['pm_uptime'])
          : null;
      var upTime =
          started != null ? timeago.format(started, locale: 'en_short') : 'N/A';

      if (upTime == 'now') {
        upTime =
            ((now.millisecondsSinceEpoch - started.millisecondsSinceEpoch) /
                        1000)
                    .round()
                    .toString() +
                's';
      }

      writeWithPad(p['name'], colWidths[0]);
      writeWithPad(p['status'], colWidths[1]);
      writeWithPad(upTime.toString(), colWidths[2]);
      writeWithPad(p['restart_time'].toString(), colWidths[3]);
      writeWithPad(ended, colWidths[4]);
      console.writeLine();
    }

    console.writeLine();
    console.writeLine('- End -', TextAlignment.center);
  }

  saveAppState(conf) async {
    for (var c = 0; c < processors.length; c++) {
      if (processors[c]['name'] == conf['name']) {
        processors[c] = conf;
        break;
      }
    }
    // await saveState();
  }

  saveState() {
    configFile.writeAsStringSync(json.encode(processors));
  }

  loadState() {
    if (!configFile.existsSync()) {
      return;
    }
    if (processors.length > 0) {
      throw 'Please stop all processes 1st';
    }
    final content = configFile.readAsStringSync();
    var states = json.decode(content);
    processors = [];
    for (var c = 0; c < states.length; c++) {
      Map<String, dynamic> state = states[c];
      state['status'] = 'stopped';
      state['ended'] = true;
      processors.add(state);
    }
  }

  Future<Map<String, dynamic>> loadApp(String config) async {
    File appConfig = File(config);
    if (!appConfig.existsSync()) {
      throw 'File $config missing';
    }

    final content = appConfig.readAsStringSync();
    final conf = json.decode(content);

    final String name = conf['name'];
    final String script = conf['script'];
    final String cwd = conf['cwd'] ?? currentDir.path;
    final String args = conf['args'];
    print('env ${conf["env"]}');
    Map<String, String> configEnv = {};
    if (conf['env'] != null) {
      for (var key in conf['env'].keys) {
        configEnv[key] = conf['env'][key];
      }
    }

    if (name == null || name.isEmpty) {
      throw 'name missing';
    }
    if (script == null || script.isEmpty) {
      throw 'script missing';
    }

    Map<String, String> appEnv = {};
    for (var key in env.keys) {
      appEnv[key] = env[key];
    }
    for (var key in configEnv.keys) {
      appEnv[key] = configEnv[key];
    }
    logger.fine('App $name env: $appEnv');
    //find existing
    for (var c = 0; c < processors.length; c++) {
      final p = processors[c];
      if (p['name'] == name) {
        throw 'Process $name already exists';
      }
    }

    return <String, dynamic>{
      'name': name,
      'script': script,
      'env': appEnv,
      'cwd': cwd,
      'args': args,
      'PM3_HOME': configFolder.path,
      'pm_pid_path': configFolder.path + '/pids/$name-1.pid',
      'pm_out_log_path': configFolder.path + '/logs/$name-out.log',
      'pm_err_log_path': configFolder.path + '/logs/$name-error.log',
    };
  }

  writeWithPad(String msg, int length) {
    if (msg == null) {
      console.write(' ' * length);
      return;
    }
    if (msg.length > length) {
      console.write(msg.substring(0, length));
    } else {
      console.write(msg + (' ' * (length - msg.length)));
    }
  }

  loadModuleConfig() {}
}

startProcess(IsolateProcessHandler r) async {
  await r.setup();
  await r.mainSendPort.send(r.childReceiver.sendPort);
}
