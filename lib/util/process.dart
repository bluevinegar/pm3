import 'dart:io';

killProcess(int pid) async {
  if (Platform.isWindows) {
  } else {
    // kill all pids from bottom
    // ps --forest -o pid=,tty=,stat=,time=,cmd= -g $(ps -o sid= -p 21438) | awk '{ print $1 }'
    // ps --ppid 8663 -o pid=
    // final pidArgs = [
    //   '--ppid',
    //   '$pid',
    //   '-o',
    //   'pid=',
    // ];
    // print('running: ps ${pidArgs.join(' ')}');
    // ProcessResult res = Process.runSync('ps', pidArgs);
    // ProcessResult res = Process.runSync('ps', ['-Af']);
    // ProcessResult res = Process.runSync('ls', []);

    final pidArgs = ['-P', '$pid'];
    ProcessResult res = Process.runSync('pgrep', pidArgs);
    String treePids = res.stdout.trim();
    // print('ps result? ${res.stdout}');
    if (treePids.isEmpty) {
      // throw 'PID tree failed for $pid';
      print('no child process for $pid');
    } else {
      print('process $pid childs: $treePids');
      final pids = treePids.split('\n');
      for (var c = pids.length - 1; c >= 0; c--) {
        final killPid = int.parse(pids[c]);

        await killProcess(killPid);
        // print('killing $killPid');
        // Process.killPid(killPid);
        if (processIsAlive(killPid)) {
          throw 'Process still alive $killPid';
        }
      }
    }
    // res.stderr.drain<String>();
  }
  print('killing caller $pid');
  Process.killPid(pid); //kill the original program
  while (processIsAlive(pid)) {
    print('waiting still alive $pid');
    await sleep(Duration(microseconds: 100));
  }
  // if (processIsAlive(pid)) {
  //   throw 'Process still alive $pid';
  // }
}

bool processIsAlive(int pid) {
  final res = Process.runSync('kill', ['-0', '$pid']);
  // print('check process ${res.exitCode}');
  if (res.exitCode == 0) {
    return true; //running
  }
  return false;
}
