/// The source commit the running binary was built from.
///
/// Automated builds stamp the commit being built through
/// `--dart-define=LAZER_COMMIT=<sha>` (see `.github/workflows/build.yml`).
/// Local builds without the define fall back to [_fallback], the commit this
/// tree was cut from when the stamp was last taken, so the About row still
/// names a commit instead of going blank.
abstract final class BuildInfo {
  static const String _stamped = String.fromEnvironment('LAZER_COMMIT');
  static const String _fallback = 'a8518ab';

  /// The full commit SHA the binary was built from.
  static String get commit => _stamped.isEmpty ? _fallback : _stamped;

  /// The first seven characters, the short form GitHub prints.
  static String get shortCommit {
    final String value = commit.trim();
    return value.length <= 7 ? value : value.substring(0, 7);
  }
}
