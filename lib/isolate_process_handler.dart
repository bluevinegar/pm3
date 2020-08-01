import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:pm3/util/date.dart';
import 'package:pm3/util/process.dart';
import 'package:socket_io/socket_io.dart' as socketIO;
import 'package:mutex/mutex.dart';

Mutex processMutex = Mutex();

class LogRequester {
  socketIO.Socket clientHandler;
  LogRequester(this.clientHandler);
}

class IsolateProcessHandler {
  ReceivePort childReceiver;
  SendPort mainSendPort;
  List<LogRequester> logClientHandlers = [];

  Map<String, dynamic> config;
  Process process;
  String state;
  bool ended = true;
  bool deleted = false;
  bool sendLog = false;
  String sendLogType = 'std';

  File logStd, logErr;

  IsolateProcessHandler(this.mainSendPort, this.config) {
    // print('IPH start');
    if (!config.containsKey('pm_out_log_path') ||
        config['pm_out_log_path'] == null ||
        (config['pm_out_log_path'] as String).isEmpty) {
      throw 'pm_out_log_path not set';
    }
    if (!config.containsKey('pm_err_log_path') ||
        config['pm_err_log_path'] == null ||
        (config['pm_err_log_path'] as String).isEmpty) {
      throw 'pm_err_log_path not set';
    }
    // print('IPH $config');
    logStd = File(config['pm_out_log_path']);
    logErr = File(config['pm_err_log_path']);
    // print('setting up logs');
    if (!logStd.parent.existsSync()) {
      logStd.parent.createSync(recursive: true);
    }
    if (!logErr.parent.existsSync()) {
      logErr.parent.createSync(recursive: true);
    }
    print('IPH initialised');
  }

  bool get isRunning {
    return state == 'running';
  }

  log({lastLineIndex = 20, errorOnly: false}) async {
    final name = config['name'];
    final logPrefix = errorOnly ? 'logErr:' : 'log:';

    sendLogType = errorOnly ? 'error' : 'std';
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.start(
              'tail',
              [
                '-n',
                lastLineIndex.toString(),
                errorOnly ? logErr.path : logStd.path
              ],
              mode: ProcessStartMode.normal)
          .then((Process proc) {
        proc.stdout.transform(utf8.decoder).listen((data) {
          print("IPH: $name tail: $data");
          mainSendPort.send('$logPrefix$data\n');
        });
        proc.stderr.transform(utf8.decoder).listen((data) {
          print("IPH: $name tail error: $data");
        });
        proc.exitCode.then((exitCode) {
          print('IPH: $name: tail exit: $exitCode');
        });
        sendLog = true;
      });

      return;
    }

