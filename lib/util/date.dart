import 'package:intl/intl.dart';

DateTime getNow() {
  return new DateTime.now().toUtc();
}

String utcTimeFormat(DateTime date) {
  DateFormat format = DateFormat("yyyy-MM-ddTHH:mm:ss");

  return format.format(date.toUtc()) + 'Z';
}

DateTime parseUTCTimeString(String date) {
  return DateTime.parse(date);
}
