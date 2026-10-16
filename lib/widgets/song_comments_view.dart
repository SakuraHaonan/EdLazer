import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/song_comments.dart';
import '../l10n/app_localizations.dart';
import '../screens/login_page.dart';
import '../state/app_state.dart';
import '../state/song_comments_controller.dart';
import '../theme/app_palette.dart';
import '../theme/paper_widgets.dart';
import '../utils/artwork.dart';
import 'accessible_controls.dart';
import 'animated_notice.dart';
import 'artwork_image.dart';
import 'interaction_feedback.dart';

Future<void> showSongComments(
  BuildContext context, {
  required AppState state,
  required Track track,
  required SongCommentsController controller,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: context.colors.ivoryLight,
  shape: const RoundedRectangleBorder(),
  builder: (context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .92,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TrText('评论', style: context.type.subheading),
                    const SizedBox(height: 4),
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.captionMuted,
                    ),
                  ],
                ),
              ),
              AccessibleIconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        const Hairline(),
        Expanded(
          child: SongCommentsView(
            state: state,
            track: track,
            controller: controller,
          ),
        ),
      ],
    ),
  ),
);

/// Lazy rows, pagination and reactions listen only to the comment controller.
class SongCommentsView extends StatefulWidget {
  const SongCommentsView({
    super.key,
    required this.state,
    required this.track,
    required this.controller,
  });
  final AppState state;
  final Track track;
  final SongCommentsController controller;
  @override
  State<SongCommentsView> createState() => _SongCommentsViewState();
}

class _SongCommentsViewState extends State<SongCommentsView> {
  final _scroll = ScrollController();
  late int _accountId;
  SongCommentsController get _comments => widget.controller;

  @override
  void initState() {
    super.initState();
    _accountId = widget.state.user.userId;
    widget.state.addListener(_accountChanged);
    _scroll.addListener(_maybeLoadMore);
    _scheduleBind();
  }

