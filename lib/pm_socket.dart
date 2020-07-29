import 'dart:io';

import 'package:pm3/pm.dart';
import 'package:socket_io/socket_io.dart';
// import 'package:socket_io/src/util/event_emitter.dart';

startSocketServer(PM3 app) async {
  var io = new Server();

  io.on('connection', (client) {
    // print('client connection on default');
    // final headers = client.handshake['headers'];
    // headers.forEach((k, v) => print('$k => $v'));
    client.on('msg', (data) async {
      print('client says: $data');
      switch (data) {
        case 'list':
          client.emit('list', app.processors);
          break;

        case 'save':
          try {
            await app.serverDoSave();
            client.emit('saveResult', []);
          } catch (err) {
            client.emit('saveError', [err.toString()]);
          }
          break;

        // case 'load':
        //   try {
        //     await app.serverDoLoad();
        //     client.emit('loadResult', []);
        //   } catch (err) {
        //     client.emit('loadError', [err.toString()]);
        //   }
        //   break;
        default:
          client.emit('error', 'unknown command $data');
      }
    });

    client.on('startApp', (data) async {
      try {
        await app.serverDoStartApp(data);
        client.emit('startResult', []);
      } catch (err) {
        client.emit('startError', [err.toString()]);
      }
    });

    client.on('start', (data) async {
      try {
        await app.serverDoStart(data);
        print('app.serverDoStart done');
        client.emit('startResult', []);
      } catch (err) {
        client.emit('startError', [err.toString()]);
      }
    });

    client.on('stop', (data) async {
      try {
        await app.serverDoStop(data);
        client.emit('stopResult', []);
      } catch (err) {
        client.emit('stopError', [err.toString()]);
      }
    });

    client.on('restart', (data) async {
      try {
        await app.serverDoRestart(data);
        client.emit('restartResult', []);
      } catch (err) {
        client.emit('restartError', [err.toString()]);
      }
    });

    client.on('resurrect', (data) async {
      try {
        await app.serverDoResurrect();
        client.emit('resurrectResult', []);
      } catch (err) {
        client.emit('resurrectError', [err.toString()]);
      }
    });

    client.on('delete', (data) async {
      try {
        await app.serverDoDelete(data);
        client.emit('deleteResult', []);
      } catch (err) {
        client.emit('deleteError', [err.toString()]);
      }
    });

    client.on('log', (data) async {
      try {
        await app.serverDoLog(data, client);
        // client.emit('logResult', []);
      } catch (err, stack) {
        print('log-error! $err | ${stack.toString()}');
        client.emit('logError', [err.toString()]);
      }
    });

    client.on('disconnect', (data) async {
      app.serverClientDisconnect(client);
      print('client dc');
    });
  });

  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((event) async {
      print('sigterm $event');
      try {
        await app.serverDoDelete('all');
      } catch (err) {
        print('sighup stop all error $err');
      }
      exit(0);
    });
  } else {
    ProcessSignal.sighup.watch().listen((event) async {
      print('sighup $event');
      try {
        await app.serverDoDelete('all');
      } catch (err) {
        print('sighup stop all error $err');
      }
      exit(0);
    });
  }

  io.listen(30100);
}