    final logReader = File(logStd.path);
    final stream = logReader
        .openRead()
        .transform(utf8.decoder)
        .transform(new LineSplitter());
    List<String> lines = [];
    await for (var line in stream) {
      lines.add(line);
      if (lines.length > lastLineIndex) {
        lines.removeAt(0);
      }
    }
    lines.forEach((log) {
      // clientHandler.emit('log', log);
      mainSendPort.send('$logPrefix$log\n');
    });
    sendLog = true;
  }

  start() async {
    final name = config['name'];
    if (isRunning) {
      print('IPH: already running $name, ignored');
      return;
    }
    ended = false;
    final script = config['script'];
    final args = config['args'];
    final cwd = config['cwd'] ?? Directory.current.path;
    final env = <String, String>{};

    if (config.containsKey('env')) {
      for (var key in config['env'].keys) {
        final val = config['env'][key].toString();
        env[key] = val;
      }
    }

    final List<String> processArgs = args == null ? [] : args.split(' ');

    print('IPH: starting $name $script args: ${processArgs} (cwd:$cwd)');
    if (sendLogType != 'error') {
      mainSendPort.send('log:starting $name args: $processArgs (cwd:$cwd)\n');
    }
    // print('IPH: starting $name sent starting log');
    try {
      await Process.start(script, processArgs,
              workingDirectory: cwd, environment: env)
          .then((Process proc) {
        process = proc;
        state = 'running';
        print("sending to main started");
        mainSendPort.send('started:${process.pid}');
        print("sent to main started");
        process.stdout.transform(utf8.decoder).listen((data) {
          // print("stdout $data");
          final nowFormatted = logFormattedNow();
          logStd.writeAsStringSync(nowFormatted + ' ' + data,
              mode: FileMode.append);
          if (sendLog && sendLogType == 'std') {
            // print('IPH: $name: emitLog');
            // clientHandler.emit('log', data);
            mainSendPort.send('log:$nowFormatted $data');
          }
          stdout.write('IPH: $name: stdout: $data');
        });
        process.stderr.transform(utf8.decoder).listen((data) {
          // print("stderr $data");
          final nowFormatted = logFormattedNow();
          logStd.writeAsStringSync(nowFormatted + ' ' + data,
              mode: FileMode.append);
          logErr.writeAsStringSync(nowFormatted + ' ' + data,
              mode: FileMode.append);
          if (sendLog) {
            // clientHandler.emit('logErr', data);
            mainSendPort.send('logErr:$nowFormatted $data');
          }
          stdout.write('IPH: $name: stderr: $data');
        });
        process.exitCode.then((exitCode) {
          print('IPH: $name: exit: $exitCode');
          state = 'stopped';
          final nowFormatted = logFormattedNow();

          logStd.writeAsStringSync(nowFormatted + ' ' + 'exit:$exitCode\n',
              mode: FileMode.append);
          if (exitCode != 0) {
            logErr.writeAsStringSync(nowFormatted + ' ' + 'exit:$exitCode\n',
                mode: FileMode.append);
            mainSendPort.send('logErr:$nowFormatted exit:$exitCode\n');
          } else if (sendLogType != 'error') {
            mainSendPort.send('log:$nowFormatted exit:$exitCode\n');
          }
          config['status'] = 'stopped';
          config['pid'] = -1;
          // config['pid'] = process.pid;
          config['exit_code'] = exitCode;
          mainSendPort.send('exit:$exitCode');
        });
      });
      print('IPH: started $name $script args: ${processArgs} (cwd:$cwd)');
    } catch (err) {
      print("IPH: start $name: error: $err");
      rethrow;
    }
  }

  logFormattedNow() {
    final now = DateTime.now();
    return timeFormat(now);
  }

  stop({bool end = true}) async {
    final name = config['name'];
    if (!isRunning) {
      print('IPH: $name already ended.');
      mainSendPort.send('ended');
      ended = true;
      return;
    }

    if (process != null) {
      print('IPH: $name stopping pid ${process.pid}...');
      await killProcess(process.pid);
      // process.kill();
    }
    print('IPH: $name ended.');
    mainSendPort.send('ended');
    state = 'stopped';
    ended = end;
  }

  restart() async {
    final name = config['name'];
    print('IPH: $name restart ended? ${ended}');
    if (!ended) {
      print('IPH: $name restart: stopping $name...');
      await stop();
      ended = true;
    }
    print('IPH: $name restart: starting $name...');
    return await start();
  }

  delete() async {
    // final name = config['name'];
    if (!ended) {
      await stop();
    }

    mainSendPort.send('deleted');
    deleted = true;
    sendLog = false;
  }

  setup() async {
    final name = config['name'];
    childReceiver = ReceivePort()
      ..listen((data) async {
        await processMutex.acquire();

        try {
          // print('data? ${data.runtimeType.toString()}');
          if (data is LogRequester) {
            logClientHandlers.add(data);
            return;
          }
          if (data is String) {
            if (data.startsWith('log')) {
              print('IPH: $name log? $data');
              final errorOnly = data.contains(':error');
              await log(errorOnly: errorOnly);

              return;
            }
            switch (data) {
              case 'tick':
                break;
              case 'start':
                print('IPH: $name: start');
                await start();
                print('IPH: $name: started');
                break;

              case 'restart':
                print('IPH: $name: restart');
                await restart();
                print('IPH: $name: restarted');
                break;

              case 'stop':
                await stop();
                print('IPH: $name: stopped');
                break;

              case 'delete':
                await delete();
                print('IPH: $name: deleted');
                break;

              default:
                if (data.startsWith('config:')) {
                  // print('IPH: $name config update');
                  final dataConf =
                      json.decode(data.replaceFirst('config:', ''));
                  config = dataConf;
                }
            }
          }
        } catch (err, stack) {
          print('process listen error: $err | ${stack.toString()}');
        } finally {
          await processMutex.release();
        }
      });
  }
}
