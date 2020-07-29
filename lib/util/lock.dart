import 'dart:io';

import 'package:mutex/mutex.dart';
// import 'package:pm3/util/date.dart';

Map<String, Mutex> mutexInstance = {};

Map<String, bool> dumbMutex = {};
const Duration defaultTimeout = Duration(seconds: 40);

mutexLock(String name, {Duration timeout = defaultTimeout}) async {
  if (!dumbMutex.containsKey(name)) {
    dumbMutex[name] = false;
  }
  var end = new DateTime.now().toUtc().add(timeout);
  var now = new DateTime.now().toUtc();
  while (dumbMutex[name] && now.isBefore(end)) {
    await sleep(Duration(milliseconds: 100));
    now = new DateTime.now().toUtc();
  }

  if (dumbMutex[name]) {
    //still locked
    throw "Timed out";
  }
}

mutexUnlock(String name) async {
  if (!dumbMutex.containsKey(name)) {
    throw "Mutex missing $name";
  }
  dumbMutex[name] = false;
}

// mutexLock(String name) async {
//   if (!mutexInstance.containsKey(name)) {
//     dumbMutex[name] = Mutex();
//   }

//   await mutexInstance[name].acquire();
// }

// mutexUnlock(String name) async {
//   if (!mutexInstance.containsKey(name)) {
//     throw "Mutex missing $name";
//   }
//   await mutexInstance[name].release();
// }
