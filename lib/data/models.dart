/// Models presented by the player, mapped from the gateway response.
library;

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.coverSeed,
    this.accent = 0,
    this.coverUrl,
    this.albumId = 0,
    this.translatedTitle,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;

  /// Seed for the generative field-plate cover illustration.
  final int coverSeed;

  /// Index into the cover palette family (0 = ivory, 1 = manilla, 2 = oat).
  final int accent;
  final String? coverUrl;
  final int albumId;
  final String? translatedTitle;
}

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.trackIds,
    required this.coverSeed,
    this.description = '',
    this.coverUrl,
    this.trackCount = 0,
  });

  final String id;
  final String name;
  final List<String> trackIds;
  final int coverSeed;
  final String description;
  final String? coverUrl;
  final int trackCount;
}

class Album {
  const Album({
    required this.id,
    required this.title,
    required this.artist,
    required this.year,
    required this.coverSeed,
    required this.note,
    this.accent = 0,
    this.trackCount,
    this.coverUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String year;
  final int coverSeed;
  final String note;
  final int accent;

  final int? trackCount;
  final String? coverUrl;
}
