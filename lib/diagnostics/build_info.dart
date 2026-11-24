/// The source commit and release version the running binary was built from.
///
/// Automated builds stamp both through `--dart-define` (see
/// `.github/workflows/build.yml`): `LAZER_COMMIT=<sha>` and
/// `LAZER_VERSION=<tag>`. Local builds without the defines fall back to the
/// pubspec version and the commit this beta was cut from. The values are
/// display-only: the app does not compare them with a release feed.
abstract final class BuildInfo {
  static const String _stamped = String.fromEnvironment('LAZER_COMMIT');
  static const String _fallback = '63e673e';
  static const String _stampedVersion = String.fromEnvironment('LAZER_VERSION');
  static const String _fallbackVersion = '2.0.0-beta.14';

  /// The full commit SHA the binary was built from.
  static String get commit => _stamped.isEmpty ? _fallback : _stamped;

  /// The first seven characters, the short form GitHub prints.
  static String get shortCommit {
    final String value = commit.trim();
    return value.length <= 7 ? value : value.substring(0, 7);
  }

  /// The release version without a `v` prefix or `+build` suffix.
  ///
  /// A branch name such as `nextgen` is not a version, so it falls back to
  /// the version in pubspec instead of being shown as one.
  static String get version =>
      versionFromStamp(_stampedVersion) ?? _fallbackVersion;

  /// The version as it appears in the interface.
  static String get displayVersion => 'v$version';

  /// Parses a CI stamp. Returns null when [raw] is not a version.
  static String? versionFromStamp(String raw) {
    String text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1).trim();
    }
    final int plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);
    if (text.isEmpty) return null;
    final int dash = text.indexOf('-');
    final String core = dash >= 0 ? text.substring(0, dash) : text;
    final String pre = dash >= 0 ? text.substring(dash + 1) : '';
    final List<String> parts = core.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    for (final String part in parts) {
      if (!RegExp(r'^\d+$').hasMatch(part)) return null;
    }
    if (pre.isNotEmpty &&
        !RegExp(r'^[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*$').hasMatch(pre)) {
      return null;
    }
    final List<String> numbers = List<String>.from(parts);
    while (numbers.length < 3) {
      numbers.add('0');
    }
    return '${numbers.join('.')}${pre.isEmpty ? '' : '-$pre'}';
  }
}
