/// Human-readable byte count shared by the download and local-library
/// surfaces.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '${value.round()} B';
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}
