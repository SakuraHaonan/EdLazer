package dev.naominet.lazer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

import dev.naominet.lazer.gateway.AudioQuality
import dev.naominet.lazer.gateway.GatewayHttpException
import dev.naominet.lazer.gateway.GatewaySessionStore
import dev.naominet.lazer.gateway.NeteaseMusicGateway
import dev.naominet.lazer.gateway.SONG_COMMENT_CONTENT_LIMIT
import dev.naominet.lazer.gateway.model.Artist
import dev.naominet.lazer.gateway.model.LISTEN_TOGETHER_SHARE_FALLBACK_SONG_ID
import dev.naominet.lazer.gateway.model.ListenTogetherParticipant
import dev.naominet.lazer.gateway.model.ListenTogetherPlaybackState
import dev.naominet.lazer.gateway.model.ListenTogetherPlaylistVersion
import dev.naominet.lazer.gateway.model.ListenTogetherRoomKind
import dev.naominet.lazer.gateway.model.Playlist
import dev.naominet.lazer.gateway.model.QrCheckResponse
import dev.naominet.lazer.gateway.model.Song
import dev.naominet.lazer.gateway.model.SongComment
import dev.naominet.lazer.gateway.model.UserProfile
import dev.naominet.lazer.gateway.model.incrementListenTogetherVersion
import io.ktor.util.date.getTimeMillis
import dev.naominet.lazer.gateway.model.isListenTogetherClosed
import dev.naominet.lazer.gateway.model.listenTogetherCreatedRoomId
import dev.naominet.lazer.gateway.model.listenTogetherPlaybackState
import dev.naominet.lazer.gateway.model.listenTogetherRoomStatus
import dev.naominet.lazer.gateway.model.mergeListenTogetherVersions
import dev.naominet.lazer.gateway.model.parseListenTogetherInvite
import dev.naominet.lazer.gateway.model.requireListenTogetherSuccess
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.abs

enum class LazerRootDestination(private val labelKey: String, val motionIndex: Int) {
    HOME("nav.today", 0),
    SEARCH("nav.search", 1),
    LIBRARY("nav.library", 2),
    ME("nav.me", 3);

    val label: String get() = tr(labelKey)
}

enum class LazerLoginMethod(private val labelKey: String) {
    CAPTCHA("login.method.captcha"),
    PASSWORD("login.method.password"),
    QR_CODE("login.method.qr"),
    COOKIE("login.method.cookie");

    val label: String get() = tr(labelKey)
}

enum class LazerQrLoginState {
    IDLE,
    CREATING,
    WAITING_FOR_SCAN,
    WAITING_FOR_CONFIRMATION,
    EXPIRED,
    ERROR,
}

private data class LazerCachedSignedInContent(
    val userPlaylists: List<LazerPlaylist>,
    val likedSongIds: Set<Long>,
)

private data class LazerCachedBootstrap(
    val hasSavedSession: Boolean,
    val featuredPlaylists: List<LazerPlaylist>,
    val homeTracks: List<LazerTrack>,
    val profile: UserProfile?,
    val userPlaylists: List<LazerPlaylist>,
    val likedSongIds: Set<Long>,
)

private const val MESSAGE_BANNER_DURATION_MILLIS = 15_000L
internal const val LAZER_LIBRARY_TIP_COUNT = 10

fun nextLazerLibraryTipIndex(current: Int): Int =
    (current + 1).mod(LAZER_LIBRARY_TIP_COUNT)

/** How the listen-together room is reachable right now, which is what the shared badge reports. */
enum class LazerListenTogetherConnection {
    CONNECTING,
    CONNECTED,
    RECONNECTING,
}

data class LazerListenTogetherState(
    val roomId: String,
    val inviterId: Long,
    val isHost: Boolean,
    val connection: LazerListenTogetherConnection = LazerListenTogetherConnection.CONNECTING,
    val participants: List<ListenTogetherParticipant> = emptyList(),
    val remoteTrackId: Long? = null,
)

/** One page of song comments, accumulated so the sheet can keep its scroll position. */
data class LazerSongCommentState(
    val songId: Long = 0,
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val failed: Boolean = false,
    val total: Int = 0,
    val hasMore: Boolean = false,
    val hotComments: List<SongComment> = emptyList(),
    val comments: List<SongComment> = emptyList(),
)

private data class LazerListenTogetherPlaybackKey(
    val trackId: Long?,
    val isPlaying: Boolean,
)

private const val LISTEN_TOGETHER_REFRESH_MILLIS = 3_000L
private const val LISTEN_TOGETHER_HEARTBEAT_MILLIS = 10_000L
private const val LISTEN_TOGETHER_SEEK_TOLERANCE_MILLIS = 4_000L
private const val COMMENT_PAGE_SIZE = 20

class LazerGatewayController(private val device: LazerDevice) {
    private val cache: LazerLibraryCache = device.cache
    val player: LazerPlayer = device.player
    val host: LazerPlatformHost = device.host

    val settings: LazerSettingsStore = device.settings
    private val gatewaySessionStore: GatewaySessionStore = device.sessionStore
    private val gateway = device.gateway ?: NeteaseMusicGateway(
        sessionStore = gatewaySessionStore,
    )
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var bootstrapJob: Job? = null
    private var searchJob: Job? = null
    private var playlistJob: Job? = null
    private var artistJob: Job? = null
    private var lyricJob: Job? = null
    private var qrLoginJob: Job? = null
    private var postLoginSyncJob: Job? = null
    private var maintenanceJob: Job? = null
    private var playlistRequestGeneration = 0L
    private var hasCompletedBootstrap = false

