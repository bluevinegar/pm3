import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
// import 'dart:convert';

// import 'package:udp/udp.dart';
import 'package:logging/logging.dart';
import 'package:colorize/colorize.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:intl/intl.dart';
import 'package:mutex/mutex.dart';

final logger = Logger('default');
// Endpoint graylogEndpoint;
// UDP graylogSender;

const Map<String, dynamic> defaultEmptyVariable = {};

SendPort loggingIsolateStream;
Mutex logMutex = Mutex();

/// setup logging, alows future addition of other type of logger like graylog
Future<Logger> setupLogger(String app,
    {bool showTime: false, showLocation: true, silent: false}) async {
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.INFO;
  Logger('MongoActions').level = Level.INFO;
  logger.level = Level.FINE;

  if (loggingIsolateStream == null) {
    loggingIsolateStream = await initLogIsolate(app, silent: silent);
    Timer.periodic(Duration(seconds: 2), (t) async {
      await loggingIsolateStream.send('tick');
    });

    Logger.root.onRecord.listen((record) async {
      String str =
          "${showTime ? new DateFormat('yyyy-MM-dd_H:m:s').format(record.time) + ' ' : ''}${record.message}";
      // String str ='${record.level.name}: ${record.time} ${record.message} $coloredStack';
      String country = ' ';
      if (record.message.length >= 4) {
        if (record.message.substring(2, 4) == '::') {
          country = record.message.substring(0, 2);
          // print('found country $country');
          // await sleep(Duration(seconds: 5));
        }
      }
      if (record.level >= Level.SEVERE) {
        str += '\n' + StackTrace.current.toString();
        Colorize cStr = Colorize(str)..red();
        print(cStr);
        // sendGraylog(str, level: 'severe');
        // preparehandler - mysql
        if (str.contains('PrepareHandler') ||
            str.contains('MongoDB ConnectionException: Invalid state')) {
          print("mysql disconnected, terminating app for respawn");
          await sleep(Duration(seconds: 5));
          Isolate.current.kill();
        }

        await loggingIsolateStream
            .send(Log(level: 7, msg: str, app: app, country: country));
        // pendingLogs.add(Log(level: 7, msg: str));
        return;
      }

      if (showLocation) {
        var frame = Trace.current().frames[1];
        int newIndex = 9;
        while ((!frame.location.contains('package:pm3')) &&
            Trace.current().frames.length > newIndex) {
          newIndex += 1;
          // print("skipping $stackLog");
          frame = Trace.current().frames[min(
              newIndex, Trace.current().frames.length - 1)]; //skip dart:async
        }

        Colorize coloredStack = Colorize(frame.location)..lightBlue();
        str += ' ' + coloredStack.toString();
      }

      if (record.level == Level.FINE) {
        Colorize cStr = Colorize(str)..darkGray();
        print(cStr);

        await loggingIsolateStream
            .send(Log(level: 2, msg: str, app: app, country: country));
        // pendingLogs.add(Log(level: 2, msg: str));
        // sendGraylog(str, level: 'fine');
        return;
      }

      if (record.level == Level.FINER) {
        Colorize cStr = Colorize(str)..darkGray();
        print(cStr);

        await loggingIsolateStream
            .send(Log(level: 1, msg: str, app: app, country: country));
        // pendingLogs.add(Log(level: 1, msg: str));
        // sendGraylog(str, level: 'finer');
        return;
      }

      print(str);
      await loggingIsolateStream
          .send(Log(level: 3, msg: str, app: app, country: country));
      // pendingLogs.add(Log(level: 3, msg: str));
    });
  }

  return logger;
}

Future<SendPort> initLogIsolate(String app, {silent = false}) async {
  Completer completer = new Completer<SendPort>();
  ReceivePort isolateToMainStream = ReceivePort();

  isolateToMainStream.listen((data) {
    if (data is SendPort) {
      loggerLog('init sendport');
      SendPort mainToIsolateStream = data;
      completer.complete(mainToIsolateStream);
    } else {
      loggerLog('[isolateToMainStream] $data');
    }
  });

  await Isolate.spawn(loggingIsolate,
      LogInit(app, isolateToMainStream.sendPort, silent: silent));
  loggerLog('initLogIsolate');
  return completer.future;
}

class LogInit {
  final SendPort sendPort;
  final String app;
  final bool silent;
  LogInit(this.app, this.sendPort, {this.silent = false});
}

void loggingIsolate(LogInit initConfig) async {
  Map<String, List<Log>> pendingLogs = {};
  ReceivePort receiver = ReceivePort();
  // loggerLog("mainsendport app: ${initConfig.app} ${initConfig.sendPort}");
  //send to main thread
  if (!initConfig.silent) {
    loggerLog('loggingIsolate init');
  }
  await initConfig.sendPort.send(receiver.sendPort);
  receiver.listen((data) async {
    await logMutex.acquire();

    try {
      if (data is Log) {
        var country = data.country ?? ' ';
        if (pendingLogs[country] == null) {
          pendingLogs[country] = [];
        }

        pendingLogs[country].add(data);
      } else if (data is String) {
        if (data == 'tick') {
          if (pendingLogs.keys.length < 1) {
            return;
          }
          // loggerLog('countries logs ${pendingLogs.keys}');
          for (var country in pendingLogs.keys) {
            if (pendingLogs[country].isEmpty) {
              continue;
            }
            var logs = pendingLogs[country];
            pendingLogs[country] = [];
            if (!initConfig.silent) {
              loggerLog('sending "$country" ${logs.length} logs');
            }

            // TODO send logs to backend
          }
        }
      }
    } catch (err) {
      loggerLog('log receiver error: $err');
    } finally {
      await logMutex.release();
    }
    // loggerLog('[loggingIsolate] $data');
    // pendingLogs.add(data);
  });

  // receiver.sendPort.send('aaaaa!');
}

loggerLog(String str) {
  Colorize cStr = Colorize(str)..darkGray();
  print(cStr);
}

class Log {
  String app;
  String msg;
  Map<String, dynamic> meta;
  int level;
  String country;
  Log({this.app, this.msg, this.meta, this.level, this.country});

  toMap() {
    return {'level': level, 'msg': msg, 'meta': meta, 'app': app};
  }
}

const emptyMeta = <String, dynamic>{};
