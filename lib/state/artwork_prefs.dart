import 'package:flutter/foundation.dart';

/// Whether album covers may play Apple Music's animated artwork.
///
/// Persisted under [kMotionArtworkPrefKey]; the settings page writes it and
/// [MotionArtwork] reads it when it resolves a cover.
final ValueNotifier<bool> motionArtworkEnabled = ValueNotifier<bool>(true);

/// SharedPreferences key for [motionArtworkEnabled].
const String kMotionArtworkPrefKey = 'lazer_motion_artwork';
