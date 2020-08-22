import 'package:intl/intl.dart';

DateTime getNow() {
  return new DateTime.now().toUtc();
}

String timeFormat(DateTime date) {
  final offset = date.timeZoneOffset;
  final offsetHour = offset.inHours;
  final offsetSymbol = offsetHour >= 0 ? '+' : '-';

  final offsetHourStr = offsetHour < 10 ? '0$offsetHour' : '$offsetHour';
  final offsetMinute =
      offset.inMinutes.abs() % 60 == 0 ? 0 : offset.inMinutes.abs() % 60;
  final offsetMinuteStr = offsetMinute > 0
      ? (offsetMinute >= 10 ? '$offsetMinute' : '0$offsetMinute')
      : '00';
  DateFormat format = DateFormat("yyyy-MM-ddTHH:mm:ss");

  return format.format(date) + '$offsetSymbol$offsetHourStr$offsetMinuteStr';
}

String utcTimeFormat(DateTime date) {
  DateFormat format = DateFormat("yyyy-MM-ddTHH:mm:ss");

  return format.format(date.toUtc()) + 'Z';
}

DateTime parseUTCTimeString(String date) {
  return DateTime.parse(date);
}