    var destination by mutableStateOf(LazerRootDestination.HOME)
        private set
    var libraryTipIndex by mutableIntStateOf(-1)
        private set
    var isSettingsVisible by mutableStateOf(false)
        private set
    var isAboutVisible by mutableStateOf(false)
        private set
    var isDark by mutableStateOf(settings.isDark)
        private set
    var useSystemMonetColors by mutableStateOf(settings.useSystemMonetColors)
        private set
    var palette by mutableStateOf(settings.palette)
        private set
    var backgroundImage by mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null)
        private set
    var backgroundMode by mutableStateOf(settings.backgroundMode)
        private set
    var backgroundAlpha by mutableStateOf(settings.backgroundAlpha)
        private set
    var backgroundImageBlurEnabled by mutableStateOf(settings.backgroundImageBlurEnabled)
        private set
    var backgroundImageBlurIntensity by mutableStateOf(settings.backgroundImageBlurIntensity)
        private set
    var style by mutableStateOf(settings.style)
        private set
    val themeEngine: LazerThemeEngine get() = style.themeEngine
    var language by mutableStateOf(settings.language)
        private set
    var lyricFollowDelayMillis by mutableStateOf(settings.lyricFollowDelayMillis)
        private set
    var lyricAnimationSpeed by mutableStateOf(settings.lyricAnimationSpeed)
        private set
    var wordLyricsEnabled by mutableStateOf(settings.wordLyricsEnabled)
        private set
    var lyricGlowEnabled by mutableStateOf(settings.lyricGlowEnabled)
        private set
    var lyricFontSizeSp by mutableIntStateOf(settings.lyricFontSizeSp)
        private set
    var showFullLyrics by mutableStateOf(settings.showFullLyrics)
        private set
    var audioQuality by mutableStateOf(settings.audioQuality)
        private set
    var replayGainMode by mutableStateOf(settings.replayGainMode)
        private set
    var exclusiveAudio by mutableStateOf(settings.exclusiveAudio)
        private set
    var equalizer by mutableStateOf(settings.equalizer)
        private set
    private var equalizerPreviewActive = false
    var playbackInterface by mutableStateOf(settings.playbackInterface)
        private set
    var audioReactiveLevels by mutableStateOf(settings.audioReactiveLevels)
        private set
    var hapticsEnabled by mutableStateOf(settings.hapticsEnabled)
        private set
    val independentPlayback: Boolean
        get() = playbackInterface == LazerPlaybackInterface.INDEPENDENT
    var currentUser by mutableStateOf<UserProfile?>(null)
        private set
    var featuredPlaylists by mutableStateOf<List<LazerPlaylist>>(emptyList())
        private set
    var homeTracks by mutableStateOf<List<LazerTrack>>(emptyList())
        private set
    var userPlaylists by mutableStateOf<List<LazerPlaylist>>(emptyList())
        private set
    var likedSongIds by mutableStateOf<Set<Long>>(emptySet())
        private set
    var activePlaylist by mutableStateOf<LazerPlaylist?>(null)
        private set
    var activePlaylistTracks by mutableStateOf<List<LazerTrack>>(emptyList())
        private set
    var activeArtist by mutableStateOf<Artist?>(null)
        private set
    var activeArtistTracks by mutableStateOf<List<LazerTrack>>(emptyList())
        private set
    var isArtistLoading by mutableStateOf(false)
        private set
    var isLoading by mutableStateOf(false)
        private set
    var isPlaylistLoading by mutableStateOf(false)
        private set
    private var bannerMessage by mutableStateOf<String?>(null)
    private var messageDismissJob: Job? = null
    var message: String?
        get() = bannerMessage
        private set(value) {
            // Every notification gets a fresh timeout, even when its text repeats.
            messageDismissJob?.cancel()
            messageDismissJob = null
            bannerMessage = value
            if (value != null) {
                messageDismissJob = scope.launch {
                    delay(MESSAGE_BANNER_DURATION_MILLIS)
                    bannerMessage = null
                    messageDismissJob = null
                }
            }
        }

    var searchQuery by mutableStateOf("")
        private set
    var searchResults by mutableStateOf<List<LazerTrack>>(emptyList())
        private set
    var isSearching by mutableStateOf(false)
        private set

    var lyrics by mutableStateOf<List<TimedLyricLine>>(emptyList())
        private set
    var lyricsLoading by mutableStateOf(false)
        private set
    private var lyricTrackId: Long? = null
    var lyricsMessage by mutableStateOf<String?>(null)
        private set

    var isLoginVisible by mutableStateOf(false)
        private set
    var loginMethod by mutableStateOf(LazerLoginMethod.CAPTCHA)
        private set
    var loginPhone by mutableStateOf("")
        private set
    var loginCaptcha by mutableStateOf("")
        private set
    var loginPassword by mutableStateOf("")
        private set
    var loginCookie by mutableStateOf("")
        private set
    var loginMessage by mutableStateOf<String?>(null)
        private set
    var isSendingCaptcha by mutableStateOf(false)
        private set
    var isSubmittingLogin by mutableStateOf(false)
        private set
    var captchaSent by mutableStateOf(false)
        private set
    var qrImageData by mutableStateOf<String?>(null)
        private set
    var qrState by mutableStateOf(LazerQrLoginState.IDLE)
        private set

    val currentSessionCookie: String?
        get() = gateway.sessionCookie?.takeIf(String::isNotBlank)

    var isListenTogetherVisible by mutableStateOf(false)
        private set
    var listenTogether by mutableStateOf<LazerListenTogetherState?>(null)
        private set
    var isListenTogetherBusy by mutableStateOf(false)
        private set
    var listenTogetherError by mutableStateOf<String?>(null)
        private set

    private var listenTogetherActionJob: Job? = null
    private var listenTogetherRefreshJob: Job? = null
    private var listenTogetherSequence = 1L
    private var listenTogetherPlaylistState: ListenTogetherPlaybackState? = null
    private var listenTogetherVersions: List<ListenTogetherPlaylistVersion> = emptyList()
    private var listenTogetherQueue: List<LazerTrack> = emptyList()
    private var lastListenTogetherRoomQueueIds: List<Long> = emptyList()
    private var lastReportedQueueIds: List<Long> = emptyList()
    private var lastAppliedRemoteSequence = -1L
    private var lastStablePlayback: LazerListenTogetherPlaybackKey? = null
    private var pendingRemotePlayback: LazerListenTogetherPlaybackKey? = null
    private var pendingListenTogetherInvitation: String? = null
    private var lastHeartbeatMillis = 0L

    val listenTogetherShareUrl: String?
        get() {
            val room = listenTogether ?: return null
            val songId = player.snapshot.value.track?.takeIf { it.source == LazerTrackSource.GatewaySong }?.id
                ?: room.remoteTrackId
                ?: LISTEN_TOGETHER_SHARE_FALLBACK_SONG_ID
            return dev.naominet.lazer.gateway.model.ListenTogetherInvite(
                roomId = room.roomId,
                inviterId = room.inviterId,
            ).shareUrl(songId)
        }

    fun openListenTogether() {
        isListenTogetherVisible = true
        listenTogetherError = null
    }

    fun closeListenTogether() {
        isListenTogetherVisible = false
        listenTogetherError = null
        pendingListenTogetherInvitation = null
    }

    var isQueueSheetVisible by mutableStateOf(false)
        private set

    /**
     * The room's shared order. A room decides what everyone hears, so while one is open the queue
     * card reads this list instead of the local one and offers no edits.
     */
    var listenTogetherRoomQueue by mutableStateOf<List<LazerTrack>>(emptyList())
        private set

    fun openQueueSheet() {
        isQueueSheetVisible = true
    }

    fun closeQueueSheet() {
        isQueueSheetVisible = false
    }

    fun setPlayMode(mode: LazerPlayMode) = player.setPlayMode(mode)

    fun playQueueAt(position: Int) = player.playAt(position)

    fun removeFromQueue(position: Int) = player.removeAt(position)

    fun moveInQueue(from: Int, to: Int) = player.moveTrack(from, to)

    var isCommentSheetVisible by mutableStateOf(false)
        private set
    var comments by mutableStateOf(LazerSongCommentState())
        private set

    private var commentJob: Job? = null
    private val commentPages = mutableMapOf<Long, LazerSongCommentState>()

    /** Paints the cached page first, then asks the service for the same page again. */
    fun openSongComments() {
        val track = player.snapshot.value.track ?: return
        if (track.source is LazerTrackSource.LocalFile) {
            message = tr("player.local.online_only")
            return
        }
        val songId = track.id
        isCommentSheetVisible = true
        val cached = commentPages[songId]
        comments = cached ?: LazerSongCommentState(songId = songId, loading = true)
        requestSongComments(songId, offset = 0, append = false)
    }

    fun closeSongComments() {
        isCommentSheetVisible = false
        commentJob?.cancel()
        cancelReply()
    }

    fun loadMoreSongComments() {
        val state = comments
        if (state.songId <= 0L || !state.hasMore || state.loading || state.loadingMore) return
        requestSongComments(state.songId, offset = state.comments.size, append = true)
    }

    fun retrySongComments() {
        val songId = comments.songId
        if (songId <= 0L) return
        requestSongComments(songId, offset = 0, append = false)
    }

    /** The comment the composer is answering, or null while the composer is hidden. */
    var replyTarget by mutableStateOf<SongComment?>(null)
        private set
    var replyDraft by mutableStateOf("")
        private set
    var isReplySending by mutableStateOf(false)
        private set
    var replyError by mutableStateOf<String?>(null)
        private set

    private var replyJob: Job? = null

    fun startReply(comment: SongComment) {
        if (currentUser == null) {
            openLogin()
            return
        }
        replyTarget = comment
        replyError = null
    }

    fun cancelReply() {
        replyTarget = null
        replyDraft = ""
        replyError = null
    }

    fun updateReplyDraft(value: String) {
        replyDraft = value.take(SONG_COMMENT_CONTENT_LIMIT)
    }

    fun sendReply() {
        val songId = comments.songId
        val target = replyTarget ?: return
        val content = replyDraft.trim()
        if (songId <= 0L || content.isEmpty() || isReplySending) return
        isReplySending = true
        replyError = null
        replyJob?.cancel()
        replyJob = scope.launch {
            val result = runCatching { gateway.replyToSongComment(songId, target.commentId, content) }
            isReplySending = false
            result.fold(
                onSuccess = {
                    replyTarget = null
                    replyDraft = ""
                    message = tr("comment.reply_sent")
                    // Floor replies only show up in the parent's own summary, so re-read page one.
                    requestSongComments(songId, offset = 0, append = false)
                },
                onFailure = { error ->
                    if (error is CancellationException) throw error
                    replyError = tr("comment.reply_fail")
                },
            )
        }
    }

    /** Flips the like locally first, because a round trip per tap feels broken. */
    fun toggleCommentLiked(comment: SongComment) {
        val songId = comments.songId
        if (songId <= 0L) return
        if (currentUser == null) {
            openLogin()
            return
        }
        val wanted = !comment.liked
        patchComment(comment.commentId) { it.copy(liked = wanted, likedCount = likeCountAfter(comment, wanted)) }
        // Each like patches only its own comment, so they never need to cancel one another.
        scope.launch {
            runCatching { gateway.setSongCommentLiked(songId, comment.commentId, wanted) }.onFailure { error ->
                if (error is CancellationException) throw error
                patchComment(comment.commentId) { it.copy(liked = comment.liked, likedCount = comment.likedCount) }
                message = tr("comment.like_fail")
            }
        }
    }

    private fun likeCountAfter(comment: SongComment, liked: Boolean): Int =
        (comment.likedCount + if (liked) 1 else -1).coerceAtLeast(0)

    private fun patchComment(commentId: Long, transform: (SongComment) -> SongComment) {
        comments = comments.copy(
            hotComments = comments.hotComments.map { if (it.commentId == commentId) transform(it) else it },
            comments = comments.comments.map { if (it.commentId == commentId) transform(it) else it },
        )
    }

    private fun requestSongComments(songId: Long, offset: Int, append: Boolean) {
        if (songId <= 0L) return
        commentJob?.cancel()
        commentJob = scope.launch {
            comments = comments.copy(
                songId = songId,
                loading = !append && comments.comments.isEmpty(),
                loadingMore = append,
                failed = false,
            )
            val page = try {
                gateway.songComments(songId, limit = COMMENT_PAGE_SIZE, offset = offset)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isActive && comments.songId == songId) {
                    comments = comments.copy(loading = false, loadingMore = false, failed = true)
                }
                return@launch
            }
            val merged = LazerSongCommentState(
                songId = songId,
                total = page.total,
                hasMore = page.more,
                hotComments = if (offset == 0) page.hotComments else comments.hotComments,
                comments = if (append) comments.comments + page.comments else page.comments,
            )
            commentPages[songId] = merged
            // A newer request has already published by now if the sheet moved on to another song.
            if (comments.songId == songId) comments = merged
        }
    }

    fun createListenTogetherRoom(kind: ListenTogetherRoomKind) {
        if (player.snapshot.value.track?.source is LazerTrackSource.LocalFile ||
            player.currentQueue().any { it.source is LazerTrackSource.LocalFile }
        ) {
            message = tr("player.local.online_only")
            return
        }
        val user = currentUser
        if (user == null) {
            openLogin()
            return
        }
        listenTogetherActionJob?.cancel()
        listenTogetherActionJob = scope.launch {
            isListenTogetherBusy = true
            listenTogetherError = null
            runCatching {
                val response = when (kind) {
                    ListenTogetherRoomKind.Duo -> gateway.listenTogetherCreateRoom()
                    ListenTogetherRoomKind.Multi -> gateway.listenTogetherCreateMultiRoom(
                        songId = currentPlaybackTrack()?.id ?: error("no track to share"),
                        nextSongIds = upcomingTrackIds(),
                        playedTimeMillis = player.snapshot.value.positionMillis,
                    )
                }
                requireListenTogetherSuccess(response)
                val roomId = listenTogetherCreatedRoomId(response) ?: error("room id missing")
                requireListenTogetherSuccess(gateway.listenTogetherRoomCheck(roomId))
                listenTogether = LazerListenTogetherState(
                    roomId = roomId,
                    inviterId = user.userId,
                    isHost = true,
                )
                resetListenTogetherSession()
                runCatching { reportCurrentPlaybackToRoom(forceQueue = true) }
                startListenTogetherRefresh()
            }.onFailure { error ->
                if (error is CancellationException) throw error
                listenTogetherError = tr("listen_together.create_fail")
            }
            isListenTogetherBusy = false
        }
    }

    private fun currentPlaybackTrack(): LazerTrack? = player.snapshot.value.track

    /** Songs after the current one, which is what a multi-person room seeds its queue with. */
    private fun upcomingTrackIds(): List<Long> {
        val currentId = currentPlaybackTrack()?.id ?: return emptyList()
        val queue = listenTogetherQueue.ifEmpty { return emptyList() }
        val index = queue.indexOfFirst { it.id == currentId }
        if (index < 0) return emptyList()
        return queue.drop(index + 1)
            .filter { it.source == LazerTrackSource.GatewaySong }
            .map(LazerTrack::id)
            .distinct()
    }

    fun joinListenTogetherRoom(roomId: String, inviterId: Long) {
        joinListenTogether("$roomId $inviterId")
    }

    fun joinListenTogether(invitation: String) {
        if (player.snapshot.value.track?.source is LazerTrackSource.LocalFile ||
            player.currentQueue().any { it.source is LazerTrackSource.LocalFile }
        ) {
            message = tr("player.local.online_only")
            return
        }
        pendingListenTogetherInvitation = invitation
        isListenTogetherVisible = true
        if (!hasCompletedBootstrap) return
        if (currentUser == null) {
            openLogin()
            return
        }
        pendingListenTogetherInvitation = null
        val invite = parseListenTogetherInvite(invitation)
        if (invite == null) {
            listenTogetherError = tr("listen_together.invalid_invite")
            return
        }
        isListenTogetherVisible = true
        listenTogetherActionJob?.cancel()
        listenTogetherActionJob = scope.launch {
            isListenTogetherBusy = true
            listenTogetherError = null
            runCatching {
                requireListenTogetherSuccess(gateway.listenTogetherAccept(invite.roomId, invite.inviterId))
                requireListenTogetherSuccess(gateway.listenTogetherRoomCheck(invite.roomId))
                listenTogether = LazerListenTogetherState(
                    roomId = invite.roomId,
                    inviterId = invite.inviterId,
                    isHost = false,
                )
                resetListenTogetherSession()
                startListenTogetherRefresh()
            }.onFailure { error ->
                if (error is CancellationException) throw error
                listenTogetherError = tr("listen_together.join_fail")
            }
            isListenTogetherBusy = false
        }
    }

    fun endListenTogetherRoom() {
        val roomId = listenTogether?.roomId ?: return
        listenTogetherActionJob?.cancel()
        listenTogetherActionJob = scope.launch {
            isListenTogetherBusy = true
            listenTogetherError = null
            runCatching {
                requireListenTogetherSuccess(gateway.listenTogetherEnd(roomId))
            }.onSuccess {
                clearListenTogetherSession()
                isListenTogetherVisible = false
                message = tr("listen_together.ended")
            }.onFailure { error ->
                if (error is CancellationException) throw error
                listenTogetherError = tr("listen_together.end_fail")
            }
            isListenTogetherBusy = false
        }
    }

    /** Starts playback and remembers the queue order for any later Listen Together session. */
    fun play(queue: List<LazerTrack>, track: LazerTrack) {
        val requestedQueue = queue.ifEmpty { listOf(track) }.distinctBy(LazerTrack::id)
        if (listenTogether != null && requestedQueue.any { it.source is LazerTrackSource.LocalFile }) {
            message = tr("player.local.online_only")
            return
        }
        listenTogetherQueue = requestedQueue
        player.play(requestedQueue, track)
    }

    /** Replaces the current queue with files returned by the platform's document picker. */
    fun playLocalAudioFiles(files: List<LazerPickedAudioFile>) {
        if (files.isEmpty()) return
        if (listenTogether != null) {
            message = tr("player.local.online_only")
            return
        }
        val tracks = files
            .distinctBy(LazerPickedAudioFile::uri)
            .take(LazerPlaybackQueue.MAX_TRACKS)
            .map { file ->
                LazerTrack(
                    id = LazerLocalTrackIdentity.nextId(),
                    title = file.title.ifBlank { file.uri.substringAfterLast('/').ifBlank { "Audio file" } },
                    artist = file.artist,
                    album = file.album,
                    durationMillis = file.durationMillis.coerceAtLeast(0L),
                    coverUrl = file.coverUrl,
                    source = LazerTrackSource.LocalFile(file.uri),
                    replayGain = file.replayGain,
                    albumArtist = file.albumArtist,
                    genre = file.genre,
                    year = file.year,
                    trackNumber = file.trackNumber,
                    totalTracks = file.totalTracks,
                    discNumber = file.discNumber,
                    totalDiscs = file.totalDiscs,
                )
            }
        if (tracks.isEmpty()) return
        listenTogetherQueue = tracks
        player.play(tracks, tracks.first())
    }

    fun handleLocalAudioPickerResult(result: LazerLocalAudioPickerResult) {
        playLocalAudioFiles(result.files)
        if (result.failedFileCount > 0) {
            message = tr("player.local.import_failed")
        } else if (result.unsupportedFileCount > 0) {
            message = tr("player.local.unsupported")
        }
    }

    fun seekTo(positionMillis: Long) {
        player.seekTo(positionMillis)
        val snapshot = player.snapshot.value
        scope.launch {
            if (listenTogether != null) {
                runCatching { reportPlaybackCommand("SEEK", snapshot.copy(positionMillis = positionMillis)) }
            }
        }
    }

    private fun startListenTogetherRefresh() {
        listenTogetherRefreshJob?.cancel()
        listenTogetherRefreshJob = scope.launch {
            var missingRoomCount = 0
            while (isActive && listenTogether != null) {
                val room = listenTogether ?: break
                try {
                    val statusResponse = gateway.listenTogetherStatus()
                    if (isListenTogetherClosed(statusResponse)) {
                        clearListenTogetherSession()
                        message = tr("listen_together.closed_remote")
                        break
                    }
                    requireListenTogetherSuccess(statusResponse)
                    val status = listenTogetherRoomStatus(statusResponse)
                    if (status?.inRoom == false) {
                        missingRoomCount += 1
                        if (missingRoomCount >= 2) {
                            clearListenTogetherSession()
                            message = tr("listen_together.closed_remote")
                            break
                        }
                    } else {
                        missingRoomCount = 0
                    }
                    val playlistResponse = gateway.listenTogetherPlaylist(room.roomId)
                    if (isListenTogetherClosed(playlistResponse)) {
                        clearListenTogetherSession()
                        message = tr("listen_together.closed_remote")
                        break
                    }
                    requireListenTogetherSuccess(playlistResponse)
                    val remote = listenTogetherPlaybackState(playlistResponse)
                    if (remote != null) {
                        listenTogetherPlaylistState = remote
                        listenTogetherVersions = mergeListenTogetherVersions(
                            listenTogetherVersions,
                            remote.versions,
                        )
                        listenTogetherSequence = maxOf(listenTogetherSequence, remote.clientSequence + 1L)
                        applyRemotePlayback(remote)
                        // Naming the room order is only worth a request when the order itself moved.
                        if (remote.trackIds != lastListenTogetherRoomQueueIds) {
                            lastListenTogetherRoomQueueIds = remote.trackIds
                            // Naming the order only needs the rows a member can scroll through. Resolving a
                            // host's whole list would ask for hundreds of detail pages for songs nobody sees.
                            runCatching {
                                loadListenTogetherTracks(remote.trackIds.take(LazerPlaybackQueue.MAX_TRACKS))
                            }.onSuccess { listenTogetherRoomQueue = it }
                        }
                    }
                    listenTogether = room.copy(
                        connection = LazerListenTogetherConnection.CONNECTED,
                        participants = status?.participants ?: room.participants,
                        remoteTrackId = remote?.targetSongId?.takeIf { it > 0L } ?: room.remoteTrackId,
                    )

                    val now = getTimeMillis()
                    val snapshot = player.snapshot.value
                    val heartbeatTrack = snapshot.track
                    if (heartbeatTrack != null && now - lastHeartbeatMillis >= LISTEN_TOGETHER_HEARTBEAT_MILLIS) {
                        val heartbeat = gateway.listenTogetherHeartbeat(
                            roomId = room.roomId,
                            songId = heartbeatTrack.id,
                            playStatus = if (snapshot.isPlaying) "PLAY" else "PAUSE",
                            progress = snapshot.positionMillis,
                        )
                        if (isListenTogetherClosed(heartbeat)) {
                            clearListenTogetherSession()
                            message = tr("listen_together.closed_remote")
                            break
                        }
                        requireListenTogetherSuccess(heartbeat)
                        lastHeartbeatMillis = now
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    if (error is GatewayHttpException && error.statusCode == 488) {
                        clearListenTogetherSession()
                        message = tr("listen_together.closed_remote")
                        break
                    }
                    listenTogether = room.copy(connection = LazerListenTogetherConnection.RECONNECTING)
                }
                delay(LISTEN_TOGETHER_REFRESH_MILLIS)
            }
        }
    }

    private fun resetListenTogetherSession() {
        listenTogetherSequence = 1L
        listenTogetherPlaylistState = null
        listenTogetherVersions = emptyList()
        listenTogetherQueue = player.currentQueue()
        listenTogetherRoomQueue = emptyList()
        lastListenTogetherRoomQueueIds = emptyList()
        lastReportedQueueIds = emptyList()
        lastAppliedRemoteSequence = -1L
        pendingRemotePlayback = null
        lastHeartbeatMillis = 0L
    }

    private fun clearListenTogetherSession() {
        listenTogetherRefreshJob?.cancel()
        listenTogetherRefreshJob = null
        listenTogether = null
        resetListenTogetherSession()
    }

    private fun observeListenTogetherPlayback() {
        scope.launch {
            player.snapshot
                .map { snapshot ->
                    Triple(
                        LazerListenTogetherPlaybackKey(snapshot.track?.id, snapshot.isPlaying),
                        snapshot.isPreparing,
                        snapshot,
                    )
                }
                .distinctUntilChanged { old, new -> old.first == new.first && old.second == new.second }
                .collect { (key, preparing, snapshot) ->
                    if (preparing) return@collect
                    val previous = lastStablePlayback
                    lastStablePlayback = key
                    pendingRemotePlayback?.let { expected ->
                        if (expected == key) {
                            pendingRemotePlayback = null
                            return@collect
                        }
                    }
                    if (listenTogether == null || key.trackId == null) return@collect
                    when {
                        previous?.trackId != key.trackId -> runCatching {
                            reportPlaybackCommand("GOTO", snapshot, forceQueue = true)
                        }
                        previous.isPlaying != key.isPlaying -> runCatching {
                            reportPlaybackCommand(
                                if (key.isPlaying) "PLAY" else "PAUSE",
                                snapshot,
                            )
                        }
                    }
                }
        }
    }

    private suspend fun reportCurrentPlaybackToRoom(forceQueue: Boolean) {
        val snapshot = player.snapshot.value
        if (snapshot.track != null) reportPlaybackCommand("GOTO", snapshot, forceQueue)
    }

    private suspend fun reportPlaybackCommand(
        commandType: String,
        snapshot: LazerPlaybackSnapshot,
        forceQueue: Boolean = false,
    ) {
        val room = listenTogether ?: return
        val track = snapshot.track ?: return
        if (track.source is LazerTrackSource.LocalFile) return
        val queue = listenTogetherQueue.ifEmpty { listOf(track) }
            .filter { it.source == LazerTrackSource.GatewaySong }
        if (queue.isEmpty()) return
        val queueIds = queue.map(LazerTrack::id).distinct()
        if (forceQueue || queueIds != lastReportedQueueIds) {
            val userId = currentUser?.userId ?: return
            val remoteState = listenTogetherPlaylistState
            val versions = incrementListenTogetherVersion(listenTogetherVersions, userId)
            requireListenTogetherSuccess(
                gateway.listenTogetherSyncList(
                    roomId = room.roomId,
                    commandType = "REPLACE",
                    versions = versions,
                    playMode = remoteState?.playMode ?: "ORDER_LOOP",
                    anchorSongId = null,
                    anchorPosition = -1,
                    randomList = queueIds,
                    displayList = queueIds,
                ),
            )
            listenTogetherVersions = versions
            lastReportedQueueIds = queueIds
            delay(400L)
        }
        val formerSongId = listenTogetherPlaylistState?.targetSongId?.takeIf { it > 0L } ?: -1L
        requireListenTogetherSuccess(
            gateway.listenTogetherPlayCommand(
                roomId = room.roomId,
                commandType = commandType,
                progress = snapshot.positionMillis,
                playStatus = if (snapshot.isPlaying) "PLAY" else "PAUSE",
                formerSongId = formerSongId,
                targetSongId = track.id,
                clientSeq = listenTogetherSequence++,
            ),
        )
    }

    private suspend fun applyRemotePlayback(remote: ListenTogetherPlaybackState) {
        val targetId = remote.targetSongId.takeIf { it > 0L } ?: return
        if (remote.clientSequence <= lastAppliedRemoteSequence) return
        val shouldPlay = remote.playStatus.equals("PLAY", ignoreCase = true)
        val local = player.snapshot.value
        val alreadyAligned = local.track?.id == targetId &&
            local.isPlaying == shouldPlay &&
            abs(local.positionMillis - remote.progressMillis) < LISTEN_TOGETHER_SEEK_TOLERANCE_MILLIS
        lastAppliedRemoteSequence = remote.clientSequence
        if (alreadyAligned) return

        pendingRemotePlayback = LazerListenTogetherPlaybackKey(targetId, shouldPlay)
        if (local.track?.id != targetId) {
            val ids = remote.trackIds.ifEmpty { listOf(targetId) }
            val tracks = loadListenTogetherTracks(ids)
            val target = tracks.firstOrNull { it.id == targetId } ?: return
            listenTogetherQueue = tracks
            lastReportedQueueIds = ids
            player.play(

                queue = tracks,
                track = target,
                startPlaying = shouldPlay,
                positionMillis = remote.progressMillis,
            )
            return
        }

        if (abs(local.positionMillis - remote.progressMillis) >= LISTEN_TOGETHER_SEEK_TOLERANCE_MILLIS &&
            remote.commandType.uppercase() in setOf("GOTO", "SEEK")
        ) {
            player.seekTo(remote.progressMillis)
        }
        when {
            shouldPlay && !local.isPlaying -> player.resume()
            !shouldPlay && local.isPlaying -> player.pause()
            else -> pendingRemotePlayback = null
        }
    }

    private suspend fun loadListenTogetherTracks(ids: List<Long>): List<LazerTrack> {
        val known = (listenTogetherQueue + homeTracks + activePlaylistTracks + activeArtistTracks)
            .associateBy(LazerTrack::id)
            .toMutableMap()
        ids.filterNot(known::containsKey).chunked(200).forEach { missing ->
            gateway.songDetails(missing).songs.map(::toLazerTrack).forEach { known[it.id] = it }
        }
        return ids.mapNotNull(known::get).distinctBy(LazerTrack::id)
    }

    init {
        LazerI18n.switchLanguage(language)
        observeListenTogetherPlayback()
        // The player starts from its own defaults, so the saved audio choices have to be handed over
        // once before the first track rather than only when the listener changes them.
        player.updateExclusiveAudio(exclusiveAudio)
        player.updatePlaybackInterface(playbackInterface == LazerPlaybackInterface.SYSTEM_MEDIA)
        scope.launch {
            loadLazerTranslations()
            loadBackgroundImage()
            bootstrap()
        }
    }

    fun updatePalette(value: LazerPalette) {
        palette = value
        settings.palette = value
    }

    fun updateBackgroundAlpha(value: Float) {
        backgroundAlpha = value.coerceIn(0f, 1f)
        settings.backgroundAlpha = backgroundAlpha
    }

    fun updateBackgroundMode(value: LazerBackgroundMode) {
        backgroundMode = value
        settings.backgroundMode = value
    }

    fun updateBackgroundImageBlurEnabled(enabled: Boolean) {
        backgroundImageBlurEnabled = enabled
        settings.backgroundImageBlurEnabled = enabled
    }

    fun updateBackgroundImageBlurIntensity(value: Float) {
        backgroundImageBlurIntensity = normalizeBackgroundImageBlurIntensity(value)
        settings.backgroundImageBlurIntensity = backgroundImageBlurIntensity
    }

    private suspend fun loadBackgroundImage() {
        val path = settings.backgroundImagePath ?: return
        backgroundImage = withContext(Dispatchers.Default) {
            runCatching { host.decodeImageFile(path) }.getOrNull()
        }
    }

    /** Copies the picked image into app storage and decodes it as the new background. */
    fun setBackgroundImage(source: String) {
        scope.launch {
            val stored = withContext(Dispatchers.Default) {
                runCatching { host.importImageFile(source, BACKGROUND_IMAGE_FILE) }
                    .onFailure { host.log("background load failed", it) }
                    .getOrNull()
            } ?: return@launch
            val decoded = withContext(Dispatchers.Default) {
                runCatching { host.decodeImageFile(stored) }.getOrNull()
            }
            if (decoded != null) {
                backgroundImage = decoded
                settings.backgroundImagePath = stored
                updateBackgroundMode(LazerBackgroundMode.IMAGE)
            }
        }
    }

    fun clearBackgroundImage() {
        backgroundImage = null
        val stored = settings.backgroundImagePath
        settings.backgroundImagePath = null
        if (backgroundMode == LazerBackgroundMode.IMAGE) {
            updateBackgroundMode(LazerBackgroundMode.SOLID)
        }
        stored?.let { path ->
            scope.launch { runCatching { host.deleteImportedImage(path) } }
        }
    }

    val isSignedIn: Boolean get() = currentUser != null

    fun selectDestination(value: LazerRootDestination) {
        if (value == LazerRootDestination.LIBRARY && destination != LazerRootDestination.LIBRARY) {
            libraryTipIndex = nextLazerLibraryTipIndex(libraryTipIndex)
        }
        destination = value
        isSettingsVisible = false
        isAboutVisible = false
        closeArtist()
        closePlaylist()
        message = null
    }

    fun openSettings() {
        isSettingsVisible = true
    }

    fun closeSettings() {
        isSettingsVisible = false
        isAboutVisible = false
    }

    fun openAbout() {
        isAboutVisible = true
    }

    fun closeAbout() {
        isAboutVisible = false
    }

    fun toggleTheme() {
        isDark = !isDark
        settings.isDark = isDark
    }

    fun updateUseSystemMonetColors(enabled: Boolean) {
        useSystemMonetColors = enabled
        settings.useSystemMonetColors = enabled
    }

    fun updateStyle(value: LazerStyle) {
        style = value
        settings.style = value
    }

    fun updateLanguage(value: LazerLanguage) {
        if (language == value) return
        language = value
        LazerI18n.switchLanguage(value)
        settings.language = value
        message = null
        loginMessage = null
    }

    fun updateLyricFollowDelay(value: Long) {
        lyricFollowDelayMillis = normalizeLyricFollowDelayMillis(value)
        settings.lyricFollowDelayMillis = lyricFollowDelayMillis
    }

    fun updateLyricAnimationSpeed(value: LyricAnimationSpeed) {
        lyricAnimationSpeed = value
        settings.lyricAnimationSpeed = value
    }

    fun updateWordLyricsEnabled(enabled: Boolean) {
        wordLyricsEnabled = enabled
        settings.wordLyricsEnabled = enabled
    }

    fun updateLyricGlowEnabled(enabled: Boolean) {
        lyricGlowEnabled = enabled
        settings.lyricGlowEnabled = enabled
    }

    fun updateLyricFontSizeSp(value: Int) {
        lyricFontSizeSp = normalizeLyricFontSizeSp(value)
        settings.lyricFontSizeSp = lyricFontSizeSp
    }

    fun updateShowFullLyrics(enabled: Boolean) {
        showFullLyrics = enabled
        settings.showFullLyrics = enabled
    }

    fun updateAudioQuality(value: AudioQuality) {
        if (value !in lazerAudioQualityOptions || value == audioQuality) return
        audioQuality = value
        settings.audioQuality = value
    }

    fun updateReplayGainMode(mode: LazerReplayGainMode) {
        if (replayGainMode == mode) return
        replayGainMode = mode
        settings.replayGainMode = mode
        player.updateReplayGainMode(mode)
    }

    fun updateExclusiveAudio(enabled: Boolean) {
        if (exclusiveAudio == enabled) return
        exclusiveAudio = enabled
        settings.exclusiveAudio = enabled
        player.updateExclusiveAudio(enabled)
    }

    fun updateEqualizer(state: LazerEqualizerState) {
        if (equalizer == state && !equalizerPreviewActive) return
        equalizerPreviewActive = false
        equalizer = state
        settings.equalizer = state
        player.updateEqualizer(state)
    }

    /** Applies an in-progress slider value without writing each drag event to preferences. */
    fun previewEqualizer(state: LazerEqualizerState) {
        equalizerPreviewActive = true
        player.updateEqualizer(state)
    }

    fun updateAudioReactiveLevels(enabled: Boolean) {
        if (audioReactiveLevels == enabled) return
        audioReactiveLevels = enabled
        settings.audioReactiveLevels = enabled
        player.updateAudioLevels(enabled)
    }

    fun updateHapticsEnabled(enabled: Boolean) {
        hapticsEnabled = enabled
        settings.hapticsEnabled = enabled
    }

    /** Shown when the user asks for the audio-reactive indicator but withholds the permission. */
    fun reportAudioLevelsPermissionDenied() {
        message = tr("settings.audio_levels.denied")
    }

    fun updateIndependentPlayback(enabled: Boolean) {
        val value = if (enabled) {
            LazerPlaybackInterface.INDEPENDENT
        } else {
            LazerPlaybackInterface.SYSTEM_MEDIA
        }
        if (playbackInterface == value) return
        playbackInterface = value
        settings.playbackInterface = value
        player.updatePlaybackInterface(value == LazerPlaybackInterface.SYSTEM_MEDIA)
    }

    fun isSongLiked(songId: Long): Boolean = songId in likedSongIds

    fun toggleSongLiked(track: LazerTrack) {
        if (track.source is LazerTrackSource.LocalFile) {
            message = tr("player.local.online_only")
            return
        }
        val user = currentUser
        if (user == null) {
            openLogin()
            return
        }
        val wasLiked = track.id in likedSongIds
        val nextLiked = !wasLiked
        likedSongIds = if (nextLiked) likedSongIds + track.id else likedSongIds - track.id
        cache.saveLikedSongIds(user.userId, likedSongIds)
        scope.launch {
            runCatching { gateway.updateSongLiked(track.id, user.userId, nextLiked) }
                .onFailure {
                    likedSongIds = if (wasLiked) likedSongIds + track.id else likedSongIds - track.id
                    cache.saveLikedSongIds(user.userId, likedSongIds)
                    message = tr("status.like_fail")
                }
        }
    }

    fun openPlaylist(playlist: LazerPlaylist) {
        val requestGeneration = ++playlistRequestGeneration
        playlistJob?.cancel()
        activePlaylist = playlist
        // A cache written before the queue was capped can still hold the whole playlist on disk.
        val cachedTracks = cache.peekTracks(playlist.id).orEmpty().take(LazerPlaybackQueue.MAX_TRACKS)
        activePlaylistTracks = cachedTracks
        isPlaylistLoading = true
        playlistJob = scope.launch {
            val persistedTracks = if (cachedTracks.isEmpty()) {
                withContext(Dispatchers.Default) { cache.loadTracks(playlist.id) }
                    .take(LazerPlaybackQueue.MAX_TRACKS)
            } else {
                cachedTracks
            }
            if (!isCurrentPlaylistRequest(playlist.id, requestGeneration)) return@launch
            if (persistedTracks.isNotEmpty()) activePlaylistTracks = persistedTracks
            try {
                val fresh = loadAllPlaylistTracks(playlist, requestGeneration)
                if (isCurrentPlaylistRequest(playlist.id, requestGeneration) && fresh.isNotEmpty()) {
                    activePlaylistTracks = fresh
                }
            } catch (_: Throwable) {
                if (persistedTracks.isEmpty()) message = tr("status.playlist_sync_fail")
            } finally {
                if (isCurrentPlaylistRequest(playlist.id, requestGeneration)) isPlaylistLoading = false
            }
        }
    }

    fun closePlaylist() {
        playlistJob?.cancel()
        playlistRequestGeneration += 1
        activePlaylist = null
        activePlaylistTracks = emptyList()
        isPlaylistLoading = false
    }

    fun openArtist(artist: Artist) {
        if (artist.id <= 0L) return
        artistJob?.cancel()
        activeArtist = artist
        activeArtistTracks = emptyList()
        isArtistLoading = true
        artistJob = scope.launch {
            try {
                val detail = runCatching { gateway.artistDetail(artist.id).data?.artist }.getOrNull()
                if (activeArtist?.id != artist.id) return@launch
                if (detail != null) activeArtist = detail
                val tracks = gateway.artistTopSongs(artist.id).songs.map(::toLazerTrack)
                if (activeArtist?.id == artist.id) activeArtistTracks = tracks
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                if (activeArtist?.id == artist.id) message = tr("artist.load_fail")
            } finally {
                if (activeArtist?.id == artist.id) isArtistLoading = false
            }
        }
    }

    fun closeArtist() {
        artistJob?.cancel()
        activeArtist = null
        activeArtistTracks = emptyList()
        isArtistLoading = false
    }

    fun saveArtwork(url: String, target: String, title: String, onSaved: (String?) -> Unit = {}) {
        scope.launch {
            message = tr("cover.save.saving")
            val saved = withContext(Dispatchers.Default) {
                runCatching {
                    host.saveRemoteFile(url, target).also { written ->
                        if (!written) runCatching { host.deleteExportedFile(target) }
                    }
                }.getOrDefault(false)
            }
            message = if (saved) tr("cover.save.success", title) else tr("cover.save.fail")
            onSaved(target.takeIf { saved })
        }
    }

    fun updateSearchQuery(value: String) {
        searchQuery = value
        searchJob?.cancel()
        if (value.isBlank()) {
            searchResults = emptyList()
            isSearching = false
            return
        }
        searchJob = scope.launch {
            delay(360)
            if (value != searchQuery) return@launch
            isSearching = true
            try {
                val searchSongs = gateway.search(value.trim(), limit = 30).result?.songs.orEmpty()
                val detailedSongs = searchSongs
                    .map(Song::id)
                    .takeIf(List<Long>::isNotEmpty)
                    ?.let { ids ->
                        runCatching { gateway.songDetails(ids).songs.associateBy(Song::id) }
                            .getOrDefault(emptyMap())
                    }
                    .orEmpty()
                searchResults = searchSongs.map { song ->
                    toLazerTrack(detailedSongs[song.id] ?: song)
                }
            } catch (_: Throwable) {
                searchResults = emptyList()
                message = tr("status.search_fail")
            } finally {
                if (value == searchQuery) isSearching = false
            }
        }
    }

    fun loadLyrics(trackId: Long) {
        if (trackId <= 0L) {
            clearLyrics()
            return
        }
        lyricJob?.cancel()
        lyricTrackId = trackId
        lyrics = emptyList()
        host.publishLyrics(trackId, emptyList())
        lyricsMessage = null
        lyricsLoading = true
        lyricJob = scope.launch {
            try {
                val response = gateway.preferredLyrics(trackId)
                val timedLyrics = parseTimedWordLyrics(response.yrc?.lyric)
                    .ifEmpty { parseTimedLrc(response.lrc?.lyric) }
                val merged = mergeTimedLyrics(
                    timedLyrics,
                    parseTimedLrc(response.tlyric?.lyric),
                )
                lyrics = merged
                host.publishLyrics(trackId, merged)
                lyricsMessage = if (merged.isEmpty()) tr("status.no_lyrics") else null
            } catch (_: Throwable) {
                lyrics = emptyList()
                host.publishLyrics(trackId, emptyList())
                lyricsMessage = tr("status.lyrics_fail")
            } finally {
                lyricsLoading = false
            }
        }
    }

    fun clearLyrics() {
        lyricJob?.cancel()
        lyricJob = null
        lyricTrackId?.let { host.publishLyrics(it, emptyList()) }
        lyricTrackId = null
        lyrics = emptyList()
        lyricsMessage = null
        lyricsLoading = false
    }

    fun openLogin() {
        isLoginVisible = true
        loginMethod = LazerLoginMethod.CAPTCHA
        loginMessage = null
    }

    fun closeLogin() {
        isLoginVisible = false
        qrLoginJob?.cancel()
        qrState = LazerQrLoginState.IDLE
        qrImageData = null
        loginCookie = ""
        loginMessage = null
    }

    fun selectLoginMethod(method: LazerLoginMethod) {
        loginMethod = method
        loginMessage = null
        if (method != LazerLoginMethod.QR_CODE) {
            qrLoginJob?.cancel()
            qrState = LazerQrLoginState.IDLE
            qrImageData = null
        } else {
            startQrLogin()
        }
    }

    fun updateLoginPhone(value: String) {
        loginPhone = value
        loginMessage = null
    }

    fun updateLoginCaptcha(value: String) {
        loginCaptcha = value
        loginMessage = null
    }

    fun updateLoginPassword(value: String) {
        loginPassword = value
        loginMessage = null
    }

    fun updateLoginCookie(value: String) {
        loginCookie = value
        loginMessage = null
    }

    fun sendCaptcha() {
        val phone = normalizedPhone() ?: run {
            loginMessage = tr("login.captcha.phone_required")
            return
        }
        scope.launch {
            isSendingCaptcha = true
            loginMessage = null
            try {
                val result = gateway.sendCaptcha(phone)
                val code = result["code"]?.toString()?.trim('"')?.toIntOrNull()
                check(code in 200..299) { tr("login.captcha.send_fail") }
                captchaSent = true
                loginMessage = tr("login.captcha.sent")
            } catch (_: Throwable) {
                loginMessage = tr("login.captcha.send_fail")
            } finally {
                isSendingCaptcha = false
            }
        }
    }

    fun submitCaptchaLogin() {
        val phone = normalizedPhone() ?: run {
            loginMessage = tr("login.phone_required")
            return
        }
        if (loginCaptcha.isBlank()) {
            loginMessage = tr("login.code_required")
            return
        }
        scope.launch {
            isSubmittingLogin = true
            loginMessage = null
            try {
                val result = gateway.loginWithPhoneCaptcha(phone, loginCaptcha.trim())
                validateLogin(result.code, result.failureMessage)
                finishLogin(result.profile)
            } catch (_: Throwable) {
                loginMessage = tr("login.captcha_fail")
            } finally {
                isSubmittingLogin = false
            }
        }
    }

    fun submitPasswordLogin() {
        val phone = normalizedPhone() ?: run {
            loginMessage = tr("login.phone_required")
            return
        }
        if (loginPassword.isBlank()) {
            loginMessage = tr("login.password_required")
            return
        }
        scope.launch {
            isSubmittingLogin = true
            loginMessage = null
            try {
                val result = gateway.loginWithPhonePassword(phone, loginPassword, countryCode = "86")
                validateLogin(result.code, result.failureMessage)
                finishLogin(result.profile)
            } catch (_: Throwable) {
                loginMessage = tr("login.password_fail")
            } finally {
                isSubmittingLogin = false
            }
        }
    }

    fun submitCookieLogin() {
        val cookie = loginCookie.trim()
        if (cookie.isBlank()) {
            loginMessage = tr("login.cookie.required")
            return
        }
        scope.launch {
            isSubmittingLogin = true
            loginMessage = null
            try {
                val response = gateway.loginWithCookie(cookie)
                val profile = response.data?.profile
                val hasAccount = (profile?.userId ?: 0L) > 0L ||
                    (response.data?.account?.id ?: 0L) > 0L
                check(hasAccount) { tr("login.cookie.fail") }
                finishLogin(profile)
            } catch (_: Throwable) {
                loginMessage = tr("login.cookie.fail")
            } finally {
                isSubmittingLogin = false
            }
        }
    }

    fun startQrLogin() {
        qrLoginJob?.cancel()
        qrLoginJob = scope.launch {
            qrState = LazerQrLoginState.CREATING
            qrImageData = null
            loginMessage = null
            try {
                val key = gateway.createQrKey().data?.unikey.orEmpty()
                check(key.isNotBlank()) { tr("login.qr_key_empty") }
                val code = gateway.createQrCode(key, includeImage = true).data
                // The in-process gateway synthesizes the scan URL and has no image encoder, so
                // render it locally when the service did not hand one back.
                qrImageData = code?.qrimg?.takeIf(String::isNotBlank)
                    ?: code?.qrurl?.let { url ->
                        host.encodeQrCode(url, QR_IMAGE_SIZE)?.let {
                            "data:image/png;base64," + kotlin.io.encoding.Base64.encode(it)
                        }
                    }
                check(!qrImageData.isNullOrBlank()) { tr("login.qr_empty") }
                qrState = LazerQrLoginState.WAITING_FOR_SCAN
                while (isActive) {
                    delay(QR_POLL_INTERVAL_MILLIS)
                    when (val result = gateway.checkQrCode(key).code) {
                        800 -> {
                            qrState = LazerQrLoginState.EXPIRED
                            return@launch
                        }
                        801 -> qrState = LazerQrLoginState.WAITING_FOR_SCAN
                        802 -> qrState = LazerQrLoginState.WAITING_FOR_CONFIRMATION
                        // Risk control: the scan landed, the phone has one more check to clear.
                        QrCheckResponse.RISK_CONTROL_CODE ->
                            qrState = LazerQrLoginState.WAITING_FOR_CONFIRMATION
                        803 -> {
                            finishLogin()
                            return@launch
                        }
                        else -> {
                            qrState = LazerQrLoginState.ERROR
                            loginMessage = tr("login.qr_fail")
                            return@launch
                        }
                    }
                }
            } catch (_: Throwable) {
                qrState = LazerQrLoginState.ERROR
                loginMessage = tr("login.qr_gen_fail_retry")
            }
        }
    }

    fun logout() {
        postLoginSyncJob?.cancel()
        listenTogetherActionJob?.cancel()
        clearListenTogetherSession()
        isListenTogetherVisible = false
        scope.launch {
            player.stopAndClearSession()
            try {
                gateway.logoutSession()
            } catch (_: Throwable) {
                gateway.clearSession()
            }
            currentUser = null
            cache.clearCurrentUser()
            userPlaylists = emptyList()
            likedSongIds = emptySet()
            destination = LazerRootDestination.HOME
            message = tr("status.logged_out")
            runCatching { loadPublicContent() }
        }
    }

    fun close() {
        postLoginSyncJob?.cancel()
        maintenanceJob?.cancel()
        listenTogetherActionJob?.cancel()
        listenTogetherRefreshJob?.cancel()
        scope.cancel()
        cache.close()
        gateway.close()
    }

    fun clearSongCache() {
        maintenanceJob?.cancel()
        maintenanceJob = scope.launch {
            val removed = withContext(Dispatchers.Default) {
                runCatching { host.clearPlatformCache() }.getOrDefault(0)
            }
            message = if (removed > 0) tr("status.songs_cleared") else tr("status.songs_empty")
        }
    }

    fun clearPlaylistCache() {
        maintenanceJob?.cancel()
        maintenanceJob = scope.launch {
            val removed = withContext(Dispatchers.Default) { cache.clearPlaylistData() }
            message = if (removed > 0) tr("status.playlists_cleared") else tr("status.playlists_empty")
        }
    }

    fun forceResync() {
        maintenanceJob?.cancel()
        bootstrapJob?.cancel()
        postLoginSyncJob?.cancel()
        maintenanceJob = scope.launch {
            isLoading = true
            message = tr("status.resyncing")
            try {
                currentUser?.let { loadSignedInContent(it, forceRefresh = true) }
                    ?: loadPublicContent(forceRefresh = true)
                message = tr("status.resynced")
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                message = tr("status.resync_fail")
            } finally {
                isLoading = false
            }
        }
    }

    private fun bootstrap() {
        bootstrapJob?.cancel()
        isLoading = true
        val gatewayAtStart = gateway
        bootstrapJob = scope.launch {
            val cached = withContext(Dispatchers.Default) {
                val hasSavedSession = !gatewayAtStart.sessionCookie.isNullOrBlank()
                val profile = cache.loadCurrentUser().takeIf { hasSavedSession }
                LazerCachedBootstrap(
                    hasSavedSession = hasSavedSession,
                    featuredPlaylists = cache.loadFeaturedPlaylists(),
                    homeTracks = cache.loadTracks(HOME_TRACKS_CACHE_ID),
                    profile = profile,
                    userPlaylists = profile?.let { cache.loadUserPlaylists(it.userId) }.orEmpty(),
                    likedSongIds = profile?.let { cache.loadLikedSongIds(it.userId) }.orEmpty(),
                )
            }
            if (gatewayAtStart !== gateway) return@launch
            featuredPlaylists = cached.featuredPlaylists
            homeTracks = cached.homeTracks
            if (cached.profile != null) {
                currentUser = cached.profile
                userPlaylists = cached.userPlaylists
                likedSongIds = cached.likedSongIds
            } else {
                currentUser = null
                userPlaylists = emptyList()
                likedSongIds = emptySet()
            }
            try {
                if (!cached.hasSavedSession) {
                    loadPublicContent()
                } else {
                    val freshProfile = resolveCurrentUser()
                    if (freshProfile == null) {
                        gateway.clearSession()
                        cache.clearCurrentUser()
                        currentUser = null
                        userPlaylists = emptyList()
                        likedSongIds = emptySet()
                        loadPublicContent()
                    } else {
                        currentUser = freshProfile
                        cache.saveCurrentUser(freshProfile)
                        restoreCachedSignedInContent(freshProfile)
                        loadSignedInContent(freshProfile)
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                message = if (currentUser != null) {
                    tr("status.local_only")
                } else {
                    tr("status.connect_fail")
                }
            } finally {
                isLoading = false
                hasCompletedBootstrap = true
                if (isActive) pendingListenTogetherInvitation?.let(::joinListenTogether)
            }
        }
    }

    private suspend fun loadPublicContent(forceRefresh: Boolean = false) {
        val freshPlaylists = withContext(Dispatchers.Default) {
            gateway.topPlaylists(limit = 12, forceRefresh = forceRefresh)
                .playlists.map(::toLazerPlaylist)
        }
        if (freshPlaylists.isNotEmpty()) {
            featuredPlaylists = freshPlaylists
            cache.saveFeaturedPlaylists(freshPlaylists)
        }
        val source = featuredPlaylists.firstOrNull() ?: return
        val freshTracks = withContext(Dispatchers.Default) {
            gateway.playlistTracks(source.id, limit = 50, forceRefresh = forceRefresh)
                .songs.map(::toLazerTrack)
        }
        if (freshTracks.isNotEmpty()) {
            homeTracks = freshTracks
            cache.saveTracks(HOME_TRACKS_CACHE_ID, freshTracks)
        }
    }

    private suspend fun restoreCachedSignedInContent(profile: UserProfile) {
        val cached = withContext(Dispatchers.Default) {
            LazerCachedSignedInContent(
                userPlaylists = cache.loadUserPlaylists(profile.userId),
                likedSongIds = cache.loadLikedSongIds(profile.userId),
            )
        }
        userPlaylists = cached.userPlaylists
        likedSongIds = cached.likedSongIds
    }

    private suspend fun loadSignedInContent(profile: UserProfile, forceRefresh: Boolean = false) {
        supervisorScope {
            // These endpoints are independent. Starting them together shortens a refresh by the
            // slowest request instead of the sum of all four round trips.
            val likedSongIdsRequest = async(Dispatchers.Default) {
                gatewayOrNull { gateway.likedSongIds(profile.userId, forceRefresh).ids.toSet() }
            }
            val userPlaylistsRequest = async(Dispatchers.Default) {
                gatewayOrNull { loadAllUserPlaylists(profile.userId, forceRefresh) }.orEmpty()
            }
            val recommendedPlaylistsRequest = async(Dispatchers.Default) {
                gatewayOrNull {
                    gateway.dailyRecommendedPlaylists(forceRefresh).recommend.map(::toLazerPlaylist)
                }.orEmpty()
            }
            val recommendedTracksRequest = async(Dispatchers.Default) {
                gatewayOrNull {
                    gateway.dailyRecommendedSongs(forceRefresh).data?.dailySongs.orEmpty().map(::toLazerTrack)
                }.orEmpty()
            }

            likedSongIdsRequest.await()?.let { freshLikedSongIds ->
                likedSongIds = freshLikedSongIds
                cache.saveLikedSongIds(profile.userId, freshLikedSongIds)
            }
            val loadedPlaylists = userPlaylistsRequest.await()
            if (loadedPlaylists.isNotEmpty()) {
                userPlaylists = loadedPlaylists
                cache.saveUserPlaylists(profile.userId, loadedPlaylists)
            }

            val recommendedPlaylists = recommendedPlaylistsRequest.await()
            if (recommendedPlaylists.isNotEmpty()) {
                featuredPlaylists = recommendedPlaylists
                cache.saveFeaturedPlaylists(recommendedPlaylists)
            }

            val recommendedTracks = recommendedTracksRequest.await()
            if (recommendedTracks.isNotEmpty()) {
                homeTracks = recommendedTracks
                cache.saveTracks(HOME_TRACKS_CACHE_ID, recommendedTracks)
            } else if (homeTracks.isEmpty()) {
                loadPublicContent(forceRefresh)
            }
        }
    }

    private suspend fun loadAllUserPlaylists(
        userId: Long,
        forceRefresh: Boolean = false,
    ): List<LazerPlaylist> {
        val all = mutableListOf<LazerPlaylist>()
        var offset = 0
        do {
            val page = gateway.userPlaylists(
                userId,
                limit = 50,
                offset = offset,
                forceRefresh = forceRefresh,
            )
            all += page.playlist.map(::toLazerPlaylist)
            offset += page.playlist.size
            if (!page.more || page.playlist.isEmpty()) break
        } while (true)
        return all.distinctBy(LazerPlaylist::id)
    }

    private suspend fun loadAllPlaylistTracks(
        playlist: LazerPlaylist,
        requestGeneration: Long,
    ): List<LazerTrack> {
        val refreshed = mutableListOf<LazerTrack>()
        var offset = 0
        do {
            val page = withContext(Dispatchers.Default) {
                gateway.playlistTracks(
                    playlist.id,
                    limit = PLAYLIST_PAGE_SIZE,
                    offset = offset,
                    // The Gateway may retain a GET response briefly. The on-screen cache is already
                    // shown first, so a refresh must use a request-specific URL rather than risk
                    // accepting an old response after the user opened another playlist.
                    forceRefresh = true,
                ).songs.map(::toLazerTrack)
            }
            if (!isCurrentPlaylistRequest(playlist.id, requestGeneration)) return emptyList()
            if (page.isEmpty()) break
            refreshed += page
            val currentPage = refreshed.distinctBy(LazerTrack::id).take(LazerPlaybackQueue.MAX_TRACKS)
            // A request owns the visible list for its full lifetime. Do not combine it with a
            // previous cache snapshot: that is how a cancelled playlist request could leave B's
            // rows visible under A's header while the next page was arriving.
            activePlaylistTracks = currentPage
            offset += page.size
            if (page.size < PLAYLIST_PAGE_SIZE || currentPage.size >= LazerPlaybackQueue.MAX_TRACKS) break
        } while (true)
        val complete = refreshed.distinctBy(LazerTrack::id).take(LazerPlaybackQueue.MAX_TRACKS)
        if (isCurrentPlaylistRequest(playlist.id, requestGeneration) && complete.isNotEmpty()) {
            cache.saveTracks(playlist.id, complete)
        }
        return complete
    }

    private fun isCurrentPlaylistRequest(playlistId: Long, requestGeneration: Long): Boolean =
        playlistRequestGeneration == requestGeneration && activePlaylist?.id == playlistId

    private suspend fun resolveCurrentUser(): UserProfile? {
        if (gateway.sessionCookie.isNullOrBlank()) return null
        val status = gateway.loginStatus().data
        return status?.profile?.takeIf { it.userId > 0 }
            ?: status?.account?.id?.takeIf { it > 0 }?.let { gateway.userDetail(it).profile }
    }

    private suspend fun finishLogin(profileHint: UserProfile? = null) {
        val profile = profileHint?.takeIf { it.userId > 0 } ?: resolveCurrentUser()
        check(profile != null && profile.userId > 0) { tr("login.no_profile") }
        bootstrapJob?.cancelAndJoin()
        bootstrapJob = null
        hasCompletedBootstrap = true
        currentUser = profile
        cache.saveCurrentUser(profile)
        restoreCachedSignedInContent(profile)
        loginPassword = ""
        loginCaptcha = ""
        loginCookie = ""
        isLoginVisible = false
        qrLoginJob = null
        qrState = LazerQrLoginState.IDLE
        qrImageData = null
        message = tr("status.login_success_syncing")
        pendingListenTogetherInvitation?.let { invitation ->
            pendingListenTogetherInvitation = null
            joinListenTogether(invitation)
        }
        postLoginSyncJob?.cancel()
        postLoginSyncJob = scope.launch {
            isLoading = true
            try {
                loadSignedInContent(profile)
                message = tr("status.synced")
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                message = tr("status.login_sync_later")
            } finally {
                isLoading = false
            }
        }
    }

    private fun validateLogin(code: Int, failureMessage: String?) {
        check(code in 200..299 && !gateway.sessionCookie.isNullOrBlank()) {
            failureMessage ?: tr("login.fail_check")
        }
    }

    private fun normalizedPhone(): String? = loginPhone
        .replace(" ", "")
        .removePrefix("+86")
        .takeIf { it.length >= 6 && it.all(Char::isDigit) }

    private suspend fun <T> gatewayOrNull(request: suspend () -> T): T? = try {
        request()
    } catch (error: CancellationException) {
        throw error
    } catch (_: Throwable) {
        null
    }

    private companion object {
        const val BACKGROUND_IMAGE_FILE = "lazer.background.png"
        const val HOME_TRACKS_CACHE_ID = -101L
        const val PLAYLIST_PAGE_SIZE = 500
        const val QR_POLL_INTERVAL_MILLIS = 1_000L
        const val QR_IMAGE_SIZE = 512
    }
}

private fun toLazerTrack(song: Song): LazerTrack = LazerTrack(
    id = song.id,
    title = song.name.ifBlank { tr("track.unknown_song") },
    translatedTitle = song.translations.map(String::trim).filter { it.isNotBlank() && it != song.name }.distinct().joinToString(" / ").takeIf(String::isNotBlank),
    artist = song.artists.joinToString(" / ") { it.name }.ifBlank { tr("track.unknown_artist") },
    album = song.album?.name.orEmpty(),
    durationMillis = song.durationMillis ?: 0L,
    coverUrl = normalizedArtworkUrl(song.album?.picUrl),
    artists = song.artists.filter { it.id > 0L && it.name.isNotBlank() },
)

private fun toLazerPlaylist(playlist: Playlist): LazerPlaylist = LazerPlaylist(
    id = playlist.id,
    title = playlist.name.ifBlank { tr("playlist.unnamed") },
    subtitle = playlist.creator?.nickname?.takeIf(String::isNotBlank)
        ?: playlist.description?.takeIf(String::isNotBlank)
        ?: tr("playlist.tracks", playlist.trackCount ?: 0),
    coverUrl = sequenceOf(playlist.coverImgUrl, playlist.picUrl)
        .mapNotNull(::normalizedArtworkUrl)
        .firstOrNull(),
    trackCount = playlist.trackCount ?: 0,
    isLikedCollection = playlist.specialType == 5 || playlist.name.endsWith("喜欢的音乐"),
)
