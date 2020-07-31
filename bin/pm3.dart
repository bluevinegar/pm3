import 'dart:io';
import 'dart:convert';
import 'package:pm3/pm.dart';

main(List<String> args) async {
  String cmd = args.length > 0 ? args[0] : '';
  if (args.length < 1) {
    return runHelp(cmd, args.skip(1).toList());
  }
  final pm = PM3(Platform.environment);
  await pm.init();
  switch (cmd) {
    case 'boot':
      final List<String> cmdArgs = args.length > 1 ? args.skip(1).toList() : [];
      await pm.doBoot(cmdArgs.skip(1).toList());
      exit(0);
      break;
    case 'start':
      final List<String> cmdArgs = args.length > 1 ? args.skip(1).toList() : [];
      final app = cmdArgs.length > 0 ? cmdArgs[0] : '';
      // print('app $app args: $cmdArgs');
      if (app.endsWith('.json')) {
        print('start? $app');
        await pm.doStartByConfig(app, cmdArgs.skip(1).toList());
      } else {
        print('start without json');
        await pm.doStart(app, cmdArgs.skip(1).toList());
      }
      break;
    case 'stop':
      final List<String> cmdArgs = args.length > 1 ? args.skip(1).toList() : [];
      final app = cmdArgs.length > 0 ? cmdArgs[0] : '';
      if (app.isEmpty) {
        return runHelp('stop', []);
      }
      await pm.doStop(app);
      break;
    case 'restart':
      final List<String> cmdArgs = args.length > 1 ? args.skip(1).toList() : [];
      final app = cmdArgs.length > 0 ? cmdArgs[0] : '';
      if (app.isEmpty) {
        return runHelp('restart', []);
      }
      await pm.doRestart(app);
      break;

    case 'delete':
      final List<String> cmdArgs = args.length > 1 ? args.skip(1).toList() : [];
      final app = cmdArgs.length > 0 ? cmdArgs[0] : '';
      if (app.isEmpty) {
        return runHelp('delete', []);
      }
      await pm.doDelete(app);
      break;

    case 'resurrect':
      final List<String> cmdArgs = args.length > 1 ? args.skip(1).toList() : [];
      final app = cmdArgs.length > 0 ? cmdArgs[0] : '';
      await pm.doResurrect(app);
      break;

    case 'log':
      final List<String> cmdArgs = args.length > 1 ? args.skip(1).toList() : [];
      final app = cmdArgs.length > 0 ? cmdArgs[0] : '';
      await pm.doLog(app);
      break;
    case 'list':
      await pm.doList(cmd, args.skip(1).toList());
      break;

    case 'save':
      await pm.doSave();
      break;

    // case 'load':
    //   await pm.doLoad();
    //   break;

    default:
      throw 'Unknown command $cmd';
  }
  // await runCmd('ls', []);
}

final String cmdName = 'pm3';
runHelp(String cmd, List<String> cmdArgs) {
  if (cmd == 'start') {
    print("""Usage: $cmdName [cmd] app
  Options:
  
  Commands:
  start jsonfile.json
  nohup pm3 start &
  """);
    return;
  }
  if (cmd == 'stop') {
    print("""Usage: $cmdName [cmd] app
  Options:
  
  Commands:
  stop app|all""");
    return;
  }

  if (cmd == 'delete') {
    print("""Usage: $cmdName [cmd] app
  Options:
  
  Commands:
  delete app|all""");
    return;
  }

  if (cmd == 'restart') {
    print("""Usage: $cmdName [cmd] app
  Options:
  
  Commands:
  restart app|all""");
    return;
  }

  print("""Usage: $cmdName [cmd] app
  Options:
  
  Commands:
  start jsonfile.json
  restart app|all
  stop app|all
  log [app]
  list
  resurrect # load saved state and start all
  save # save states
  """);
}

runCmd(String cmd, List<String> cmdArgs) {
  return Process.start(cmd, cmdArgs).then((Process process) {
    process.stdout.transform(utf8.decoder).listen((output) {
      print(output);
    });
    // process.stdin.writeln('Hello, world!');
  });
}
