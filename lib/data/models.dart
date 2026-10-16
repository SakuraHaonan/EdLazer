/// Models presented by the player, mapped from the gateway response.
library;

class ArtistRef {
  const ArtistRef({required this.id, required this.name, this.coverUrl});
  final int id;
  final String name;
  final String? coverUrl;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'coverUrl': coverUrl,
  };
  factory ArtistRef.fromJson(Map<String, dynamic> json) => ArtistRef(
    id: (json['id'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
    coverUrl: json['coverUrl'] as String?,
  );
  static List<ArtistRef> list(Object? values) => values is List
      ? [
          for (final value in values)
            if (value is Map<String, dynamic>) ArtistRef.fromJson(value),
        ]
      : const [];
}

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
    this.artists = const [],
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
  final List<ArtistRef> artists;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': duration.inMilliseconds,
    'coverSeed': coverSeed,
    'accent': accent,
    'coverUrl': coverUrl,
    'albumId': albumId,
    'translatedTitle': translatedTitle,
    'artists': artists.map((artist) => artist.toJson()).toList(),
  };

  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: json['id'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    album: json['album'] as String,
    duration: Duration(milliseconds: json['durationMs'] as int),
    coverSeed: json['coverSeed'] as int,
    accent: json['accent'] as int? ?? 0,
    coverUrl: json['coverUrl'] as String?,
    albumId: json['albumId'] as int? ?? 0,
    translatedTitle: json['translatedTitle'] as String?,
    artists: ArtistRef.list(json['artists']),
  );
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

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'trackIds': trackIds,
    'coverSeed': coverSeed,
    'description': description,
    'coverUrl': coverUrl,
    'trackCount': trackCount,
  };

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: json['id'] as String,
    name: json['name'] as String,
    trackIds: (json['trackIds'] as List).cast<String>(),
    coverSeed: json['coverSeed'] as int,
    description: json['description'] as String? ?? '',
    coverUrl: json['coverUrl'] as String?,
    trackCount: json['trackCount'] as int? ?? 0,
  );
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
    this.artists = const [],
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
  final List<ArtistRef> artists;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'year': year,
    'coverSeed': coverSeed,
    'note': note,
    'accent': accent,
    'trackCount': trackCount,
    'coverUrl': coverUrl,
    'artists': artists.map((artist) => artist.toJson()).toList(),
  };

  factory Album.fromJson(Map<String, dynamic> json) => Album(
    id: json['id'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    year: json['year'] as String,
    coverSeed: json['coverSeed'] as int,
    note: json['note'] as String,
    accent: json['accent'] as int? ?? 0,
    trackCount: json['trackCount'] as int?,
    coverUrl: json['coverUrl'] as String?,
    artists: ArtistRef.list(json['artists']),
  );
}