  void _scheduleBind() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(
      _comments.openSong(widget.track.id, accountId: widget.state.user.userId),
    );
  });

  @override
  void didUpdateWidget(covariant SongCommentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_accountChanged);
      widget.state.addListener(_accountChanged);
    }
    if (oldWidget.track.id != widget.track.id ||
        oldWidget.controller != widget.controller) {
      _scheduleBind();
    }
    _accountChanged();
  }

  void _accountChanged() {
    final id = widget.state.user.userId;
    if (id == _accountId) return;
    _accountId = id;
    _scheduleBind();
  }

  void _maybeLoadMore() {
    if (_scroll.positions.length == 1 &&
        _scroll.position.extentAfter < 320 &&
        _comments.trackId == widget.track.id &&
        _comments.error == null) {
      unawaited(_comments.loadMore());
    }
  }

  Future<void> _like(int id) async {
    if (!widget.state.signedIn) {
      await showLoginDialog(context, widget.state);
      if (!mounted || !widget.state.signedIn) return;
      await _comments.openSong(
        widget.track.id,
        accountId: widget.state.user.userId,
      );
      if (!mounted) return;
    }
    await _comments.toggleLike(id);
  }

  Future<void> _loginAgain() async {
    final previous = widget.state.user;
    await showLoginDialog(context, widget.state);
    if (!mounted ||
        !widget.state.signedIn ||
        identical(previous, widget.state.user)) {
      return;
    }
    _comments.dismissActionError();
    await _comments.refresh();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _comments,
    builder: (context, _) {
      final bound = _comments.trackId == widget.track.id;
      final hot = bound ? _comments.hot : const <SongComment>[];
      final latest = bound ? _comments.latest : const <SongComment>[];
      final initialLoading = !bound || _comments.loading && _comments.isEmpty;
      final empty = bound && _comments.isEmpty;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: TrText(
                        initialLoading ? '正在加载评论…' : '${_comments.total} 条评论',
                        key: ValueKey((initialLoading, _comments.total)),
                        style: context.type.captionMuted,
                      ),
                    ),
                  ),
                ),
                AccessibleIconButton(
                  tooltip: '刷新评论',
                  onPressed:
                      !bound ||
                          _comments.loading ||
                          _comments.loadingMore ||
                          _comments.reacting ||
                          _comments.unsupported
                      ? null
                      : () => unawaited(_comments.refresh()),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: AnimatedNotice(
              message: _comments.actionError,
              onDismiss: _comments.dismissActionError,
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topLeft,
            child: _comments.loginRequired
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextButton(
                        onPressed: () => unawaited(_loginAgain()),
                        child: const TrText('重新登录'),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Expanded(
            child: TweenAnimationBuilder<double>(
              key: ValueKey((widget.track.id, initialLoading, empty)),
              tween: Tween(begin: 0, end: 1),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, (1 - value) * 10),
                  child: child,
                ),
              ),
              child: initialLoading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : empty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 36,
                              color: context.colors.cloudMedium,
                            ),
                            const SizedBox(height: 16),
                            TrText(
                              _comments.unsupported
                                  ? '这首歌暂不支持查看评论'
                                  : _comments.error ?? '这首歌还没有评论',
                              textAlign: TextAlign.center,
                              style: context.type.bodySmMuted,
                            ),
                            if (_comments.error != null)
                              TextButton(
                                onPressed: () => unawaited(_comments.retry()),
                                child: const TrText('重试'),
                              ),
                          ],
                        ),
                      ),
                    )
                  : CustomScrollView(
                      controller: _scroll,
                      key: const PageStorageKey('song-comments'),
                      slivers: [
                        if (hot.isNotEmpty) ...[
                          const SliverPadding(
                            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                            sliver: SliverToBoxAdapter(
                              child: SectionHeading('热门评论'),
                            ),
                          ),
                          _rows(hot),
                        ],
                        if (latest.isNotEmpty) ...[
                          const SliverPadding(
                            padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                            sliver: SliverToBoxAdapter(
                              child: SectionHeading('最新评论'),
                            ),
                          ),
                          _rows(latest),
                        ],
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                            child: Center(
                              child: _comments.loadingMore
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : _comments.error != null
                                  ? Column(
                                      children: [
                                        TrText(
                                          _comments.error!,
                                          style: context.type.captionMuted,
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              unawaited(_comments.retry()),
                                          child: const TrText('重试'),
                                        ),
                                      ],
                                    )
                                  : _comments.hasMore
                                  ? TextButton(
                                      onPressed: () =>
                                          unawaited(_comments.loadMore()),
                                      child: const TrText('加载更多评论'),
                                    )
                                  : TrText(
                                      '已显示全部评论',
                                      style: context.type.captionMuted,
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      );
    },
  );

  Widget _rows(List<SongComment> comments) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    sliver: SliverList.builder(
      itemCount: comments.length,
      itemBuilder: (context, index) => _CommentRow(
        key: ValueKey(comments[index].id),
        comment: comments[index],
        pending: _comments.isLiking(comments[index].id),
        signedIn: widget.state.signedIn,
        onLike: () => unawaited(_like(comments[index].id)),
      ),
    ),
  );

  @override
  void dispose() {
    widget.state.removeListener(_accountChanged);
    _scroll.dispose();
    super.dispose();
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({
    super.key,
    required this.comment,
    required this.pending,
    required this.signedIn,
    required this.onLike,
  });
  final SongComment comment;
  final bool pending;
  final bool signedIn;
  final VoidCallback onLike;

  @override
  Widget build(BuildContext context) {
    final color = comment.liked
        ? context.colors.clayDeep
        : context.colors.cloudDark;
    final avatar = enlargedArtworkUrl(comment.avatarUrl, sizePx: 96);
    final fallback = ColoredBox(
      color: context.colors.oatWarm,
      child: Icon(
        Icons.person_outline_rounded,
        color: context.colors.cloudDark,
        size: 20,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: SizedBox.square(
                  dimension: 36,
                  child: avatar == null
                      ? fallback
                      : Image(
                          image: ResizeImage(
                            ArtworkImage(avatar),
                            width: 96,
                            height: 96,
                          ),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => fallback,
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      comment.author.isEmpty
                          ? context.tr('匿名用户')
                          : comment.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.captionStrong,
                    ),
                    if (comment.time > 0) ...[
                      const SizedBox(height: 3),
                      Text(
                        [
                          MaterialLocalizations.of(context).formatMediumDate(
                            DateTime.fromMillisecondsSinceEpoch(comment.time),
                          ),
                          if (comment.location?.isNotEmpty ?? false)
                            comment.location!,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.captionMuted,
                      ),
                    ],
                  ],
                ),
              ),
              AccessibleTooltip(
                message: comment.liked
                    ? '取消点赞'
                    : signedIn
                    ? '点赞'
                    : '登录后点赞',
                child: Semantics(
                  toggled: comment.liked,
                  child: TextButton(
                    onPressed: pending ? null : feedbackAction(context, onLike),
                    style: TextButton.styleFrom(
                      foregroundColor: color,
                      disabledForegroundColor: color.withValues(alpha: .65),
                      shape: const RoundedRectangleBorder(),
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      enableFeedback: false,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(
                                scale: animation,
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              ),
                          child: Icon(
                            comment.liked
                                ? Icons.thumb_up_rounded
                                : Icons.thumb_up_outlined,
                            key: ValueKey(comment.liked),
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 6),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          child: Text(
                            MaterialLocalizations.of(
                              context,
                            ).formatDecimal(comment.likedCount),
                            key: ValueKey(comment.likedCount),
                            style: context.type.caption.copyWith(color: color),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(
            comment.content,
            style: context.type.bodySm.copyWith(height: 1.7),
          ),
          for (final reply in comment.replies)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.colors.ivoryLight,
                  border: Border(
                    left: BorderSide(color: context.colors.stone, width: 2),
                  ),
                ),
                child: Text(
                  '${reply.author}：${reply.content}',
                  style: context.type.bodySmMuted.copyWith(height: 1.6),
                ),
              ),
            ),
          const SizedBox(height: 20),
          const Hairline(),
        ],
      ),
    );
  }
}
