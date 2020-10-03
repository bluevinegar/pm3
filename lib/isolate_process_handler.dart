import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:pm3/util/date.dart';
import 'package:pm3/util/process.dart';
import 'package:socket_io/socket_io.dart' as socketIO;
import 'package:mutex/mutex.dart';

Mutex processMutex = Mutex();
Mutex logStartMutex = Mutex();

class LogRequester {
  socketIO.Socket clientHandler;
  String logType;
  bool started = false;
  LogRequester(this.clientHandler, {this.logType = 'std'});
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

  sendLogFile(
      String name, int lastLineIndex, String logPrefix, String logFile) async {
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.start('tail', ['-n', lastLineIndex.toString(), logFile],
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
  }

  log({lastLineIndex = 20, errorOnly: false}) async {
    //allow singular logging at 1 time to avoid sending logging to 2 different log request concurrently that did not finish
    await logStartMutex.acquire();

    try {
      final name = config['name'];
      if (errorOnly) {
        await sendLogFile(name, lastLineIndex, 'logErrStart:', logErr.path);
      } else {
        await sendLogFile(name, lastLineIndex, 'logStart:', logStd.path);
      }
      sendLog = true;
    } catch (err) {
      rethrow;
    } finally {
      await logStartMutex.release();
    }
  }

  start() async {
    final name = config['name'];
    if (isRunning) {
      print('IPH: already running $name, ignored');
      return;
    }
    ended = false;
    String script = config['script'];
    final String execInterpreter = config['exec_interpreter'];
    final String execPath = config['pm_exec_path'];
    final args = config['args'];
    final cwd = config['cwd'] ?? Directory.current.path;
    final env = <String, String>{};

    if (config.containsKey('env')) {
      for (var key in config['env'].keys) {
        final val = config['env'][key].toString();
        env[key] = val;
      }
    }

    final List<String> processArgs = [];

    if (execInterpreter != null && execInterpreter.isNotEmpty) {
      if (script == null || script.isEmpty) {
        script = execInterpreter;
      } else {
        processArgs.add(execInterpreter);
      }
    }

    if (execPath != null && execPath.isNotEmpty) {
      processArgs.add(execPath);
    }

    if (args != null) {
      if (args is String) {
        processArgs.addAll(args.split(' '));
      } else if (args is List) {
        print('IPH: starting $name $script args is list');
        processArgs.addAll(args.map((e) => e as String).toList());
      } else {
        throw 'Unknown args $args';
      }
    }

    print('IPH: starting $name script $script args: ${processArgs} (cwd:$cwd)');
    mainSendPort.send(
        'log:starting $name script $script args: $processArgs (cwd:$cwd)\n');
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
          if (sendLog) {
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
          } else {
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
              final logCmd = data.split(':');
              final errorOnly = logCmd[1] == 'error';
              final lines = int.parse(logCmd[2]);
              await log(errorOnly: errorOnly, lastLineIndex: lines);

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
