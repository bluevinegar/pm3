import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pm3/pm.dart';

startLogRotate(PM3 pm) async {
  Timer(Duration(seconds: 10), () async {
    // print('checking log');
    await pm.logRotate(doLogRotate);
    startLogRotate(pm);
  });
}

doLogRotate(String file, String truncateSize) async {
  if (Platform.isWindows) {
    print('TODO: window logRotate');
    return;
  }

  //fallocate -c -o 0 -l 100MB yourfile
  final cmdArgs = ['-c', '-o', '0', '-l', '${truncateSize}', file];
  print('fallocate ${cmdArgs.join(" ")}');
  await Process.start('fallocate', cmdArgs).then((Process process) {
    // await Process.start('ftruncate', [file, '--size', '${balanceSize}MB'])
    process.stdout.transform(utf8.decoder).listen((data) {
      print('doLogRotate: $data');
    });
    process.stderr.transform(utf8.decoder).listen((data) {
      print('doLogRotate: error: $data');
    });
    process.exitCode.then((exitCode) {
      print('doLogRotate: exit: $exitCode');
    });
  });
}
