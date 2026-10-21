import '../player/now_playing_page.dart';

export '../player/now_playing_page.dart' show NowPlayingPage;

/// Compatibility name used by the shell and existing tests. The implementation
/// is the new [NowPlayingPage] in `lib/player`; no old page code remains here.
class LegacyNowPlayingPage extends NowPlayingPage {
  const LegacyNowPlayingPage({super.key, required super.state, super.onClose});
}
