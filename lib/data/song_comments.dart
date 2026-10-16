import '../utils/artwork.dart';

int _number(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;
Map<String, dynamic> _object(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

class CommentReply {
  const CommentReply({required this.author, required this.content});
  final String author, content;
  factory CommentReply.fromJson(Map<String, dynamic> json) => CommentReply(
    author: '${_object(json['user'])['nickname'] ?? ''}',
    content: '${json['content'] ?? ''}',
  );
}

class SongComment {
  const SongComment({
    required this.id,
    required this.content,
    required this.author,
    this.userId = 0,
    this.avatarUrl,
    this.time = 0,
    this.location,
    this.liked = false,
    this.likedCount = 0,
    this.replies = const [],
  });
  final int id, userId, time, likedCount;
  final String content, author;
  final String? avatarUrl, location;
  final bool liked;
  final List<CommentReply> replies;

  factory SongComment.fromJson(Map<String, dynamic> json) {
    final user = _object(json['user']);
    return SongComment(
      id: _number(json['commentId']),
      content: '${json['content'] ?? ''}',
      author: '${user['nickname'] ?? ''}',
      userId: _number(user['userId']),
      avatarUrl: normalizedArtworkUrl(user['avatarUrl'] as String?),
      time: _number(json['time']),
      location: _object(json['ipLocation'])['location'] as String?,
      liked: json['liked'] == true,
      likedCount: _number(json['likedCount']).clamp(0, 1 << 53),
      replies: [
        for (final reply
            in json['beReplied'] is List ? json['beReplied'] as List : const [])
          if (reply is Map<String, dynamic> &&
              '${reply['content'] ?? ''}'.isNotEmpty)
            CommentReply.fromJson(reply),
      ],
    );
  }

  SongComment withLike(bool value, int count) => SongComment(
    id: id,
    content: content,
    author: author,
    userId: userId,
    avatarUrl: avatarUrl,
    time: time,
    location: location,
    liked: value,
    likedCount: count.clamp(0, 1 << 53),
    replies: replies,
  );
}

class SongCommentPage {
  const SongCommentPage({
    required this.total,
    required this.more,
    required this.hot,
    required this.latest,
    required this.receivedCount,
  });
  final int total, receivedCount;
  final bool more;
  final List<SongComment> hot, latest;

  factory SongCommentPage.fromJson(Map<String, dynamic> json) {
    List<SongComment> comments(Object? values) => values is List
        ? [
            for (final value in values)
              if (value is Map<String, dynamic> &&
                  _number(value['commentId']) > 0)
                SongComment.fromJson(value),
          ]
        : const [];
    final latest = json['comments'];
    return SongCommentPage(
      total: _number(json['total']),
      more: json['more'] == true,
      hot: comments(json['hotComments']),
      latest: comments(latest),
      receivedCount: latest is List ? latest.length : 0,
    );
  }
}
