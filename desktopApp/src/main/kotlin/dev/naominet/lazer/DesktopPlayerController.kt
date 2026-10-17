package dev.naominet.lazer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import dev.naominet.lazer.gateway.AudioQuality
import dev.naominet.lazer.gateway.NeteaseMusicGateway
import dev.naominet.lazer.gateway.SONG_COMMENT_CONTENT_LIMIT
import dev.naominet.lazer.gateway.model.Artist
import dev.naominet.lazer.gateway.model.LISTEN_TOGETHER_SHARE_FALLBACK_SONG_ID
import dev.naominet.lazer.gateway.model.ListenTogetherInvite
import dev.naominet.lazer.gateway.model.ListenTogetherParticipant
import dev.naominet.lazer.gateway.model.ListenTogetherPlaybackState
import dev.naominet.lazer.gateway.model.ListenTogetherPlaylistVersion
import dev.naominet.lazer.gateway.model.ListenTogetherRoomKind
import dev.naominet.lazer.gateway.model.Playlist
import dev.naominet.lazer.gateway.model.QrCheckResponse
import dev.naominet.lazer.gateway.model.Song
import dev.naominet.lazer.gateway.model.SongComment
import dev.naominet.lazer.gateway.model.SongUrl
import dev.naominet.lazer.gateway.model.UserProfile
import dev.naominet.lazer.gateway.model.incrementListenTogetherVersion
import dev.naominet.lazer.gateway.model.isListenTogetherClosed
import dev.naominet.lazer.gateway.model.listenTogetherCreatedRoomId
import dev.naominet.lazer.gateway.model.listenTogetherPlaybackState
import dev.naominet.lazer.gateway.model.listenTogetherRoomStatus
import dev.naominet.lazer.gateway.model.mergeListenTogetherVersions
import dev.naominet.lazer.gateway.model.parseListenTogetherInvite
import dev.naominet.lazer.gateway.model.requireListenTogetherSuccess
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.swing.Swing
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlin.math.roundToInt

data class TrackItem(
    val id: Long,
    val title: String,
    val artist: String,
    val album: String,
    val durationMillis: Long,
    val coverUrl: String?,
    val artists: List<Artist> = emptyList(),
    val translatedTitle: String? = null,
    val playbackSource: DesktopTrackSource = DesktopTrackSource.Remote,
    val replayGain: DesktopReplayGainTags? = null,
) {
    val isLocalFile: Boolean get() = playbackSource is DesktopTrackSource.LocalFile

    val durationLabel: String
        get() = formatDuration(durationMillis)
}

private data class DesktopUpnpQueuedMedia(
    val track: TrackItem,
    val mimeType: String,
    val lease: DesktopUpnpMediaLease,
)

private class DesktopUpnpMediaLeaseAuthorizationException(val sessionToken: Any) :
    IOException("A queued local source changed or its media lease is no longer valid.")

private data class DesktopUpnpMediaResources(
    val queue: List<DesktopUpnpQueuedMedia>,
    val server: DesktopUpnpMediaServer,
    val localAddress: InetAddress,
) : AutoCloseable {
    override fun close() {
        queue.forEach { it.lease.revoke() }
        server.close()
    }
}

/** Endpoint and callback resources that must move together when a renderer session is rebound. */
private data class DesktopUpnpActiveMediaBinding(
    val device: DesktopUpnpRendererDevice,
    val mediaResources: DesktopUpnpMediaResources,
    val rendererAddress: InetAddress,
    val eventReceiver: DesktopUpnpEventReceiver?,
    val eventLease: DesktopUpnpGenaLease?,
)

private data class DesktopUpnpActiveMediaPlayback(
    @Volatile var binding: DesktopUpnpActiveMediaBinding,
    @Volatile var queueIndex: Int,
    val sessionToken: Any,
    val sessionReady: AtomicBoolean,
    val eventRevision: AtomicLong,
    val advanceInProgress: AtomicBoolean,
    val explicitStopRequested: AtomicBoolean,
    val recoveryState: DesktopUpnpRecoveryState,
    @Volatile var appliedEventRevision: Long = 0L,
    @Volatile var lastObservedTrackUri: String? = null,
    @Volatile var lastObservedTransportState: String? = null,
    @Volatile var lastObservedTransportStatus: String? = null,
    @Volatile var lastObservedPositionMillis: Long? = null,
    @Volatile var lastObservedDurationMillis: Long? = null,
    @Volatile var lastObservedAtMillis: Long = 0L,
    @Volatile var naturalEndPending: Boolean = false,
    @Volatile var observedPlayingForCurrentTrack: Boolean = false,
    @Volatile var advanceRetryAfterNanos: Long = 0L,
    @Volatile var advanceFailureCount: Int = 0,
    @Volatile var recoveryRetryAfterNanos: Long = 0L,
    @Volatile var recoveryFailureCount: Int = 0,
    @Volatile var eventReconnectRefreshSent: Boolean = false,
    val shuffleRemainingIndices: ArrayDeque<Int> = ArrayDeque(),
    val shuffleHistoryIndices: MutableList<Int> = mutableListOf(),
    val eventReceiverRetryPolicy: DesktopUpnpEventReceiverRetryPolicy = DesktopUpnpEventReceiverRetryPolicy(),
    val mediaLeaseRenewalSchedule: DesktopUpnpMediaLeaseRenewalSchedule = DesktopUpnpMediaLeaseRenewalSchedule(),
    val eventRefreshRequests: Channel<Unit> = Channel(Channel.CONFLATED),
    val eventSubscriptionLock: Any = Any(),
    var eventRenewalJob: Job? = null,
    var statusPollingJob: Job? = null,
) {
    val device: DesktopUpnpRendererDevice get() = binding.device
    val mediaResources: DesktopUpnpMediaResources get() = binding.mediaResources
    val rendererAddress: InetAddress get() = binding.rendererAddress
    var eventReceiver: DesktopUpnpEventReceiver?
        get() = binding.eventReceiver
        set(value) { binding = binding.copy(eventReceiver = value) }
    var eventLease: DesktopUpnpGenaLease?
        get() = binding.eventLease
        set(value) { binding = binding.copy(eventLease = value) }
    val queue: List<DesktopUpnpQueuedMedia> get() = mediaResources.queue
    val server: DesktopUpnpMediaServer get() = mediaResources.server
    val localAddress: InetAddress get() = mediaResources.localAddress
    val current: DesktopUpnpQueuedMedia get() = queue[queueIndex]
}

/** One confirmed OpenHome queue plus the local mapping that is valid only for this session. */
private class DesktopOpenHomeActiveQueueSession(
    @Volatile var device: DesktopUpnpRendererDevice,
    @Volatile var boundRendererAddress: InetAddress,
    @Volatile var boundDeviceDescriptor: DesktopUpnpRendererDevice,
    val generation: Long,
    @Volatile var lastSnapshot: DesktopOpenHomeQueueSnapshot,
    @Volatile var binding: DesktopOpenHomeActiveQueueBinding?,
    @Volatile var localTracks: List<TrackItem>?,
    @Volatile var mediaResources: DesktopUpnpMediaResources?,
    val excludedItems: Int,
) {
    @Volatile var pollingJob: Job? = null
    val eventRefreshRequests: Channel<Unit> = Channel(Channel.CONFLATED)
    val genaRefreshRequests: Channel<Unit> = Channel(Channel.CONFLATED)
    val genaBindingState = DesktopOpenHomeGenaBindingState<
        DesktopUpnpEventReceiver,
        DesktopUpnpRendererDevice,
        InetAddress,
        DesktopUpnpGenaLease,
    >()
    val eventReceiver: DesktopUpnpEventReceiver? get() = genaBindingState.receiver()
    val eventLease: DesktopUpnpGenaLease? get() = genaBindingState.lease()
    @Volatile var eventSubscriptionJob: Job? = null
    val eventReceiverRetryPolicy = DesktopUpnpEventReceiverRetryPolicy()
    val reconnectBackoff = DesktopOpenHomeReconnectBackoff()
    @Volatile var consecutivePollFailures: Int = 0
    val operationMutex = Mutex()
    val transportCommandRevision = AtomicLong(0L)
    @Volatile var requestedTransportCommand: DesktopUpnpTransportCommand? = null

    fun recordTransportCommand(command: DesktopUpnpTransportCommand): Long = synchronized(this) {
        requestedTransportCommand = command
        transportCommandRevision.incrementAndGet()
    }

    fun clearTransportCommand(command: DesktopUpnpTransportCommand, revision: Long) {
        synchronized(this) {
            if (transportCommandRevision.get() == revision && requestedTransportCommand == command) {
                requestedTransportCommand = null
            }
        }
    }
}

/** Explicit playback origin; [TrackItem.id] remains an opaque callback/queue token for local files. */
sealed interface DesktopTrackSource {
    data object Remote : DesktopTrackSource
    data class LocalFile(
        val absolutePath: String,
        val cueSheetPath: String? = null,
        val cueTrackNumber: Int? = null,
        val cueStartFrame75: Long = 0L,
        val cueEndFrame75: Long = 0L,
    ) : DesktopTrackSource
}

private val nextLocalTrackToken = AtomicLong(Long.MIN_VALUE)
private val OPENHOME_EVENT_WAKE_PROPERTIES = setOf("Id", "IdArray", "TransportState")

internal fun isNetworkRendererEligibleLocalTrack(track: TrackItem): Boolean {
    val source = track.playbackSource as? DesktopTrackSource.LocalFile ?: return false
    if (source.cueSheetPath != null || source.cueTrackNumber != null ||
        source.cueStartFrame75 != 0L || source.cueEndFrame75 != 0L
    ) return false
    return File(source.absolutePath).extension.lowercase() in setOf("wav", "flac")
}

internal fun desktopUpnpMimeCandidates(path: String): List<String> = when (File(path).extension.lowercase()) {
    "wav" -> listOf("audio/wav", "audio/x-wav")
    "flac" -> listOf("audio/flac")
    else -> emptyList()
}

data class PlaylistItem(
    val id: Long,
    val title: String,
    val subtitle: String,
    val coverUrl: String?,
    val trackCount: Int,
    val creatorName: String? = null,
    /** True for the account's private "liked songs" collection (sidebar 我喜欢). */
    val isLikedCollection: Boolean = false,
)

internal fun visiblePlaylistTracks(
    activePlaylist: PlaylistItem?,
    activePlaylistTracks: List<TrackItem>,
    refreshedHomeTracks: List<TrackItem>,
): List<TrackItem> = if (activePlaylist == null) refreshedHomeTracks else activePlaylistTracks

enum class LoginMethod(private val labelKey: String) {
    QR_CODE("login.method.qr"),
    PASSWORD("login.method.password"),
    COOKIE("login.method.cookie");

    val label: String get() = tr(labelKey)
}

private const val WASAPI_DEFAULT_ROLE_MULTIMEDIA = 1 shl 1
private const val RETRY_UPNP_EVENT_SUBSCRIPTION_MILLIS = 2_000L
private const val NETWORK_RENDERER_END_SAMPLE_MAX_AGE_MILLIS = 10_000L
private const val LOCAL_QUEUE_CHECKPOINT_NANOS = 2_000_000_000L
private const val LOCAL_QUEUE_SAVE_DEBOUNCE_MILLIS = 300L
private const val OPENHOME_QUEUE_POLL_INTERVAL_MILLIS = 3_000L
private const val OPENHOME_QUEUE_POLL_MAX_BACKOFF_MILLIS = 30_000L

enum class QrLoginState {
    IDLE,
    CREATING,
    WAITING_FOR_SCAN,
    WAITING_FOR_CONFIRMATION,
    EXPIRED,
    AUTHORIZED,
    ERROR,
}

private data class DecodedBackgroundImage(val bitmap: ImageBitmap?)
private data class PlaybackProgress(val token: Long, val value: Float)
private data class CacheProgress(val trackId: Long, val value: Float)
private data class DesktopStreamCacheKey(val trackId: Long, val quality: AudioQuality)
private data class CachedDesktopSongUrl(val songUrl: SongUrl, val expiresAtMillis: Long)
private data class DesktopCachedLibrary(
    val playlists: List<PlaylistItem>,
    val likedTracks: List<TrackItem>,
)

private data class DesktopCachedBootstrap(
    val hasSavedSession: Boolean,
    val profile: UserProfile?,
    val featuredPlaylists: List<PlaylistItem>,
    val recentTracks: List<TrackItem>,
    val library: DesktopCachedLibrary?,
)

private data class DesktopHiFiTestToneResume(
    val track: TrackItem,
    val progress: Float,
    val wasPlaying: Boolean,
)

enum class DesktopListenTogetherConnection {
    CONNECTING,
    CONNECTED,
    RECONNECTING,
}

data class DesktopListenTogetherState(
    val roomId: String,
    val inviterId: Long,
    val isHost: Boolean,
    val connection: DesktopListenTogetherConnection = DesktopListenTogetherConnection.CONNECTING,
    val participants: List<ListenTogetherParticipant> = emptyList(),
    val remoteTrackId: Long? = null,
)

private data class DesktopListenTogetherPlaybackKey(
    val trackId: Long?,
    val isPlaying: Boolean,
)

/** How the queue advances. Sequential stops on the last track instead of wrapping around. */
enum class DesktopPlayMode {
    Sequential,
    ListLoop,
    SingleLoop,
    Shuffle,
}

internal fun DesktopPlayMode.nextOnClick(): DesktopPlayMode = when (this) {
    DesktopPlayMode.ListLoop -> DesktopPlayMode.SingleLoop
    DesktopPlayMode.SingleLoop -> DesktopPlayMode.Sequential
    DesktopPlayMode.Sequential -> DesktopPlayMode.Shuffle
    DesktopPlayMode.Shuffle -> DesktopPlayMode.ListLoop
}

internal val DesktopPlayMode.labelKey: String
    get() = when (this) {
        DesktopPlayMode.Sequential -> "player.mode.sequential"
        DesktopPlayMode.ListLoop -> "player.mode.list_loop"
        DesktopPlayMode.SingleLoop -> "player.mode.single_loop"
        DesktopPlayMode.Shuffle -> "player.shuffle"
    }

/** One page of song comments, accumulated so the panel can keep its scroll position. */
data class DesktopSongCommentState(
    val songId: Long = 0,
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val failed: Boolean = false,
    val total: Int = 0,
    val hasMore: Boolean = false,
    val hotComments: List<SongComment> = emptyList(),
    val comments: List<SongComment> = emptyList(),
)

private const val LISTEN_TOGETHER_REFRESH_MILLIS = 3_000L
private const val COMMENT_PAGE_SIZE = 20
private const val LISTEN_TOGETHER_WATCH_MILLIS = 700L
private const val LISTEN_TOGETHER_HEARTBEAT_MILLIS = 10_000L
private const val LISTEN_TOGETHER_SEEK_TOLERANCE_MILLIS = 4_000L
private const val MPD_STATUS_POLL_MILLIS = 2_000L

/** Runtime overrides used to exercise the real controller-to-native recovery path in JVM tests. */
internal data class DesktopPlayerControllerTestOverrides(
    val nativeAudioLibrary: LazerAudioLibrary,
    val enumerateOutputDevices: suspend () -> List<DesktopAudioOutputDevice>,
    val awaitRecoveryRetry: suspend (attempt: Int) -> Unit,
    val localPlaybackQueueStore: DesktopLocalPlaybackQueueStore,
    val networkRendererDiscovery: DesktopUpnpRendererDiscovery? = null,
)

class DesktopPlayerController private constructor(
    private val gateway: NeteaseMusicGateway,
    private val testOverrides: DesktopPlayerControllerTestOverrides?,
) {
    constructor(gateway: NeteaseMusicGateway = createDesktopGateway()) : this(gateway, null)

    internal constructor(testOverrides: DesktopPlayerControllerTestOverrides) :
        this(createDesktopGateway(), testOverrides)

    private val controllerJob = SupervisorJob()
    private val scope = CoroutineScope(controllerJob + Dispatchers.Swing)
    private val playlistCache = DesktopPlaylistCache()
    private val localLibraryStore = DesktopLocalAudioLibraryStore()
    private val localPlaybackQueueStore =
        testOverrides?.localPlaybackQueueStore ?: DesktopLocalPlaybackQueueStore()
    private val localPlaybackQueueSaveMutex = Mutex()
    private val localPlaybackQueueSaveGeneration = AtomicLong(0L)
    private val localPlaybackQueueNeedsFullWrite = AtomicBoolean(false)
    private var localPlaybackQueueSaveJob: Job? = null
    private var lastLocalPlaybackQueueCheckpointNanos = 0L
    private var localPlaybackQueueManaged = false
    private var localPlaybackQueueRestoreCompleted = false
    private var playModeChangedBeforeLocalQueueRestore = false
    private val systemMediaSession = DesktopSystemMediaSession(::handleSystemMediaCommand)
    private var searchJob: Job? = null
    private var playJob: Job? = null
    private var playlistJob: Job? = null
    private var artistJob: Job? = null
    private var lyricsJob: Job? = null
    private var paletteJob: Job? = null
    private var qrLoginJob: Job? = null
    private var bootstrapJob: Job? = null
    private var maintenanceJob: Job? = null
    private var backgroundImageJob: Job? = null
    private var backgroundImageGeneration = 0L
    private var localLibraryScanJob: Job? = null
    // ImageIO reads are blocking and may ignore cancellation. Hold this through the actual decode.
    private val backgroundImageDecodeMutex = Mutex()
    private var playlistRequestGeneration = 0L
    private val streamUrls = object : LinkedHashMap<DesktopStreamCacheKey, CachedDesktopSongUrl>(
        STREAM_URL_CACHE_SIZE,
        0.75f,
        true,
    ) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<DesktopStreamCacheKey, CachedDesktopSongUrl>?): Boolean =
            size > STREAM_URL_CACHE_SIZE
    }
    private val streamUrlPrefetches = mutableSetOf<DesktopStreamCacheKey>()
    private var started = false
    private var uiForeground = true
    private var lastProgressUiUpdateNanos = 0L
    private var lastCacheUiUpdateNanos = 0L
    private val activePlaybackToken = DesktopPlaybackTokenGate()
    private val progressEvents = Channel<PlaybackProgress>(Channel.CONFLATED)
    private val cacheProgressEvents = Channel<CacheProgress>(Channel.CONFLATED)
    private val progressCollectorJob = scope.launch {
        for (event in progressEvents) {
            val now = System.nanoTime()
            if (event.token == activePlaybackToken.get()) {
                automaticResumeGuard.observeProgress(event.value)
            }
            if (
                event.token == activePlaybackToken.get() &&
                !isSeeking &&
                shouldPublishDesktopUiUpdate(now, lastProgressUiUpdateNanos, uiForeground, event.value)
            ) {
                progress = event.value
                lastProgressUiUpdateNanos = now
                publishSystemMedia()
                checkpointLocalPlaybackQueue(now)
            }
        }
    }
    private val cacheProgressCollectorJob = scope.launch {
        for (event in cacheProgressEvents) {
            val now = System.nanoTime()
            if (
                nowPlaying?.id == event.trackId &&
                shouldPublishDesktopUiUpdate(now, lastCacheUiUpdateNanos, uiForeground, event.value)
            ) {
                bufferedProgress = event.value.coerceIn(0f, 1f)
                lastCacheUiUpdateNanos = now
            }
        }
    }
    /** Whether the listener chose the native HiFi engine, and what it last reported. */
    var hifiEngineEnabled by mutableStateOf(DesktopSettings.hifiEngine)
        private set
    var hifiStreamInfo by mutableStateOf<LazerHiFiStreamInfo?>(null)
        private set
    private var hifiBitPerfectOpening by mutableStateOf(false)
    private var hifiDoPOpening by mutableStateOf(false)
    private var hifiNativeDsdOpening by mutableStateOf(false)
    val hifiDigitalVolumeBypassed: Boolean
        get() = shouldBypassDesktopDigitalVolume(
            nativePlayback = usesNativeAudioFor(nowPlaying),
            bitPerfectActive = hifiStreamInfo?.bitPerfectActive == true,
            doPActive = hifiStreamInfo?.isDoPOutput == true,
            bitPerfectOpening = hifiBitPerfectOpening,
            doPOpening = hifiDoPOpening,
            nativeDsdActive = hifiStreamInfo?.isNativeDsdOutput == true,
            nativeDsdOpening = hifiNativeDsdOpening,
        )
    var hifiBufferMillis by mutableIntStateOf(DesktopSettings.hifiBufferMillis)
        private set
    var hifiBitPerfect by mutableStateOf(
        DesktopSettings.hifiBitPerfect && !DesktopSettings.hifiDoPOutput &&
            !(DesktopSettings.hifiNativeDsdOutput && supportsDesktopNativeDsdOutput()) &&
            supportsDesktopBitPerfectOutput(),
    )
        private set
    var hifiDoPOutput by mutableStateOf(DesktopSettings.hifiDoPOutput)
        private set
    var hifiNativeDsdOutput by mutableStateOf(
        DesktopSettings.hifiNativeDsdOutput && !DesktopSettings.hifiDoPOutput &&
            supportsDesktopNativeDsdOutput(),
    )
        private set
    internal var hifiOutputDevices by mutableStateOf<List<DesktopAudioOutputDevice>>(emptyList())
        private set
    var hifiOutputDevicesLoading by mutableStateOf(false)
        private set
    var hifiOutputDevicesError by mutableStateOf<String?>(null)
        private set
    var hifiOutputDeviceIdentity by mutableStateOf(DesktopSettings.hifiDeviceIdentity)
        private set
    var hifiOutputDeviceUnavailable by mutableStateOf(DesktopSettings.hifiDeviceIdentity != null)
        private set
    internal var networkRendererDevices by mutableStateOf<List<DesktopUpnpRendererDevice>>(emptyList())
        private set
    var mpdHost by mutableStateOf(DesktopSettings.mpdHost)
        private set
    var mpdPort by mutableStateOf(DesktopSettings.mpdPort.toString())
        private set
    var mpdPassword by mutableStateOf("")
        private set
    var mpdSearchQuery by mutableStateOf("")
        private set
    var mpdSearchHasSearched by mutableStateOf(false)
        private set
    var mpdSearchOffset by mutableIntStateOf(0)
        private set
    var mpdSearchTotalCount by mutableIntStateOf(0)
        private set
    var mpdSearchHasMore by mutableStateOf(false)
        private set
    internal var mpdStatus by mutableStateOf<DesktopMpdStatus?>(null)
        private set
    internal var mpdSearchResults by mutableStateOf<List<DesktopMpdTrack>>(emptyList())
        private set
    internal var mpdQueuePage by mutableStateOf<DesktopMpdQueuePage?>(null)
        private set
    var mpdLoading by mutableStateOf(false)
        private set
    var mpdError by mutableStateOf<String?>(null)
        private set
    private val mpdClient = DesktopMpdClient()
    private var mpdOperationJob: Job? = null
    private var mpdPollingJob: Job? = null
    private var mpdOperationGeneration = 0L
    var networkRendererDiscoveryLoading by mutableStateOf(false)
        private set
    var networkRendererDiscoveryError by mutableStateOf<String?>(null)
        private set
    var networkRendererDiscoveryHasSearched by mutableStateOf(false)
        private set
    private var networkRendererDiscoveryJob: Job? = null
    private var networkRendererDiscoveryGeneration = 0L
    internal var networkRendererStatusByIdentity by mutableStateOf<Map<String, DesktopUpnpRendererStatus>>(emptyMap())
        private set
    internal var networkRendererOperationLoadingIdentity by mutableStateOf<String?>(null)
        private set
    internal var networkRendererOperationErrors by mutableStateOf<Map<String, String>>(emptyMap())
        private set
    internal var networkRendererPlayingIdentity by mutableStateOf<String?>(null)
        private set
    internal var networkRendererPlayingTrackTitle by mutableStateOf<String?>(null)
        private set
    internal var networkRendererQueueIdentity by mutableStateOf<String?>(null)
        private set
    internal var networkRendererQueuePosition by mutableStateOf<String?>(null)
        private set
    internal var networkRendererQueueExcludedItems by mutableIntStateOf(0)
        private set
    internal var networkRendererQueueIsLocal by mutableStateOf(false)
        private set
    private val networkRendererClient = DesktopUpnpRendererClient()
    private val networkRendererDiscovery = testOverrides?.networkRendererDiscovery
        ?: DesktopUpnpRendererDiscovery()
    private val openHomePlaylistClient = DesktopOpenHomePlaylistClient()
    private val openHomeQueueCoordinator = DesktopOpenHomePlaylistQueueCoordinator(openHomePlaylistClient)
    private val openHomeMediaRetention = DesktopOpenHomeMediaResourceRetention()
    private val openHomeMediaDevices = ConcurrentHashMap<String, DesktopUpnpRendererDevice>()
    private val openHomeRenewalFailures = ConcurrentHashMap.newKeySet<Long>()
    private val openHomeActiveQueueSessions = ConcurrentHashMap<String, DesktopOpenHomeActiveQueueSession>()
    private val openHomeQueueSessionGeneration = AtomicLong()
    @Volatile private var openHomeActiveTargetIdentity: String? = null
    private var openHomeLeaseRenewalJob: Job? = null
    private val networkRendererGenaClient = DesktopUpnpGenaClient()
    private var networkRendererOperationJob: Job? = null
    private var networkRendererOperationGeneration = 0L
    private var networkRendererDeferredStopDevice: DesktopUpnpRendererDevice? = null
    private val networkRendererDeferredOpenHomeCommands = linkedMapOf<String, Pair<DesktopUpnpRendererDevice, DesktopUpnpTransportCommand>>()
    private var networkRendererActiveMediaPlayback: DesktopUpnpActiveMediaPlayback? = null
    private var hifiOutputRecoveryIntent: DesktopOutputRecoveryIntent? = null
    private var hifiOutputRecoveryGeneration = 0L
    private var hifiOutputRecoveryJob: Job? = null
    private val automaticResumeGuard = DesktopOutputRecoveryGuard()
    var hifiEndpointVolumeScalar by mutableStateOf<Float?>(null)
        private set
    var hifiEndpointVolumeLoading by mutableStateOf(false)
        private set
    var hifiEndpointVolumeError by mutableStateOf(false)
        private set
    internal var hifiDiagnosticsExportStatus by mutableStateOf(DesktopHiFiDiagnosticsExportStatus.Idle)
        private set
    internal var hifiPcmTestToneStatus by mutableStateOf(DesktopHiFiTestToneStatus.Idle)
        private set
    private var hifiPcmTestToneGeneration = 0L
    private var hifiPcmTestToneJob: Job? = null
    private var hifiPcmTestToneResume: DesktopHiFiTestToneResume? = null
    var hifiPcmFormatProbeLoading by mutableStateOf(false)
        private set
    var hifiPcmFormatProbeError by mutableStateOf<String?>(null)
        private set
    internal var hifiPcmFormatProbeResults by mutableStateOf<List<DesktopWasapiPcmFormatProbeResult>>(emptyList())
        private set
    internal var hifiPcmFormatProbeTarget by mutableStateOf<DesktopWasapiDevice?>(null)
        private set
    var hifiPcmFormatCapabilities by mutableStateOf<OutputCapabilities?>(null)
        private set
    private var hifiPcmFormatProbeGeneration = 0
    var hifiPcmSessionProbeLoading by mutableStateOf(false)
        private set
    var hifiPcmSessionProbeError by mutableStateOf<String?>(null)
        private set
    internal var hifiPcmSessionProbeResults by mutableStateOf<List<DesktopWasapiPcmSessionProbeResult>>(emptyList())
        private set
    internal var hifiPcmSessionProbeTarget by mutableStateOf<DesktopWasapiDevice?>(null)
        private set
    private var hifiPcmSessionProbeGeneration = 0
    @Volatile private var hifiEndpointVolumeGeneration = 0
    private val hifiEndpointVolumeMutex = Mutex()
    internal val selectedHifiOutputDevice: DesktopAudioOutputDevice?
        get() = hifiOutputDevices.firstOrNull {
            it.identityKey == hifiOutputDeviceIdentity && it.active
        }
    internal val hifiDefaultOutputLabelKey: String
        get() = when (resolveDesktopAudioOutputBackend(System.getProperty("os.name").orEmpty())) {
            DesktopAudioOutputBackend.Alsa -> "settings.hifi.device.alsa_default"
            else -> "settings.hifi.device.system_default"
        }
    internal val selectedHifiEndpointVolumeDevice: DesktopWasapiDevice?
        get() = when {
            hifiOutputDeviceUnavailable -> null
            hifiOutputDeviceIdentity != null -> selectedHifiOutputDevice as? DesktopWasapiDevice
            else -> hifiOutputDevices.filterIsInstance<DesktopWasapiDevice>().firstOrNull {
                it.defaultRoleMask and WASAPI_DEFAULT_ROLE_MULTIMEDIA != 0 &&
                    it.endpointState and WASAPI_DEVICE_STATE_ACTIVE != 0
            }
        }
    internal val hifiPcmFormatProbeDevice: DesktopWasapiDevice?
        get() = (selectedHifiOutputDevice as? DesktopWasapiDevice)
            ?: hifiOutputDevices.filterIsInstance<DesktopWasapiDevice>().firstOrNull {
            it.defaultRoleMask and WASAPI_DEFAULT_ROLE_MULTIMEDIA != 0 &&
                it.endpointState and WASAPI_DEVICE_STATE_ACTIVE != 0
        }

    private val standardPlayer = DesktopAudioPlayer(
        // A conflated channel keeps at most one pending UI update. This prevents a busy Swing
        // thread from accumulating one coroutine and captured object for every audio tick.
        onProgress = ::handlePlayerProgress,
        onBuffered = ::handlePlayerBuffered,
        onCompleted = ::handlePlayerCompleted,
        onError = ::handlePlayerError,
        initialExclusiveAudio = DesktopSettings.exclusiveAudio && isWindowsDesktop(),
        initialEqualizer = DesktopSettings.equalizer,
    )

    /**
     * The native engine is optional: it needs its DLL and the FFmpeg DLLs beside it. When it is
     * missing, or the listener never turned it on, playback stays on the Java Sound path.
     */
    private val nativePlayer: DesktopNativeAudioPlayer? = if (
        testOverrides != null || LazerAudioLoader.isAvailable
    ) {
        DesktopNativeAudioPlayer(
            onProgress = ::handlePlayerProgress,
            onBuffered = ::handlePlayerBuffered,
            onCompleted = ::handlePlayerCompleted,
            onError = ::handlePlayerError,
            onTrackChanged = ::handlePlayerTrackChanged,
            onStreamInfo = { info ->
                hifiStreamInfo = info
                hifiBitPerfectOpening = false
                hifiDoPOpening = false
                hifiNativeDsdOpening = false
            },
            initialExclusiveAudio = shouldRequestDesktopExclusiveOutput(DesktopSettings.exclusiveAudio),
            initialEqualizer = DesktopSettings.equalizer,
            initialBufferMillis = DesktopSettings.hifiBufferMillis,
            initialBitPerfect = hifiBitPerfect,
            initialDoPOutput = DesktopSettings.hifiDoPOutput,
            initialNativeDsdOutput = hifiNativeDsdOutput,
            apiOverride = testOverrides?.nativeAudioLibrary,
        )
    } else {
        null
    }

    /** The engine the transport actually talks to. */
    private val audioPlayer: DesktopAudioEngine
        get() = if (usesNativeAudioFor(nowPlaying)) nativePlayer ?: standardPlayer else standardPlayer

    private fun usesNativeAudioFor(track: TrackItem?): Boolean =
        nativePlayer != null && (hifiEngineEnabled || track?.isLocalFile == true)

    private fun stopAudioEngineForRequest(request: Long) {
        val player = audioPlayer
        val native = nativePlayer
        if (native != null && player === native) {
            scope.launch {
                withContext(Dispatchers.IO) {
                    native.stopIfCurrent { activePlaybackToken.isCurrent(request) }
                }
            }
        } else {
            player.stop()
        }
    }

    /** True when this machine can run the native HiFi engine. */
    val hifiEngineAvailable: Boolean get() = nativePlayer != null

    private fun handlePlayerProgress(token: Long, value: Float) {
        progressEvents.trySend(PlaybackProgress(token, value))
    }

    private fun handlePlayerBuffered(trackId: Long, value: Float) {
        cacheProgressEvents.trySend(CacheProgress(trackId, value))
    }

    private fun handlePlayerCompleted(token: Long) {
        scope.launch {
            if (!activePlaybackToken.compareAndSet(token, 0L)) {
                PlaybackDebugLog.event("playback-complete-ignored", "token=$token active=${activePlaybackToken.get()}")
                return@launch
            }
            clearHifiOutputRecoveryIntent()
            PlaybackDebugLog.event("playback-complete", "token=$token track=${nowPlaying?.id}")
            hifiStreamInfo = null
            hifiBitPerfectOpening = false
            hifiDoPOpening = false
            hifiNativeDsdOpening = false
            progress = 1f
            when {
                playModeState == DesktopPlayMode.SingleLoop -> {
                    nowPlaying?.let { resolveAndPlay(it) } ?: run { isPlaying = false }
                    publishSystemMedia(forcePosition = true)
                }
                effectiveQueue().isEmpty() -> {
                    isPlaying = false
                    publishSystemMedia(forcePosition = true)
                }
                else -> playNext()
            }
        }
    }

    private fun handlePlayerTrackChanged(token: Long, playback: DesktopQueuedPlayback) {
        scope.launch {
            if (activePlaybackToken.get() != token) return@launch
            nowPlaying = playback.track
            progress = 0f
            bufferedProgress = 0f
            streamUrl = playback.url
            streamBitrate = playback.bitrate
            streamCacheVariant = playback.cacheVariant
            streamExpectedBytes = playback.expectedBytes
            activeReplayGainResolution = if (playback.track.isLocalFile &&
                replayGainMode != DesktopReplayGainMode.Off
            ) {
                resolveDesktopReplayGain(playback.track.replayGain, replayGainMode)
            } else {
                null
            }
            isLiked = likedTracks.any { it.id == playback.track.id }
            if (recentTracks.none { it.id == playback.track.id }) {
                recentTracks = listOf(playback.track) + recentTracks.take(39)
            }
            if (playModeState == DesktopPlayMode.Shuffle) {
                if (shuffleRemaining.firstOrNull() == playback.track.id) {
                    shuffleRemaining.removeFirst()
                } else {
                    shuffleRemaining.remove(playback.track.id)
                }
                if (shuffleVisited.lastOrNull() != playback.track.id) {
                    shuffleVisited.addLast(playback.track.id)
                    while (shuffleVisited.size > 200) shuffleVisited.removeFirst()
                }
            }
            loadLyrics(playback.track.id)
            loadCoverPalette(playback.track.coverUrl, playback.track.id)
            PlaybackDebugLog.event(
                "playback-track-boundary",
                "token=$token track=${playback.track.id}",
            )
            refreshGaplessSuccessor(token, playback.track)
            publishSystemMedia(forcePosition = true)
            persistLocalPlaybackQueue(immediate = true)
        }
    }

    /** Resolve and prepare one native successor; a request generation retires stale URL lookups. */
    private fun refreshGaplessSuccessor(
        token: Long = activePlaybackToken.get(),
        currentTrack: TrackItem? = nowPlaying,
    ) {
        val localNativePlayback = currentTrack?.isLocalFile == true
        val player = nativePlayer?.takeIf { hifiEngineEnabled || localNativePlayback }
        val requestGeneration = gaplessRequestGeneration.incrementAndGet()
        player?.clearQueuedNext()
        if (player == null || token == 0L || currentTrack == null) return
        val successor = nextTrackForGapless(currentTrack) ?: return
        if (currentTrack.isLocalFile || successor.isLocalFile) {
            val nextGain = resolveDesktopReplayGain(successor.replayGain, replayGainMode).appliedGainDb
            val doPOutputActive = hifiStreamInfo?.isDoPOutput == true
            val nativeDsdOutputActive = hifiStreamInfo?.isNativeDsdOutput == true
            if (!canQueueDesktopLocalGaplessSuccessor(
                    currentTrack,
                    successor,
                    doPOutputActive = doPOutputActive,
                    nativeDsdOutputActive = nativeDsdOutputActive,
                ) ||
                gaplessRequestGeneration.get() != requestGeneration ||
                activePlaybackToken.get() != token || nowPlaying?.id != currentTrack.id ||
                (!hifiEngineEnabled && !currentTrack.isLocalFile)
            ) return
            val localKind = when {
                nativeDsdOutputActive -> "local-dsd-native"
                doPOutputActive -> "local-dsd-dop"
                isContiguousDesktopCueSuccessor(currentTrack, successor) -> "local-cue"
                else -> "local-file"
            }
            player.queueNext(
                DesktopQueuedPlayback(
                    track = successor,
                    afterTrackId = currentTrack.id,
                    url = null,
                    cacheVariant = localKind,
                    expectedBytes = null,
                    bitrate = null,
                    replayGainDb = nextGain,
                ),
            )
            return
        }
        val quality = audioQuality
        scope.launch {
            try {
                val songUrl = resolveSongUrl(successor.id, quality) ?: return@launch
                val url = songUrl.url?.takeIf(String::isNotBlank) ?: return@launch
                if (gaplessRequestGeneration.get() != requestGeneration ||
                    activePlaybackToken.get() != token || nowPlaying?.id != currentTrack.id ||
                    audioQuality != quality || !hifiEngineEnabled
                ) return@launch
                val variant = audioCacheVariant(songUrl.br, songUrl.md5, songUrl.type)
                player.queueNext(
                    DesktopQueuedPlayback(
                        track = successor,
                        afterTrackId = currentTrack.id,
                        url = url,
                        cacheVariant = variant,
                        expectedBytes = songUrl.size,
                        bitrate = songUrl.br,
                    ),
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                PlaybackDebugLog.event(
                    "gapless-url-prepare-failed",
                    "token=$token track=${successor.id} error=${error.playbackDebugSummary()}",
                )
            }
        }
    }

    private fun nextTrackForGapless(currentTrack: TrackItem): TrackItem? {
        if (playModeState == DesktopPlayMode.SingleLoop) return currentTrack
        val tracks = effectiveQueue()
        if (tracks.isEmpty()) return null
        val index = tracks.indexOfFirst { it.id == currentTrack.id }
        if (index < 0) return null
        return when (playModeState) {
            DesktopPlayMode.Sequential -> tracks.getOrNull(index + 1)
            DesktopPlayMode.ListLoop -> tracks[(index + 1) % tracks.size]
            DesktopPlayMode.SingleLoop -> currentTrack
            DesktopPlayMode.Shuffle -> previewShuffleTrack(tracks, currentTrack.id)
        }
    }

    /** Peek the shuffle bag without consuming the track before its audible boundary. */
    private fun previewShuffleTrack(tracks: List<TrackItem>, currentId: Long): TrackItem? {
        if (tracks.size <= 1) return tracks.firstOrNull { it.id == currentId }
        if (shuffleRemaining.isEmpty()) {
            tracks.asSequence()
                .map(TrackItem::id)
                .filter { it != currentId && it !in shuffleVisited }
                .shuffled()
                .let(shuffleRemaining::addAll)
            if (shuffleRemaining.isEmpty()) {
                tracks.asSequence().map(TrackItem::id).filter { it != currentId }
                    .shuffled().let(shuffleRemaining::addAll)
            }
        }
        while (true) {
            val id = shuffleRemaining.firstOrNull() ?: return tracks.firstOrNull { it.id == currentId }
            val track = tracks.firstOrNull { it.id == id }
            if (track != null && id != currentId) return track
            shuffleRemaining.removeFirst()
        }
    }

    private fun handlePlayerError(token: Long, error: Throwable) {
        scope.launch {
            if (!activePlaybackToken.compareAndSet(token, 0L)) {
                PlaybackDebugLog.event(
                    "playback-error-ignored",
                    "token=$token active=${activePlaybackToken.get()} error=${error.playbackDebugSummary()}",
                )
                return@launch
            }
            PlaybackDebugLog.event(
                "playback-error",
                "token=$token track=${nowPlaying?.id} seeking=$isSeeking progress=$progress error=${error.playbackDebugSummary()}",
            )
            val automaticResumeFailed = automaticResumeGuard.awaitingConfirmation
            clearHifiOutputRecoveryIntent()
            val deviceLost = error as? DesktopAudioDeviceLostException
            val track = nowPlaying
            val recoveryIntent = if (deviceLost != null && track != null && usesNativeAudioFor(track)) {
                DesktopOutputRecoveryIntent(
                    trackId = track.id,
                    positionMillis = deviceLost.positionMillis,
                    wasPlaying = isPlaying,
                    outputIdentity = hifiOutputDeviceIdentity,
                    outputIdentityStable = selectedHifiOutputDevice?.stableIdentity == true,
                )
            } else {
                null
            }
            hifiOutputRecoveryIntent = recoveryIntent
            if (recoveryIntent != null && track != null && track.durationMillis > 0L) {
                progress = recoveryIntent.progressFor(track.durationMillis)
            }
            hifiStreamInfo = null
            hifiBitPerfectOpening = false
            hifiDoPOpening = false
            hifiNativeDsdOpening = false
            isPlaying = false
            isSeeking = false
            streamUrl = null
            statusMessage = if (deviceLost != null) {
                if (!automaticResumeFailed &&
                    canAutomaticallyRecoverOutput(recoveryIntent, track?.id, hifiOutputDeviceIdentity)
                ) {
                    tr("status.hifi.device_lost_recovering")
                } else {
                    tr("status.hifi.device_lost_manual")
                }
            } else {
                error.toFriendlyMessage(tr("status.audio_fail"))
            }
            if (recoveryIntent != null && !automaticResumeFailed) {
                startAutomaticHifiOutputRecovery(recoveryIntent)
            }
            publishSystemMedia(
                statusOverride = SystemMediaPlaybackStatus.STOPPED,
                forcePosition = true,
            )
        }
    }

    var isDark by mutableStateOf(DesktopSettings.isDark)
        private set
    var style by mutableStateOf(DesktopSettings.style)
        private set
    var palette by mutableStateOf(DesktopSettings.palette)
        private set
    private var backgroundImagePath by mutableStateOf(DesktopSettings.backgroundImagePath)
    val hasBackgroundImage: Boolean get() = backgroundImagePath != null
    var backgroundImage by mutableStateOf<ImageBitmap?>(null)
        private set
    var backgroundImageEnabled by mutableStateOf(DesktopSettings.backgroundImageEnabled)
        private set
    var backgroundMode by mutableStateOf(DesktopSettings.backgroundMode)
        private set
    var backgroundAlpha by mutableStateOf(DesktopSettings.backgroundAlpha)
        private set
    val themeEngine: LazerThemeEngine get() = style.themeEngine
    var language by mutableStateOf(DesktopSettings.language)
        private set
    var lyricFollowDelayMillis by mutableStateOf(DesktopSettings.lyricFollowDelayMillis)
        private set
    var lyricAnimationSpeed by mutableStateOf(DesktopSettings.lyricAnimationSpeed)
        private set
    var wordLyricsEnabled by mutableStateOf(DesktopSettings.wordLyricsEnabled)
        private set
    var lyricGlowEnabled by mutableStateOf(DesktopSettings.lyricGlowEnabled)
        private set
    var lyricFontSizeSp by mutableIntStateOf(DesktopSettings.lyricFontSizeSp)
        private set
    var showFullLyrics by mutableStateOf(DesktopSettings.showFullLyrics)
        private set
    var isLoading by mutableStateOf(false)
        private set
    var statusMessage by mutableStateOf<String?>(null)
        private set
    var localLibraryRoots by mutableStateOf(DesktopSettings.localLibraryRoots)
        private set
    var localLibraryTracks by mutableStateOf<List<TrackItem>>(emptyList())
        private set
    var localLibraryReady by mutableStateOf(false)
        private set
    var localLibraryScanning by mutableStateOf(false)
        private set
    var localLibraryScanError by mutableStateOf<String?>(null)
        private set
    var searchQuery by mutableStateOf("")
        private set
    var featuredPlaylists by mutableStateOf<List<PlaylistItem>>(emptyList())
        private set
    var userPlaylists by mutableStateOf<List<PlaylistItem>>(emptyList())
        private set
    var recentTracks by mutableStateOf<List<TrackItem>>(emptyList())
        private set
    var likedTracks by mutableStateOf<List<TrackItem>>(emptyList())
        private set
    var searchResults by mutableStateOf<List<TrackItem>>(emptyList())
        private set
    var activePlaylist by mutableStateOf<PlaylistItem?>(null)
        private set
    var activePlaylistTracks by mutableStateOf<List<TrackItem>>(emptyList())
        private set
    val activePlaylistTitle: String?
        get() = activePlaylist?.title
    var activeArtist by mutableStateOf<Artist?>(null)
        private set
    var activeArtistTracks by mutableStateOf<List<TrackItem>>(emptyList())
        private set
    var isArtistLoading by mutableStateOf(false)
        private set
    var nowPlaying by mutableStateOf<TrackItem?>(null)
        private set
    internal val canSendCurrentLocalTrackToNetworkRenderer: Boolean
        get() = nowPlaying?.let(::isNetworkRendererEligibleLocalTrack) == true
    internal val currentLocalTrackIsCue: Boolean
        get() = (nowPlaying?.playbackSource as? DesktopTrackSource.LocalFile)?.let {
            it.cueSheetPath != null || it.cueTrackNumber != null || it.cueStartFrame75 != 0L || it.cueEndFrame75 != 0L
        } == true
    var isPlaying by mutableStateOf(false)
        private set
    var progress by mutableFloatStateOf(0f)
        private set
    /** Fraction of the current encoded audio already available in the persistent local cache. */
    var bufferedProgress by mutableFloatStateOf(0f)
        private set
    /** True while the user is dragging the seek bar — freezes display smoothing. */
    var isSeeking by mutableStateOf(false)
        private set
    var volume by mutableFloatStateOf(DesktopSettings.volume)
        private set
    var audioQuality by mutableStateOf(AudioQuality.EXHIGH)
        private set
    var exclusiveAudio by mutableStateOf(shouldRequestDesktopExclusiveOutput(DesktopSettings.exclusiveAudio))
        private set
    var equalizer by mutableStateOf(DesktopSettings.equalizer)
        private set
    var replayGainMode by mutableStateOf(DesktopSettings.replayGainMode)
        private set
    var activeReplayGainResolution by mutableStateOf<DesktopReplayGainResolution?>(null)
        private set
    var streamUrl by mutableStateOf<String?>(null)
        private set
    var streamBitrate by mutableStateOf<Int?>(null)
        private set
    private var streamCacheVariant = "default"
    private var streamExpectedBytes: Long? = null
    var isLiked by mutableStateOf(false)
        private set
    /** The single playback-mode control shared by the player and queue. */
    private var playModeState by mutableStateOf(DesktopPlayMode.ListLoop)

    val playMode: DesktopPlayMode get() = playModeState

    /**
     * An arrangement made in the queue card, paired with the source list it was made from. Carrying
     * the source alongside the order is what retires an edit once a different playlist takes over,
     * without the reader having to write anything back.
     */
    private data class QueueEdit(val base: List<TrackItem>, val order: List<TrackItem>)

    private var queueEdit by mutableStateOf<QueueEdit?>(null)

    /** Shuffle draws without replacement: ids still in the bag, and the order already drawn. */
    private val shuffleRemaining = ArrayDeque<Long>()
    private val shuffleVisited = ArrayDeque<Long>()
    private val gaplessRequestGeneration = AtomicLong(0L)


    var lyrics by mutableStateOf<List<TimedLyricLine>>(emptyList())
        private set
    var lyricsLoading by mutableStateOf(false)
        private set
    var lyricsError by mutableStateOf<String?>(null)
        private set
    /** Album-art-derived seed and colors driving themes and visual backgrounds. */
    var nowPlayingArtworkSeed by mutableStateOf(CoverPalette.defaultSeed)
        private set
    var lyricFlowColors by mutableStateOf(CoverPalette.defaultFlow)
        private set

    /** Playback position derived from progress and the current track duration. */
    val positionMillis: Long
        get() {
            val duration = nowPlaying?.durationMillis ?: return 0L
            return (duration * progress.toDouble()).toLong().coerceIn(0L, duration)
        }

    val currentLyricIndex: Int
        get() = findCurrentLyricIndex(lyrics, positionMillis)

    var currentUser by mutableStateOf<UserProfile?>(null)
        private set
    val isSignedIn: Boolean
        get() = currentUser != null
    val currentSessionCookie: String?
        get() = gateway.sessionCookie?.takeIf(String::isNotBlank)

    var isLoginVisible by mutableStateOf(false)
        private set
    var loginMethod by mutableStateOf(LoginMethod.QR_CODE)
        private set
    var qrLoginState by mutableStateOf(QrLoginState.IDLE)
        private set
    var qrImageData by mutableStateOf<String?>(null)
        private set
    var qrFallbackUrl by mutableStateOf<String?>(null)
        private set
    var loginIdentifier by mutableStateOf("")
        private set
    var loginPassword by mutableStateOf("")
        private set
    var loginCookie by mutableStateOf("")
        private set
    var loginError by mutableStateOf<String?>(null)
        private set
    var isSubmittingLogin by mutableStateOf(false)
        private set
    private var activeRequests by mutableIntStateOf(0)

    var isListenTogetherVisible by mutableStateOf(false)
        private set
    var listenTogether by mutableStateOf<DesktopListenTogetherState?>(null)
        private set
    var isListenTogetherBusy by mutableStateOf(false)
        private set
    var listenTogetherError by mutableStateOf<String?>(null)
        private set
    private var listenTogetherActionJob: Job? = null
    private var listenTogetherRefreshJob: Job? = null
    private var listenTogetherWatchJob: Job? = null
    private var listenTogetherSequence = 1L
    private var listenTogetherPlaylistState: ListenTogetherPlaybackState? = null
    private var listenTogetherVersions: List<ListenTogetherPlaylistVersion> = emptyList()
    private var lastReportedQueueIds: List<Long> = emptyList()
    private var lastRoomQueueIds: List<Long> = emptyList()
    private var lastAppliedRemoteSequence = -1L
    private var pendingRemotePlayback: DesktopListenTogetherPlaybackKey? = null
    private var lastStablePlayback: DesktopListenTogetherPlaybackKey? = null
    private var lastHeartbeatMillis = 0L

    /** Room link friends open in the official app; a fresh room still has no song of its own. */
    val listenTogetherShareUrl: String?
        get() {
            val room = listenTogether ?: return null
            val current = nowPlaying?.takeUnless(TrackItem::isLocalFile)
            val songId = current?.id ?: room.remoteTrackId ?: LISTEN_TOGETHER_SHARE_FALLBACK_SONG_ID
            return ListenTogetherInvite(roomId = room.roomId, inviterId = room.inviterId).shareUrl(songId)
        }

    fun start() {
        if (started) return
        started = true
        LazerI18n.switchLanguage(language)
        systemMediaSession.start()
        systemMediaSession.setVolume(volume)
        if (hifiEngineAvailable) refreshHifiOutputDevices()
        loadBackgroundImage()
        restoreLocalLibrary()
        scope.launch {
            restoreLocalPlaybackQueue()
            loadLazerTranslations()
            connectMusicService()
        }
    }

    fun updatePalette(value: LazerPalette) {
        palette = value
        DesktopSettings.palette = value
    }

    fun updateBackgroundAlpha(value: Float) {
        backgroundAlpha = value.coerceIn(0f, 1f)
        DesktopSettings.backgroundAlpha = backgroundAlpha
    }

    fun updateBackgroundMode(value: DesktopBackgroundMode) {
        if (backgroundMode == value) return
        backgroundMode = value
        DesktopSettings.backgroundMode = value
        cancelBackgroundImageLoad()
        if (value == DesktopBackgroundMode.IMAGE) {
            loadBackgroundImage()
        } else {
            backgroundImage = null
        }
    }

    fun updateBackgroundImageEnabled(enabled: Boolean) {
        if (backgroundImageEnabled == enabled) return
        backgroundImageEnabled = enabled
        DesktopSettings.backgroundImageEnabled = enabled
        cancelBackgroundImageLoad()
        if (enabled) loadBackgroundImage() else backgroundImage = null
    }

    /** Only persist a new selection after it has decoded successfully, even when hidden. */
    fun setBackgroundImage(source: java.io.File) {
        requestBackgroundImage(source, saveSelection = true)
    }

    fun clearBackgroundImage() {
        cancelBackgroundImageLoad()
        backgroundImage = null
        backgroundImagePath = null
        DesktopSettings.backgroundImagePath = null
    }

    private fun cancelBackgroundImageLoad() {
        backgroundImageGeneration++
        backgroundImageJob?.cancel()
        backgroundImageJob = null
    }

    private fun loadBackgroundImage() {
        if (!backgroundImageEnabled || backgroundMode != DesktopBackgroundMode.IMAGE) return
        val path = backgroundImagePath ?: return
        requestBackgroundImage(java.io.File(path), saveSelection = false)
    }

    private fun requestBackgroundImage(source: java.io.File, saveSelection: Boolean) {
        cancelBackgroundImageLoad()
        val generation = backgroundImageGeneration
        val retainBitmap = backgroundImageEnabled
        backgroundImageJob = scope.launch {
            try {
                val result = withContext(Dispatchers.IO) {
                    backgroundImageDecodeMutex.withLock {
                        currentCoroutineContext().ensureActive()
                        val image = decodeDesktopBackgroundImage(source) ?: return@withLock null
                        try {
                            currentCoroutineContext().ensureActive()
                            // A hidden selection still gets validated, without retaining a native bitmap.
                            DecodedBackgroundImage(if (retainBitmap) image.toComposeImageBitmap() else null)
                        } finally {
                            image.flush()
                        }
                    }
                }
                if (generation != backgroundImageGeneration || result == null) return@launch
                backgroundImage = result.bitmap
                if (saveSelection) {
                    backgroundImagePath = source.absolutePath
                    DesktopSettings.backgroundImagePath = source.absolutePath
                    backgroundMode = DesktopBackgroundMode.IMAGE
                    backgroundImageEnabled = true
                    DesktopSettings.backgroundMode = DesktopBackgroundMode.IMAGE
                    DesktopSettings.backgroundImageEnabled = true
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (saveSelection) println("Lazer: background load failed: $error")
            }
        }
    }

    private fun connectMusicService() {
        bootstrapJob?.cancel()
        val gatewayAtStart = gateway
        bootstrapJob = scope.launch {
            val cached = withContext(Dispatchers.IO) {
                val hasSavedSession = !gatewayAtStart.sessionCookie.isNullOrBlank()
                val profile = playlistCache.loadCurrentUser().takeIf { hasSavedSession }
                val library = profile?.let {
                    DesktopCachedLibrary(
                        playlists = playlistCache.loadPlaylists(userPlaylistCacheKey(it.userId)),
                        likedTracks = playlistCache.loadLikedTracks(it.userId),
                    )
                }
                DesktopCachedBootstrap(
                    hasSavedSession = hasSavedSession,
                    profile = profile,
                    // Older builds cached `/recommend/resource` entries before `picUrl` was mapped.
                    featuredPlaylists = playlistCache.loadPlaylists(FEATURED_CACHE_KEY)
                        .filter { !it.coverUrl.isNullOrBlank() },
                    recentTracks = playlistCache.loadTracks(RECENT_TRACKS_CACHE_ID)?.tracks.orEmpty(),
                    library = library,
                )
            }
            if (gatewayAtStart !== gateway) return@launch
            featuredPlaylists = cached.featuredPlaylists
            recentTracks = cached.recentTracks
            if (nowPlaying == null) nowPlaying = recentTracks.firstOrNull()
            nowPlaying?.let { track ->
                loadCoverPalette(track.coverUrl, track.id)
                if (lyrics.isEmpty()) loadLyrics(track.id)
            }
            if (cached.profile != null && cached.library != null) {
                currentUser = cached.profile
                userPlaylists = cached.library.playlists
                likedTracks = cached.library.likedTracks
                isLiked = nowPlaying?.let { track -> likedTracks.any { it.id == track.id } } ?: false
            } else {
                currentUser = null
                userPlaylists = emptyList()
                likedTracks = emptyList()
                isLiked = false
            }
            publishSystemMedia(forcePosition = true)
            beginRequest(if (cached.profile != null) tr("status.syncing_music") else tr("status.connecting"))
            try {
                if (!cached.hasSavedSession) {
                    loadPublicLibrary()
                } else {
                    val freshProfile = resolveStoredProfile()
                    if (freshProfile == null) {
                        gateway.clearSession()
                        playlistCache.clearCurrentUser()
                        currentUser = null
                        userPlaylists = emptyList()
                        likedTracks = emptyList()
                        isLiked = false
                        loadPublicLibrary()
                    } else {
                        currentUser = freshProfile
                        playlistCache.saveCurrentUser(freshProfile)
                        restoreCachedUserLibrary(freshProfile)
                        syncUserLibrary(freshProfile)
                    }
                }
                statusMessage = null
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                statusMessage = if (currentUser != null) {
                    tr("status.local_only")
                } else {
                    error.toFriendlyMessage(tr("status.connect_fail"))
                }
            } finally {
                endRequest()
            }
        }
    }

    fun dispose() {
        persistLocalPlaybackQueueImmediately()
        cancelBackgroundImageLoad()
        backgroundImage = null
        bootstrapJob?.cancel()
        searchJob?.cancel()
        playJob?.cancel()
        playlistJob?.cancel()
        artistJob?.cancel()
        lyricsJob?.cancel()
        paletteJob?.cancel()
        qrLoginJob?.cancel()
        maintenanceJob?.cancel()
        localLibraryScanJob?.cancel()
        networkRendererDiscoveryGeneration++
        networkRendererDiscoveryJob?.cancel()
        networkRendererOperationGeneration++
        networkRendererOperationJob?.cancel()
        networkRendererDeferredOpenHomeCommands.clear()
        networkRendererDeferredStopDevice = null
        openHomeLeaseRenewalJob?.cancel()
        val openHomeSessions = openHomeActiveQueueSessions.values.toList()
        openHomeActiveQueueSessions.clear()
        openHomeSessions.forEach { session ->
            session.pollingJob?.cancel()
            closeOpenHomeGenaSubscription(session, closeRefreshChannel = true)
        }
        runCatching { openHomeMediaRetention.close() }
        openHomeMediaDevices.clear()
        openHomeActiveTargetIdentity = null
        mpdOperationGeneration++
        mpdOperationJob?.cancel()
        mpdPollingJob?.cancel()
        closeActiveNetworkRendererMediaPlayback()
        listenTogetherActionJob?.cancel()
        listenTogetherRefreshJob?.cancel()
        listenTogetherWatchJob?.cancel()
        activePlaybackToken.beginRequest()
        progressEvents.close()
        progressCollectorJob.cancel()
        cacheProgressEvents.close()
        cacheProgressCollectorJob.cancel()
        systemMediaSession.close()
        standardPlayer.close()
        nativePlayer?.close()
        controllerJob.cancel()
        gateway.close()
    }

    /** Keep foreground motion unchanged, but avoid repainting an inactive window for every audio tick. */
    fun setUiForeground(foreground: Boolean) {
        if (uiForeground == foreground) return
        uiForeground = foreground
        standardPlayer.setUiForeground(foreground)
        nativePlayer?.setUiForeground(foreground)
        lastProgressUiUpdateNanos = 0L
        lastCacheUiUpdateNanos = 0L
    }

    fun toggleTheme() {
        isDark = !isDark
        DesktopSettings.isDark = isDark
    }

    fun updateStyle(value: LazerStyle) {
        style = value
        DesktopSettings.style = value
    }

    fun updateLanguage(value: LazerLanguage) {
        if (language == value) return
        language = value
        LazerI18n.switchLanguage(value)
        DesktopSettings.language = value
        statusMessage = null
        loginError = null
    }

    fun updateLyricFollowDelay(value: Long) {
        lyricFollowDelayMillis = normalizeLyricFollowDelayMillis(value)
        DesktopSettings.lyricFollowDelayMillis = lyricFollowDelayMillis
    }

    fun updateLyricAnimationSpeed(value: LyricAnimationSpeed) {
        lyricAnimationSpeed = value
        DesktopSettings.lyricAnimationSpeed = value
    }

    fun updateWordLyricsEnabled(enabled: Boolean) {
        wordLyricsEnabled = enabled
        DesktopSettings.wordLyricsEnabled = enabled
    }

    fun updateLyricGlowEnabled(enabled: Boolean) {
        lyricGlowEnabled = enabled
        DesktopSettings.lyricGlowEnabled = enabled
    }

    fun updateLyricFontSizeSp(value: Int) {
        lyricFontSizeSp = normalizeLyricFontSizeSp(value)
        DesktopSettings.lyricFontSizeSp = lyricFontSizeSp
    }

    fun updateShowFullLyrics(enabled: Boolean) {
        showFullLyrics = enabled
        DesktopSettings.showFullLyrics = enabled
    }

    fun updateSearchQuery(query: String) {
        searchQuery = query
        searchJob?.cancel()
        if (query.isBlank()) {
            searchResults = emptyList()
            return
        }
        searchJob = scope.launch {
            delay(320)
            beginRequest(tr("status.understanding"))
            try {
                val response = gateway.search(query, limit = 24, useCloudSearch = true)
                searchResults = response.result?.songs.orEmpty().map { it.toTrackItem() }
                statusMessage = if (searchResults.isEmpty()) tr("status.try_again") else null
            } catch (error: Throwable) {
                statusMessage = error.toFriendlyMessage(tr("status.search_fail"))
            } finally {
                endRequest()
            }
        }
    }

    fun useIntentSuggestion(suggestion: String) {
        updateSearchQuery(suggestion)
    }

    fun playTrack(track: TrackItem) = playTrackAt(track, positionMillis = 0L, shouldPlay = true)

    /** Starts a track at an absolute position, which is how a room hands playback over. */
    fun playTrackAt(track: TrackItem, positionMillis: Long, shouldPlay: Boolean) {
        if (track.isLocalFile && listenTogether != null) {
            statusMessage = tr("status.local_audio.room_unavailable")
            return
        }
        // Invalidate an in-flight local native open before changing nowPlaying or waiting on stop().
        activePlaybackToken.beginRequest()
        localPlaybackQueueManaged = true
        if (!track.isLocalFile && localQueueTracks.isNotEmpty()) {
            localQueueTracks = emptyList()
            queueEdit = null
            persistLocalPlaybackQueue(immediate = true)
        }
        clearHifiOutputRecoveryIntent()
        stopHiFiPcmTestTone(restorePlayback = false)
        nowPlaying = track
        if (playModeState == DesktopPlayMode.Shuffle && shuffleVisited.lastOrNull() != track.id) {
            shuffleVisited.addLast(track.id)
            while (shuffleVisited.size > 200) shuffleVisited.removeFirst()
        }
        progress = 0f
        bufferedProgress = 0f
        streamUrl = null
        streamBitrate = null
        streamCacheVariant = "default"
        streamExpectedBytes = null
        isLiked = !track.isLocalFile && likedTracks.any { it.id == track.id }
        activeReplayGainResolution = null
        if (!track.isLocalFile && recentTracks.none { it.id == track.id }) {
            recentTracks = listOf(track) + recentTracks.take(39)
        }
        if (track.isLocalFile) {
            lyricsJob?.cancel()
            lyrics = emptyList()
            lyricsError = null
            lyricsLoading = false
        }
        if (!track.isLocalFile) {
            loadLyrics(track.id)
        }
        loadCoverPalette(track.coverUrl, track.id)
        publishSystemMedia(
            statusOverride = SystemMediaPlaybackStatus.STOPPED,
            forcePosition = true,
        )
        val resumeProgress = if (track.durationMillis > 0L) {
            positionMillis.toFloat() / track.durationMillis.toFloat()
        } else {
            0f
        }
        progress = resumeProgress.coerceIn(0f, 1f)
        persistLocalPlaybackQueue(immediate = true)
        resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = shouldPlay)
    }

    /** Jump playback to the start of a lyric line. */
    fun seekToLyric(index: Int) {
        val line = lyrics.getOrNull(index) ?: return
        seekToLyricTime(line.timeMs, index)
    }

    /** Jump to a rendered lyric row, including transient interlude rows not present in [lyrics]. */
    fun seekToLyricTime(timeMs: Long) {
        seekToLyricTime(timeMs, null)
    }

    private fun seekToLyricTime(timeMs: Long, sourceIndex: Int?) {
        clearHifiOutputRecoveryIntent()
        stopHiFiPcmTestTone(restorePlayback = false)
        val track = nowPlaying ?: return
        if (track.durationMillis <= 0L) return
        val url = streamUrl
        val playWhenReady = isPlaying
        isSeeking = true
        progress = lyricSeekProgress(timeMs, track.durationMillis)
        PlaybackDebugLog.event(
            "lyric-seek",
            "track=${track.id} line=${sourceIndex ?: "transient"} target=$progress playing=$playWhenReady hasStream=${!url.isNullOrBlank()}",
        )
        if (url.isNullOrBlank()) {
            isSeeking = false
            resolveAndPlay(track, resumeProgress = progress, playWhenReady = playWhenReady)
        } else {
            startAudioPlayback(
                url = url,
                track = track,
                fromProgress = progress,
                playWhenReady = playWhenReady,
            )
            isSeeking = false
        }
        publishSystemMedia(forcePosition = true)
    }

    private fun loadLyrics(songId: Long) {
        lyricsJob?.cancel()
        lyrics = emptyList()
        lyricsError = null
        lyricsLoading = true
        lyricsJob = scope.launch {
            try {
                val response = gateway.preferredLyrics(songId)
                val timedLyrics = parseDesktopWordLyrics(response.yrc?.lyric)
                    .ifEmpty { parseLrc(response.lrc?.lyric) }
                val parsed = mergeLyrics(
                    lyrics = timedLyrics,
                    translatedLyrics = parseLrc(response.tlyric?.lyric),
                )
                if (nowPlaying?.id != songId) return@launch
                lyrics = parsed
                lyricsLoading = false
                lyricsError = if (parsed.isEmpty()) tr("status.no_lyrics") else null
            } catch (error: Throwable) {
                if (nowPlaying?.id != songId) return@launch
                lyrics = emptyList()
                lyricsLoading = false
                lyricsError = error.toFriendlyMessage(tr("status.lyrics_fail"))
            }
        }
    }

    private fun loadCoverPalette(coverUrl: String?, trackId: Long) {
        paletteJob?.cancel()
        paletteJob = scope.launch {
            val seed = runInterruptible(Dispatchers.IO) {
                CoverPalette.extractSeedFromUrl(coverUrl)
            }
            val flow = CoverPalette.flowColorsFromSeed(seed)
            if (nowPlaying?.id == trackId) {
                nowPlayingArtworkSeed = seed
                lyricFlowColors = flow
            }
        }
    }

    fun togglePlayPause() {
        if (hifiPcmTestToneStatus == DesktopHiFiTestToneStatus.Preparing ||
            hifiPcmTestToneStatus == DesktopHiFiTestToneStatus.Playing
        ) {
            stopHiFiPcmTestTone(restorePlayback = true)
            return
        }
        val track = nowPlaying ?: recentTracks.firstOrNull() ?: return
        if (nowPlaying == null) {
            playTrack(track)
            return
        }
        if (isPlaying) {
            isPlaying = false
            audioPlayer.pause()
            persistLocalPlaybackQueue(immediate = true)
            publishSystemMedia(forcePosition = true)
        } else if (streamUrl == null) {
            // Playback errors deliberately clear the stale URL, but the UI keeps the last
            // confirmed position. Resume from that position instead of silently starting the
            // audio at zero while lyrics and the seek bar remain further ahead.
            clearHifiOutputRecoveryIntent()
            val resumeProgress = progress.coerceIn(0f, 0.999f)
            PlaybackDebugLog.event(
                "playback-retry",
                "track=${track.id} from=$resumeProgress reason=missing-stream",
            )
            resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = true)
        } else {
            isPlaying = true
            automaticResumeGuard.clear()
            audioPlayer.resume()
            publishSystemMedia(forcePosition = true)
        }
    }

    private fun handleSystemMediaCommand(command: SystemMediaCommand) {
        when (command) {
            SystemMediaCommand.Play -> if (!isPlaying) togglePlayPause()
            SystemMediaCommand.Pause -> if (isPlaying) togglePlayPause()
            SystemMediaCommand.Toggle -> togglePlayPause()
            SystemMediaCommand.Next -> playNext()
            SystemMediaCommand.Previous -> playPrevious()
            SystemMediaCommand.Stop -> stopFromSystemMedia()
            is SystemMediaCommand.SeekBy -> seekFromSystemMedia(
                systemSeekTargetMillis(positionMillis, command.offsetMillis, nowPlaying?.durationMillis ?: 0L),
            )
            is SystemMediaCommand.SetPosition -> seekFromSystemMedia(command.positionMillis)
            is SystemMediaCommand.SetVolume -> updateVolume(command.volume.toFloat())
        }
    }

    private fun stopFromSystemMedia() {
        clearHifiOutputRecoveryIntent()
        stopHiFiPcmTestTone(restorePlayback = false)
        playJob?.cancel()
        val stopRequest = activePlaybackToken.beginRequest()
        hifiStreamInfo = null
        hifiBitPerfectOpening = false
        hifiDoPOpening = false
        hifiNativeDsdOpening = false
        stopAudioEngineForRequest(stopRequest)
        isPlaying = false
        isSeeking = false
        progress = 0f
        streamUrl = null
        streamBitrate = null
        persistLocalPlaybackQueue(immediate = true)
        publishSystemMedia(
            statusOverride = SystemMediaPlaybackStatus.STOPPED,
            forcePosition = true,
        )
    }

    private fun seekFromSystemMedia(positionMillis: Long) {
        val durationMillis = nowPlaying?.durationMillis ?: return
        if (durationMillis <= 0L) return
        seekTo(systemPositionProgress(positionMillis, durationMillis))
        commitSeek()
    }

    fun playPrevious() {
        networkRendererActiveMediaPlayback?.takeIf { it.sessionReady.get() }?.let { active ->
            requestNetworkRendererQueueAdvance(active, previous = true, naturalEnd = false)
            return
        }
        val list = effectiveQueue()
        if (list.isEmpty()) return
        val currentId = nowPlaying?.id
        if (playModeState == DesktopPlayMode.Shuffle) {
            val previousId = stepShuffleHistoryBack(currentId)
            val track = list.firstOrNull { it.id == previousId } ?: return
            playTrack(track)
            return
        }
        val index = list.indexOfFirst { it.id == currentId }.let { if (it < 0) 0 else it }
        playTrack(list[(index - 1 + list.size) % list.size])
    }

    fun playNext() {
        networkRendererActiveMediaPlayback?.takeIf { it.sessionReady.get() }?.let { active ->
            requestNetworkRendererQueueAdvance(active, previous = false, naturalEnd = false)
            return
        }
        val list = effectiveQueue()
        if (list.isEmpty()) return
        val currentId = nowPlaying?.id
        val index = list.indexOfFirst { it.id == currentId }
        if (index < 0) {
            playTrack(list.first())
            return
        }
        val target = when (playModeState) {
            DesktopPlayMode.Shuffle -> drawFromShuffleBag(list, currentId)
            DesktopPlayMode.Sequential -> list.getOrNull(index + 1)
            else -> list[(index + 1) % list.size]
        }
        if (target == null) {
            // Sequential reached the end of the list: the queue stops instead of wrapping.
            stopFromQueueEnd()
            return
        }
        playTrack(target)
    }

    /** Draws the next shuffle track without replacement, refilling the bag once it runs dry. */
    private fun drawFromShuffleBag(list: List<TrackItem>, currentId: Long?): TrackItem? {
        if (list.size <= 1) return list.firstOrNull { it.id == currentId } ?: list.firstOrNull()
        if (shuffleRemaining.isEmpty()) {
            list.asSequence()
                .map(TrackItem::id)
                .filter { it != currentId && it !in shuffleVisited }
                .shuffled()
                .let(shuffleRemaining::addAll)
            // Every track has been heard: start a fresh pass so the bag never runs dry.
            if (shuffleRemaining.isEmpty()) {
                list.asSequence().map(TrackItem::id).filter { it != currentId }.shuffled().let(shuffleRemaining::addAll)
            }
        }
        while (true) {
            val id = shuffleRemaining.removeFirstOrNull() ?: return list.firstOrNull { it.id == currentId }
            val track = list.firstOrNull { it.id == id } ?: continue
            if (track.id != currentId) return track
        }
    }

    /** Rewinds the drawn path so shuffle's “previous” replays what the listener actually heard. */
    private fun stepShuffleHistoryBack(currentId: Long?): Long? {
        while (shuffleVisited.lastOrNull() == currentId) shuffleVisited.removeLast()
        val previousId = shuffleVisited.lastOrNull() ?: return null
        shuffleRemaining.addFirst(currentId ?: 0L)
        return previousId
    }

    /** Sequential stopped at the last track: leave the queue in place, just end playback. */
    private fun stopFromQueueEnd() {
        clearHifiOutputRecoveryIntent()
        playJob?.cancel()
        val stopRequest = activePlaybackToken.beginRequest()
        stopAudioEngineForRequest(stopRequest)
        isPlaying = false
        isSeeking = false
        streamUrl = null
        streamBitrate = null
        persistLocalPlaybackQueue(immediate = true)
        publishSystemMedia(
            statusOverride = SystemMediaPlaybackStatus.STOPPED,
            forcePosition = true,
        )
    }

    fun seekTo(value: Float) {
        if (!isSeeking) clearHifiOutputRecoveryIntent()
        isSeeking = true
        progress = playableSeekProgress(value, nowPlaying?.durationMillis ?: 0L)
    }

    fun commitSeek() {
        // Tap and drag recognizers may both finish one pointer sequence. Only the first commit is
        // allowed to rebuild the audio pipeline.
        if (!isSeeking) {
            PlaybackDebugLog.event("seek-commit-ignored", "track=${nowPlaying?.id} reason=no-active-seek")
            return
        }
        clearHifiOutputRecoveryIntent()
        val track = nowPlaying
        val url = streamUrl
        val targetProgress = playableSeekProgress(progress, track?.durationMillis ?: 0L)
        val playWhenReady = isPlaying
        isSeeking = false
        PlaybackDebugLog.event(
            "seek-commit",
            "track=${track?.id} target=$targetProgress playing=$playWhenReady hasStream=${!url.isNullOrBlank()}",
        )
        if (track == null) return
        if (url.isNullOrBlank()) {
            resolveAndPlay(track, resumeProgress = targetProgress, playWhenReady = playWhenReady)
        } else {
            startAudioPlayback(url, track, targetProgress, playWhenReady = playWhenReady)
        }
        persistLocalPlaybackQueue(immediate = true)
        publishSystemMedia(forcePosition = true)
        if (listenTogether != null) {
            scope.launch { runCatching { reportPlaybackToRoom("SEEK") } }
        }
    }

    /** Browse playlists shown in the library strip / sidebar, without the dedicated liked entry. */
    fun browsePlaylists(): List<PlaylistItem> = userPlaylists.filterNot { it.isLikedCollection }

    fun likedPlaylist(): PlaylistItem? =
        userPlaylists.firstOrNull { it.isLikedCollection }
            ?: userPlaylists.firstOrNull { it.title.endsWith("喜欢的音乐") }

    /** Sidebar 「我喜欢」— open the private liked collection so track order matches NetEase. */
    fun openLikedCollection() {
        val profile = currentUser
        if (profile == null) {
            openLogin()
            return
        }
        val liked = likedPlaylist()
        if (liked != null) {
            openPlaylist(liked)
            return
        }
        // Fallback: rebuild from /likelist while preserving the returned id order.
        playlistJob?.cancel()
        playlistRequestGeneration += 1
        playlistJob = scope.launch {
            beginRequest(tr("liked.open"))
            try {
                // The liked collection is a playback source like any other, so it is carried only as far
                // as the queue cap; asking for every id would put the whole library in one request.
                val likedIds = gateway.likedSongIds(profile.userId).ids.take(MAX_PLAYLIST_TRACKS)
                val details = if (likedIds.isEmpty()) {
                    emptyList()
                } else {
                    gateway.songDetails(likedIds).songs
                        .associateBy { it.id }
                        .let { byId -> likedIds.mapNotNull { id -> byId[id]?.toTrackItem() } }
                }
                likedTracks = details
                val synthetic = PlaylistItem(
                    id = LIKED_FALLBACK_PLAYLIST_ID,
                    title = tr("liked.title"),
                    subtitle = "${tr("playlist.tracks", details.size)} · ${profile.nickname}",
                    coverUrl = details.firstOrNull()?.coverUrl,
                    trackCount = details.size,
                    creatorName = profile.nickname,
                    isLikedCollection = true,
                )
                showPlaylist(synthetic, details)
                statusMessage = if (details.isEmpty()) tr("status.quiet") else null
            } catch (error: Throwable) {
                statusMessage = error.toFriendlyMessage(tr("status.liked_sync_fail"))
            } finally {
                endRequest()
            }
        }
    }

    fun updateVolume(value: Float) {
        if (hifiDigitalVolumeBypassed) return
        volume = value.coerceIn(0f, 1f)
        DesktopSettings.volume = volume
        standardPlayer.setVolume(volume)
        nativePlayer?.setVolume(volume)
        systemMediaSession.setVolume(volume)
    }

    fun updateAudioQuality(quality: AudioQuality) {
        if (audioQuality == quality) return
        audioQuality = quality
        val track = nowPlaying ?: return
        if (isPlaying || streamUrl != null) {
            bufferedProgress = 0f
            resolveAndPlay(track, resumeProgress = progress, playWhenReady = isPlaying)
        }
    }

    fun updateExclusiveAudio(enabled: Boolean) {
        if (!supportsDesktopExclusiveOutput() || exclusiveAudio == enabled) return
        if (isMacOSDesktop() && nativePlayer == null) return
        clearHifiOutputRecoveryIntent()
        stopHiFiPcmTestTone(restorePlayback = false)
        exclusiveAudio = enabled
        DesktopSettings.exclusiveAudio = enabled
        val playbackToRebuild = nowPlaying?.takeIf { track ->
            when {
                isWindowsDesktop() -> isPlaying || streamUrl != null
                else -> usesNativeAudioFor(track) && (isPlaying || streamUrl != null || hifiStreamInfo != null)
            }
        }
        val resumeProgress = progress
        val playWhenReady = isPlaying
        scope.launch {
            if (isWindowsDesktop()) standardPlayer.setExclusiveAudio(enabled)
            nativePlayer?.setExclusiveAudio(enabled)
            playbackToRebuild?.let { track ->
                bufferedProgress = 0f
                resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = playWhenReady)
            }
        }
    }

    /**
     * Switches to the native HiFi engine (or back). The engine that is being left is stopped before
     * the new one takes over so two outputs never run at once.
     */
    fun updateHifiEngine(enabled: Boolean) {
        val target = enabled && nativePlayer != null
        if (hifiEngineEnabled == target) return
        clearHifiOutputRecoveryIntent()
        stopHiFiPcmTestTone(restorePlayback = false)
        standardPlayer.stop()
        playJob?.cancel()
        val stopRequest = activePlaybackToken.beginRequest()
        nativePlayer?.let { player ->
            scope.launch {
                withContext(Dispatchers.IO) {
                    player.stopIfCurrent { activePlaybackToken.isCurrent(stopRequest) }
                }
            }
        }
        hifiStreamInfo = null
        hifiBitPerfectOpening = false
        hifiDoPOpening = false
        hifiNativeDsdOpening = false
        hifiEngineEnabled = target
        DesktopSettings.hifiEngine = target
        standardPlayer.setVolume(volume)
        standardPlayer.setEqualizer(equalizer)
        nativePlayer?.let { player ->
            player.setVolume(volume)
            player.setEqualizer(equalizer)
        }
        val track = nowPlaying ?: return
        if (isPlaying || streamUrl != null) {
            val resumeProgress = progress
            val playWhenReady = isPlaying
            scope.launch { resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = playWhenReady) }
        }
    }

    fun updateHifiBufferMillis(value: Int) {
        val clamped = value.coerceIn(30, 1_000)
        hifiBufferMillis = clamped
        DesktopSettings.hifiBufferMillis = clamped
        nativePlayer?.setBufferMillis(clamped)
    }

    /** Replaces the current queue with selected local WAV/FLAC/DSF/DFF files and starts the first one. */
    fun openLocalAudioFiles(files: List<File>) {
        if (listenTogether != null) {
            statusMessage = tr("status.local_audio.room_unavailable")
            return
        }
        if (nativePlayer == null) {
            statusMessage = tr("status.local_audio.native_required")
            return
        }
        val validFiles = files.distinctBy { it.toPath().toAbsolutePath().normalize().toString() }
            .filter { it.isFile && it.canRead() && isSupportedLocalAudioFile(it) }
        if (validFiles.isEmpty()) {
            statusMessage = tr("status.local_audio.no_supported_files")
            return
        }
        localPlaybackQueueManaged = true
        localPlaybackQueueNeedsFullWrite.set(true)
        localQueueTracks = validFiles.map { file ->
            val metadata = readLocalAudioMetadata(file)
            TrackItem(
                id = nextLocalTrackToken.getAndIncrement(),
                title = metadata?.title?.takeIf(String::isNotBlank)
                    ?: file.nameWithoutExtension.ifBlank { file.name },
                artist = metadata?.artist.orEmpty(),
                album = metadata?.album.orEmpty(),
                durationMillis = metadata?.durationMillis ?: 0L,
                coverUrl = metadata?.embeddedArtwork?.let(::writeLocalAudioArtwork),
                replayGain = metadata?.replayGain,
                playbackSource = DesktopTrackSource.LocalFile(
                    file.toPath().toAbsolutePath().normalize().toString(),
                ),
            )
        }
        queueEdit = null
        statusMessage = tr("status.local_audio.queued", localQueueTracks.size)
        playTrack(localQueueTracks.first())
    }

    fun addLocalLibraryRoot(directory: File) {
        if (!localLibraryReady || localLibraryScanning) return
        val path = directory.toPath().toAbsolutePath().normalize()
        if (Files.isSymbolicLink(path) || !Files.isDirectory(path) || !Files.isReadable(path)) {
            localLibraryScanError = tr("library.local.root_unavailable")
            return
        }
        if (localLibraryRoots.any { samePath(Path.of(it), path) }) {
            rescanLocalLibrary()
            return
        }
        localLibraryRoots = localLibraryRoots + path.toString()
        DesktopSettings.localLibraryRoots = localLibraryRoots
        rescanLocalLibrary()
    }

    fun removeLocalLibraryRoot(root: String) {
        if (!localLibraryReady || localLibraryScanning) return
        val path = runCatching { Path.of(root) }.getOrNull() ?: return
        localLibraryRoots = localLibraryRoots.filterNot { candidate ->
            runCatching { samePath(Path.of(candidate), path) }.getOrDefault(false)
        }
        DesktopSettings.localLibraryRoots = localLibraryRoots
        rescanLocalLibrary()
    }

    fun rescanLocalLibrary() {
        if (!localLibraryReady || localLibraryScanning) return
        localLibraryScanning = true
        localLibraryScanError = null
        val roots = runCatching { localLibraryRoots.map { Path.of(it) } }.getOrElse { error ->
            localLibraryScanning = false
            localLibraryScanError = error.message?.takeIf(String::isNotBlank)
                ?: tr("library.local.scan_failed")
            return
        }
        val oldTracks = localLibraryTracks
        localLibraryScanJob = scope.launch {
            try {
                val previous = withContext(Dispatchers.IO) { localLibraryStore.load() }
                val scanContext = currentCoroutineContext()
                val result = withContext(Dispatchers.IO) {
                    localLibraryStore.scanAndCommit(
                        roots = roots,
                        previousEntries = previous,
                        checkActive = { scanContext.ensureActive() },
                    )
                }
                localLibraryTracks = localLibraryTracksFrom(result.entries, oldTracks)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                localLibraryScanError = listOfNotNull(
                    tr("library.local.scan_failed"),
                    error.message?.takeIf(String::isNotBlank),
                ).joinToString(": ")
            } finally {
                localLibraryScanning = false
            }
        }
    }

    fun playLocalLibraryTrack(track: TrackItem) {
        if (track !in localLibraryTracks || !track.isLocalFile) return
        localPlaybackQueueManaged = true
        localPlaybackQueueNeedsFullWrite.set(true)
        localQueueTracks = localLibraryTracks
        queueEdit = null
        playTrack(track)
    }

    private fun restoreLocalLibrary() {
        scope.launch {
            val entries = withContext(Dispatchers.IO) { localLibraryStore.load() }
            localLibraryTracks = localLibraryTracksFrom(entries, emptyList())
            localLibraryReady = true
            if (localLibraryRoots.isNotEmpty()) rescanLocalLibrary()
        }
    }

    private fun snapshotLocalPlaybackQueue(): DesktopLocalPlaybackQueueSnapshot? {
        if (localQueueTracks.isEmpty()) return null
        val tracks = effectiveQueue()
        if (tracks.isEmpty() || tracks.any { !it.isLocalFile }) return null
        val currentIndex = tracks.indexOfFirst { it.id == nowPlaying?.id }.takeIf { it >= 0 } ?: 0
        val currentTrack = tracks[currentIndex]
        val positionMillis = if (currentTrack.id == nowPlaying?.id && currentTrack.durationMillis > 0L) {
            (currentTrack.durationMillis.toDouble() * progress.coerceIn(0f, 1f)).toLong()
                .coerceIn(0L, (currentTrack.durationMillis - 1L).coerceAtLeast(0L))
        } else {
            0L
        }
        val savedTracks = tracks.map { track ->
            val source = track.playbackSource as? DesktopTrackSource.LocalFile ?: return null
            DesktopLocalPlaybackQueueTrack(
                absolutePath = source.absolutePath,
                title = track.title,
                artist = track.artist,
                album = track.album,
                durationMillis = track.durationMillis,
                coverUrl = track.coverUrl,
                replayGain = track.replayGain,
                cueSheetPath = source.cueSheetPath,
                cueTrackNumber = source.cueTrackNumber,
                cueStartFrame75 = source.cueStartFrame75,
                cueEndFrame75 = source.cueEndFrame75,
            )
        }
        return DesktopLocalPlaybackQueueSnapshot(savedTracks, currentIndex, positionMillis, playModeState)
    }

    private fun checkpointLocalPlaybackQueue(nowNanos: Long = System.nanoTime()) {
        if (localQueueTracks.isEmpty()) return
        if (nowNanos - lastLocalPlaybackQueueCheckpointNanos < LOCAL_QUEUE_CHECKPOINT_NANOS) return
        lastLocalPlaybackQueueCheckpointNanos = nowNanos
        persistLocalPlaybackQueue(immediate = false)
    }

    private fun persistLocalPlaybackQueue(immediate: Boolean) {
        if (!localPlaybackQueueManaged) return
        val generation = localPlaybackQueueSaveGeneration.incrementAndGet()
        val snapshot = snapshotLocalPlaybackQueue()
        val rewriteQueue = localPlaybackQueueNeedsFullWrite.get()
        localPlaybackQueueSaveJob?.cancel()
        localPlaybackQueueSaveJob = scope.launch {
            if (!immediate) delay(LOCAL_QUEUE_SAVE_DEBOUNCE_MILLIS)
            withContext(Dispatchers.IO) {
                localPlaybackQueueSaveMutex.withLock {
                    if (generation != localPlaybackQueueSaveGeneration.get()) return@withLock
                    val saved = writeLocalPlaybackQueueSnapshot(snapshot, rewriteQueue)
                    if (saved && generation == localPlaybackQueueSaveGeneration.get()) {
                        localPlaybackQueueNeedsFullWrite.compareAndSet(true, false)
                    }
                }
            }
        }
    }

    private fun persistLocalPlaybackQueueImmediately() {
        if (!localPlaybackQueueManaged) return
        val generation = localPlaybackQueueSaveGeneration.incrementAndGet()
        localPlaybackQueueSaveJob?.cancel()
        val snapshot = snapshotLocalPlaybackQueue()
        val rewriteQueue = localPlaybackQueueNeedsFullWrite.get()
        runBlocking {
            withContext(Dispatchers.IO) {
                localPlaybackQueueSaveMutex.withLock {
                    if (generation != localPlaybackQueueSaveGeneration.get()) return@withLock
                    val saved = writeLocalPlaybackQueueSnapshot(snapshot, rewriteQueue)
                    if (saved && generation == localPlaybackQueueSaveGeneration.get()) {
                        localPlaybackQueueNeedsFullWrite.compareAndSet(true, false)
                    }
                }
            }
        }
    }

    private fun writeLocalPlaybackQueueSnapshot(
        snapshot: DesktopLocalPlaybackQueueSnapshot?,
        rewriteQueue: Boolean,
    ): Boolean = runCatching {
            if (snapshot == null) localPlaybackQueueStore.delete()
            else if (rewriteQueue) localPlaybackQueueStore.save(snapshot)
            else localPlaybackQueueStore.updateProgress(snapshot)
            true
        }.onFailure { error ->
            PlaybackDebugLog.event("local-playback-queue-write-failed", "error=${error.javaClass.simpleName}")
        }.getOrDefault(false)

    private suspend fun restoreLocalPlaybackQueue() {
        val (snapshot, availableTracks) = withContext(Dispatchers.IO) {
            val loaded = localPlaybackQueueStore.load()
            val available = loaded?.tracks?.mapIndexedNotNull { index, saved ->
                saved.takeIf(::isLocalPlaybackQueueTrackAvailable)?.let { index to it }
            }.orEmpty()
            loaded to available
        }
        localPlaybackQueueRestoreCompleted = true
        if (localPlaybackQueueManaged) return
        localPlaybackQueueManaged = true
        if (snapshot == null) return
        val restored = availableTracks.map { (index, saved) ->
            index to TrackItem(
                    id = nextLocalTrackToken.getAndIncrement(),
                    title = saved.title,
                    artist = saved.artist,
                    album = saved.album,
                    durationMillis = saved.durationMillis,
                    coverUrl = saved.coverUrl,
                    replayGain = saved.replayGain,
                    playbackSource = DesktopTrackSource.LocalFile(
                        absolutePath = saved.absolutePath,
                        cueSheetPath = saved.cueSheetPath,
                        cueTrackNumber = saved.cueTrackNumber,
                        cueStartFrame75 = saved.cueStartFrame75,
                        cueEndFrame75 = saved.cueEndFrame75,
                    ),
                )
        }
        if (restored.isEmpty()) {
            withContext(Dispatchers.IO) { localPlaybackQueueStore.delete() }
            return
        }
        val restoredCurrent = restored.indexOfFirst { it.first == snapshot.currentIndex }
            .takeIf { it >= 0 }
            ?: restored.indexOfFirst { it.first > snapshot.currentIndex }.takeIf { it >= 0 }
            ?: restored.lastIndex
        val tracks = restored.map { it.second }
        val current = tracks[restoredCurrent]
        localQueueTracks = tracks
        queueEdit = null
        if (!playModeChangedBeforeLocalQueueRestore) playModeState = snapshot.playMode
        nowPlaying = current
        isPlaying = false
        streamUrl = null
        streamBitrate = null
        bufferedProgress = 0f
        val positionMillis = if (restored[restoredCurrent].first == snapshot.currentIndex) {
            snapshot.positionMillis.coerceAtMost((current.durationMillis - 1L).coerceAtLeast(0L))
        } else {
            0L
        }
        progress = if (current.durationMillis > 0L) {
            (positionMillis.toDouble() / current.durationMillis.toDouble()).toFloat().coerceIn(0f, 1f)
        } else {
            0f
        }
        loadCoverPalette(current.coverUrl, current.id)
        val missingCount = snapshot.tracks.size - restored.size
        if (missingCount > 0) statusMessage = tr("status.local_audio.restore_missing", missingCount)
        publishSystemMedia(forcePosition = true)
        if (missingCount > 0) persistLocalPlaybackQueue(immediate = true)
    }

    private fun isLocalPlaybackQueueTrackAvailable(track: DesktopLocalPlaybackQueueTrack): Boolean {
        val audio = File(track.absolutePath)
        if (!audio.isFile || !audio.canRead() || !isSupportedLocalAudioFile(audio) ||
            !matchesPersistedFileStamp(audio, track.audioSizeBytes, track.audioModifiedMillis)
        ) return false
        val cuePath = track.cueSheetPath ?: return true
        val cue = File(cuePath)
        return cue.isFile && cue.canRead() &&
            matchesPersistedFileStamp(cue, track.cueSheetSizeBytes, track.cueSheetModifiedMillis)
    }

    private fun matchesPersistedFileStamp(file: File, expectedSize: Long, expectedModifiedMillis: Long): Boolean =
        (expectedSize < 0L || file.length() == expectedSize) &&
            (expectedModifiedMillis < 0L || file.lastModified() == expectedModifiedMillis)

    private fun localLibraryTracksFrom(
        entries: List<DesktopLocalLibraryEntry>,
        previousTracks: List<TrackItem>,
    ): List<TrackItem> {
        val existing = (previousTracks + localLibraryTracks + localQueueTracks)
            .mapNotNull { track ->
                val source = track.playbackSource as? DesktopTrackSource.LocalFile
                    ?: return@mapNotNull null
                runCatching { localTrackIdentityKey(source) to track }.getOrNull()
            }
            .toMap()
        return entries.map { entry ->
            val source = DesktopTrackSource.LocalFile(
                absolutePath = entry.absolutePath,
                cueSheetPath = entry.cueSheetPath,
                cueTrackNumber = entry.cueTrackNumber,
                cueStartFrame75 = entry.cueStartFrame75 ?: 0L,
                cueEndFrame75 = entry.cueEndFrame75 ?: 0L,
            )
            val title = entry.title.ifBlank {
                entry.cueTrackNumber?.let { tr("library.local.cue.track_default", it) }
                    ?: Path.of(entry.absolutePath).fileName.toString().substringBeforeLast('.')
            }
            existing[localTrackIdentityKey(source)]?.copy(
                title = title,
                artist = entry.artist,
                album = entry.album,
                durationMillis = entry.durationMillis,
                coverUrl = entry.coverUrl,
                replayGain = entry.replayGain,
                playbackSource = source,
            ) ?: TrackItem(
                id = nextLocalTrackToken.getAndIncrement(),
                title = title,
                artist = entry.artist,
                album = entry.album,
                durationMillis = entry.durationMillis,
                coverUrl = entry.coverUrl,
                playbackSource = source,
                replayGain = entry.replayGain,
            )
        }
    }

    private fun localTrackIdentityKey(source: DesktopTrackSource.LocalFile): String {
        val path = Path.of(source.absolutePath).toAbsolutePath().normalize().toString()
        val cuePath = source.cueSheetPath
        val cueTrackNumber = source.cueTrackNumber
        return if (cuePath != null && cueTrackNumber != null) {
            "cue:${Path.of(cuePath).toAbsolutePath().normalize()}#$cueTrackNumber"
        } else {
            "file:$path"
        }
    }

    private fun samePath(first: Path, second: Path): Boolean =
        first.toAbsolutePath().normalize() == second.toAbsolutePath().normalize()

    fun refreshHifiOutputDevices() {
        if (!hifiEngineAvailable || hifiOutputDevicesLoading) return
        clearHifiPcmFormatProbe()
        hifiOutputDevicesLoading = true
        hifiOutputDevicesError = null
        scope.launch {
            refreshHifiOutputSnapshot(
                enumerate = ::enumerateHifiOutputDevices,
                applySnapshot = ::applyHifiOutputDeviceSnapshot,
                onFailure = { error ->
                    hifiOutputDevices = emptyList()
                    hifiOutputDevicesError = error.message ?: tr("settings.hifi.device.list_fail")
                    hifiOutputDeviceUnavailable = hifiOutputDeviceIdentity != null
                    invalidateHifiEndpointVolume()
                },
                onFinished = { successful ->
                    hifiOutputDevicesLoading = false
                    if (successful) resumeAfterOutputDeviceRefresh()
                },
            )
        }
    }

    private suspend fun enumerateHifiOutputDevices(): List<DesktopAudioOutputDevice> =
        testOverrides?.enumerateOutputDevices?.invoke() ?: withContext(Dispatchers.IO) {
            when (resolveDesktopAudioOutputBackend(System.getProperty("os.name").orEmpty())) {
                DesktopAudioOutputBackend.Wasapi -> DesktopWasapiDeviceCatalog.enumerate()
                DesktopAudioOutputBackend.Alsa -> DesktopAlsaOutputDeviceCatalog.enumerate()
                DesktopAudioOutputBackend.CoreAudio -> DesktopCoreAudioOutputDeviceCatalog.enumerate()
                DesktopAudioOutputBackend.Unsupported ->
                    error("Local HiFi output is not implemented for this desktop platform")
            }
        }

    private fun applyHifiOutputDeviceSnapshot(
        devices: List<DesktopAudioOutputDevice>,
        configureNativeDevice: Boolean = true,
        refreshEndpointVolume: Boolean = true,
    ) {
        hifiOutputDevices = devices
        val selection = resolveDesktopAudioOutputSelection(hifiOutputDeviceIdentity, devices)
        hifiOutputDeviceUnavailable = selection.unavailable
        if (configureNativeDevice && (!selection.unavailable || hifiOutputDeviceIdentity == null)) {
            nativePlayer?.setOutputDevice(selection.deviceToken)
        }
        if (selection.unavailable) {
            invalidateHifiEndpointVolume()
        } else if (refreshEndpointVolume) {
            refreshHifiEndpointVolume()
        }
    }

    private fun startAutomaticHifiOutputRecovery(intent: DesktopOutputRecoveryIntent) {
        if (!canAutomaticallyRecoverOutput(intent, nowPlaying?.id, hifiOutputDeviceIdentity)) return
        val generation = ++hifiOutputRecoveryGeneration
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                runDesktopOutputRecovery(
                    intent = intent,
                    driver = object : DesktopOutputRecoveryDriver {
                        override suspend fun awaitRetry(attempt: Int) {
                            val injectedDelay = testOverrides?.awaitRecoveryRetry
                            if (injectedDelay != null) injectedDelay(attempt)
                            else delay(desktopOutputRecoveryRetryDelayMillis(attempt))
                        }

                        override fun isRequestCurrent(): Boolean =
                            isCurrentHifiOutputRecovery(generation, intent)

                        override fun isSnapshotLoading(): Boolean = hifiOutputDevicesLoading

                        override suspend fun enumerateDevices(): List<DesktopAudioOutputDevice> =
                            enumerateHifiOutputDevices()

                        override fun applySnapshot(devices: List<DesktopAudioOutputDevice>) {
                            applyHifiOutputDeviceSnapshot(
                                devices,
                                configureNativeDevice = false,
                                refreshEndpointVolume = false,
                            )
                            hifiOutputDevicesError = null
                        }

                        override fun switchNativeOutput(deviceToken: String) {
                            runCatching { nativePlayer?.setOutputDevice(deviceToken) }
                        }

                        override fun refreshEndpointVolume() = refreshHifiEndpointVolume()

                        override fun resume(intent: DesktopOutputRecoveryIntent) =
                            resumeAfterOutputDeviceRefresh(fromAutomaticRecovery = true)

                        override fun onAttemptsExhausted() {
                            statusMessage = tr("status.hifi.device_lost_manual")
                        }
                    },
                )
            } finally {
                if (hifiOutputRecoveryGeneration == generation) {
                    hifiOutputRecoveryJob = null
                }
            }
        }
        hifiOutputRecoveryJob?.cancel()
        hifiOutputRecoveryJob = job
        job.start()
    }

    private fun isCurrentHifiOutputRecovery(
        generation: Long,
        intent: DesktopOutputRecoveryIntent,
    ): Boolean = hifiOutputRecoveryGeneration == generation &&
        hifiOutputRecoveryIntent === intent &&
        nowPlaying?.id == intent.trackId &&
        canAutomaticallyRecoverOutput(intent, nowPlaying?.id, hifiOutputDeviceIdentity)

    private fun clearHifiOutputRecoveryIntent(cancelJob: Boolean = true) {
        hifiOutputRecoveryIntent = null
        hifiOutputRecoveryGeneration += 1
        val job = hifiOutputRecoveryJob
        hifiOutputRecoveryJob = null
        if (cancelJob) job?.cancel()
        automaticResumeGuard.clear()
    }

    fun discoverNetworkRenderers() {
        networkRendererDiscoveryJob?.cancel()
        val generation = ++networkRendererDiscoveryGeneration
        networkRendererDiscoveryHasSearched = true
        networkRendererDiscoveryLoading = true
        networkRendererDiscoveryError = null
        networkRendererDiscoveryJob = scope.launch {
            try {
                val devices = networkRendererDiscovery.discover()
                if (generation == networkRendererDiscoveryGeneration) {
                    networkRendererDevices = devices
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (generation == networkRendererDiscoveryGeneration) {
                    networkRendererDiscoveryError = error.message ?: tr("settings.network_renderer.failed_generic")
                }
            } finally {
                if (generation == networkRendererDiscoveryGeneration) {
                    networkRendererDiscoveryLoading = false
                }
            }
        }
    }

    fun updateMpdHost(value: String) {
        if (mpdHost == value) return
        mpdHost = value
        invalidateMpdEndpointState()
    }

    fun updateMpdPort(value: String) {
        val filtered = value.filter(Char::isDigit).take(5)
        if (mpdPort == filtered) return
        mpdPort = filtered
        invalidateMpdEndpointState()
    }

    fun updateMpdPassword(value: String) {
        mpdPassword = value
    }

    fun updateMpdSearchQuery(value: String) {
        if (mpdSearchQuery == value) return
        mpdSearchQuery = value
        mpdSearchResults = emptyList()
        mpdSearchHasSearched = false
        mpdSearchOffset = 0
        mpdSearchTotalCount = 0
        mpdSearchHasMore = false
    }

    private fun invalidateMpdEndpointState() {
        mpdOperationGeneration++
        mpdOperationJob?.cancel()
        mpdOperationJob = null
        mpdPollingJob?.cancel()
        mpdPollingJob = null
        mpdLoading = false
        mpdStatus = null
        mpdSearchResults = emptyList()
        mpdSearchHasSearched = false
        mpdSearchOffset = 0
        mpdSearchTotalCount = 0
        mpdSearchHasMore = false
        mpdQueuePage = null
        mpdPassword = ""
        mpdError = null
    }

    fun connectMpd() {
        runMpdOperation { endpoint, password -> mpdClient.readStatus(endpoint, password) }
    }

    fun refreshMpdStatus() = connectMpd()

    fun searchMpdLibrary(offset: Int = 0) {
        val query = mpdSearchQuery.trim()
        if (query.isBlank()) {
            mpdError = tr("settings.mpd.search.empty")
            mpdSearchResults = emptyList()
            mpdSearchHasSearched = true
            mpdSearchOffset = 0
            mpdSearchTotalCount = 0
            mpdSearchHasMore = false
            return
        }
        val safeOffset = offset.coerceAtLeast(0)
        var results = emptyList<DesktopMpdTrack>()
        var totalCount = 0
        var pageOffset = safeOffset
        runMpdOperation({ endpoint, password ->
            val page = mpdClient.search(endpoint, query, offset = safeOffset, password = password)
            results = page.entries
            totalCount = page.totalCount
            pageOffset = page.offset
            mpdClient.readStatus(endpoint, password)
        }, onSuccess = {
            mpdSearchResults = results
            mpdSearchOffset = pageOffset
            mpdSearchTotalCount = totalCount
            mpdSearchHasMore = pageOffset + results.size < totalCount
            mpdSearchHasSearched = true
        })
    }

    fun refreshMpdQueue(requestedOffset: Int = mpdQueuePage?.offset ?: 0) {
        var queuePage: DesktopMpdQueuePage? = null
        runMpdOperation({ endpoint, password ->
            queuePage = mpdClient.readQueue(endpoint, requestedOffset, password = password)
            mpdClient.readStatus(endpoint, password)
        }, onSuccess = { mpdQueuePage = queuePage })
    }

    internal fun addMpdTrackToQueue(track: DesktopMpdTrack) {
        var queuePage: DesktopMpdQueuePage? = null
        runMpdOperation({ endpoint, password ->
            mpdClient.addToQueue(endpoint, track.uri, password)
            queuePage = mpdClient.readQueue(endpoint, mpdQueuePage?.offset ?: 0, password = password)
            mpdClient.readStatus(endpoint, password)
        }, onSuccess = { mpdQueuePage = queuePage })
    }

    internal fun playMpdTrackNow(track: DesktopMpdTrack) {
        var queuePage: DesktopMpdQueuePage? = null
        runMpdOperation({ endpoint, password ->
            val queueId = mpdClient.addToQueue(endpoint, track.uri, password)
            mpdClient.playQueueItem(endpoint, queueId, password)
            queuePage = mpdClient.readQueue(endpoint, mpdQueuePage?.offset ?: 0, password = password)
            mpdClient.readStatus(endpoint, password)
        }, onSuccess = { mpdQueuePage = queuePage })
    }

    fun playMpdQueueItem(queueId: Int) {
        runMpdOperation { endpoint, password ->
            mpdClient.playQueueItem(endpoint, queueId, password)
            mpdClient.readStatus(endpoint, password)
        }
    }

    fun removeMpdQueueItem(queueId: Int) {
        var queuePage: DesktopMpdQueuePage? = null
        runMpdOperation({ endpoint, password ->
            mpdClient.deleteQueueItem(endpoint, queueId, password)
            queuePage = mpdClient.readQueue(endpoint, mpdQueuePage?.offset ?: 0, password = password)
            mpdClient.readStatus(endpoint, password)
        }, onSuccess = { mpdQueuePage = queuePage })
    }

    fun playMpd() = runMpdOperation { endpoint, password ->
        mpdClient.play(endpoint, password)
        mpdClient.readStatus(endpoint, password)
    }

    fun pauseMpd() = runMpdOperation { endpoint, password ->
        mpdClient.pause(endpoint, password)
        mpdClient.readStatus(endpoint, password)
    }

    fun stopMpd() = runMpdOperation { endpoint, password ->
        mpdClient.stop(endpoint, password)
        mpdClient.readStatus(endpoint, password)
    }

    fun seekMpd(seconds: Double) {
        if (!seconds.isFinite() || seconds < 0.0) return
        runMpdOperation { endpoint, password ->
            mpdClient.seek(endpoint, seconds, password)
            mpdClient.readStatus(endpoint, password)
        }
    }

    fun adjustMpdVolume(delta: Int) {
        if (delta != -5 && delta != 5) return
        val nextVolume = (mpdStatus?.volumePercent ?: return) + delta
        if (nextVolume !in 0..100) return
        runMpdOperation { endpoint, password ->
            mpdClient.setVolume(endpoint, nextVolume, password)
            mpdClient.readStatus(endpoint, password)
        }
    }

    private fun runMpdOperation(operation: suspend (DesktopMpdEndpoint, String?) -> DesktopMpdStatus) {
        runMpdOperation(operation, onSuccess = {})
    }

    private fun runMpdOperation(
        operation: suspend (DesktopMpdEndpoint, String?) -> DesktopMpdStatus,
        onSuccess: () -> Unit,
    ) {
        val endpoint = DesktopMpdEndpoint(mpdHost.trim(), mpdPort.toIntOrNull() ?: 0)
        try {
            endpoint.validated()
        } catch (error: IllegalArgumentException) {
            mpdError = error.message ?: tr("settings.mpd.endpoint.invalid")
            return
        }
        val checkedEndpoint = endpoint.validated()
        DesktopSettings.mpdHost = checkedEndpoint.host
        DesktopSettings.mpdPort = checkedEndpoint.port
        mpdHost = checkedEndpoint.host
        mpdPort = checkedEndpoint.port.toString()
        val generation = ++mpdOperationGeneration
        val password = mpdPassword.takeIf(String::isNotEmpty)
        mpdOperationJob?.cancel()
        mpdPollingJob?.cancel()
        mpdPollingJob = null
        mpdLoading = true
        mpdError = null
        mpdOperationJob = scope.launch {
            try {
                val result = operation(checkedEndpoint, password)
                if (generation == mpdOperationGeneration) {
                    mpdStatus = result
                    onSuccess()
                    startMpdPolling(checkedEndpoint, generation, result.state, password)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (generation == mpdOperationGeneration) {
                    mpdError = error.message ?: tr("settings.mpd.failed_generic")
                    mpdStatus = null
                }
            } finally {
                if (generation == mpdOperationGeneration) mpdLoading = false
            }
        }
    }

    private fun startMpdPolling(endpoint: DesktopMpdEndpoint, generation: Long, state: String, password: String?) {
        if (!state.equals("play", ignoreCase = true)) return
        mpdPollingJob = scope.launch {
            try {
                while (isActive && generation == mpdOperationGeneration) {
                    delay(MPD_STATUS_POLL_MILLIS)
                    if (!isActive || generation != mpdOperationGeneration) break
                    val refreshed = mpdClient.readStatus(endpoint, password)
                    if (!isActive || generation != mpdOperationGeneration) break
                    val queue = mpdQueuePage
                    if (queue != null && queue.playlistVersion != refreshed.playlistVersion) {
                        mpdQueuePage = mpdClient.readQueue(endpoint, queue.offset, password = password)
                    }
                    mpdStatus = refreshed
                    if (!refreshed.state.equals("play", ignoreCase = true)) break
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (generation == mpdOperationGeneration) {
                    mpdError = error.message ?: tr("settings.mpd.failed_generic")
                    mpdStatus = null
                }
            } finally {
                if (generation == mpdOperationGeneration) mpdPollingJob = null
            }
        }
    }

    internal fun refreshNetworkRendererStatus(device: DesktopUpnpRendererDevice) {
        runNetworkRendererOperation(device) {
            if (shouldUseOpenHomePlaylist(device)) readOpenHomeRendererStatus(device)
            else networkRendererClient.readStatus(device)
        }
    }

    internal fun setNetworkRendererVolume(device: DesktopUpnpRendererDevice, volume: Int) {
        runNetworkRendererOperation(device) { networkRendererClient.setVolume(device, volume) }
    }

    internal fun adjustNetworkRendererVolume(device: DesktopUpnpRendererDevice, delta: Int) {
        runNetworkRendererOperation(device) { networkRendererClient.adjustVolume(device, delta) }
    }

    internal fun seekNetworkRenderer(device: DesktopUpnpRendererDevice, positionMillis: Long) {
        if (positionMillis < 0L) return
        val activeAtSeek = networkRendererActiveMediaPlayback
            ?.takeIf { it.device.identity == device.identity }
        runNetworkRendererOperation(device) {
            val before = networkRendererClient.readStatus(device)
            if (!desktopUpnpRelativeTimeSeekEnabled(before)) {
                throw IOException(tr("settings.network_renderer.action_unsupported", "Seek"))
            }
            val duration = before.durationMillis
                ?: throw IOException(tr("settings.network_renderer.seek_position_unavailable"))
            val target = positionMillis.coerceAtMost(duration)
            networkRendererClient.seek(device, target)
            activeAtSeek?.takeIf { networkRendererActiveMediaPlayback?.sessionToken === it.sessionToken }?.let { active ->
                active.recoveryState.recordUserSeek(
                    expectedUri = active.current.lease.mediaUri.toASCIIString(),
                    observedUri = before.trackUri,
                    transportState = before.transportState,
                    positionMillis = target,
                    durationMillis = duration,
                )
            }
            networkRendererClient.readStatus(device).also { after ->
                activeAtSeek
                    ?.takeIf { networkRendererActiveMediaPlayback?.sessionToken === it.sessionToken }
                    ?.let { active ->
                        active.recoveryState.recordUserSeek(
                            expectedUri = active.current.lease.mediaUri.toASCIIString(),
                            observedUri = after.trackUri,
                            transportState = after.transportState,
                            positionMillis = after.positionMillis ?: target,
                            durationMillis = after.durationMillis ?: duration,
                        )
                    }
            }
        }
    }

    internal fun controlNetworkRenderer(device: DesktopUpnpRendererDevice, command: DesktopUpnpTransportCommand) {
        val useOpenHomePlaylist = shouldUseOpenHomePlaylist(device)
        val openHomeSession = openHomeActiveQueueSessions[device.identity].takeIf { useOpenHomePlaylist }
        val openHomeCommandRevision = openHomeSession?.recordTransportCommand(command)
        val activeAtStop = networkRendererActiveMediaPlayback
            ?.takeIf { it.device.identity == device.identity }
        if (!useOpenHomePlaylist) when (command) {
            DesktopUpnpTransportCommand.PLAY -> {
                activeAtStop?.explicitStopRequested?.set(false)
                activeAtStop?.recoveryState?.requestPlay()
                activeAtStop?.recoveryRetryAfterNanos = 0L
                activeAtStop?.recoveryFailureCount = 0
            }
            DesktopUpnpTransportCommand.PAUSE -> {
                activeAtStop?.recoveryState?.requestPause()
                activeAtStop?.recoveryRetryAfterNanos = 0L
                activeAtStop?.recoveryFailureCount = 0
            }
            DesktopUpnpTransportCommand.STOP -> {
                activeAtStop?.explicitStopRequested?.set(true)
                activeAtStop?.recoveryState?.cancel()
            }
        }
        if (networkRendererOperationLoadingIdentity != null) {
            if (openHomeSession != null) {
                networkRendererDeferredOpenHomeCommands[device.identity] = openHomeSession.device to command
            } else if (command == DesktopUpnpTransportCommand.STOP) {
                networkRendererDeferredStopDevice = device
            }
            return
        }
        runNetworkRendererOperation(device) {
            if (useOpenHomePlaylist) {
                val activeSession = openHomeSession
                if (activeSession != null) {
                    return@runNetworkRendererOperation activeSession.operationMutex.withLock {
                        val targetDevice = activeSession.device
                        if (activeSession.transportCommandRevision.get() != openHomeCommandRevision) {
                            return@withLock readOpenHomeRendererStatus(targetDevice)
                        }
                        when (command) {
                            DesktopUpnpTransportCommand.PLAY -> openHomePlaylistClient.play(targetDevice)
                            DesktopUpnpTransportCommand.PAUSE -> openHomePlaylistClient.pause(targetDevice)
                            DesktopUpnpTransportCommand.STOP -> openHomePlaylistClient.stop(targetDevice)
                        }
                        val status = readOpenHomeRendererStatus(targetDevice)
                        if (desktopOpenHomeCommandMatches(command, status)) {
                            activeSession.clearTransportCommand(command, checkNotNull(openHomeCommandRevision))
                            if (command == DesktopUpnpTransportCommand.PLAY) {
                                openHomeMediaDevices[targetDevice.identity] = targetDevice
                                openHomeActiveTargetIdentity = targetDevice.identity
                            } else if (command == DesktopUpnpTransportCommand.STOP &&
                                openHomeActiveTargetIdentity == targetDevice.identity
                            ) {
                                openHomeActiveTargetIdentity = null
                            }
                        }
                        status
                    }
                } else {
                    when (command) {
                        DesktopUpnpTransportCommand.PLAY -> openHomePlaylistClient.play(device)
                        DesktopUpnpTransportCommand.PAUSE -> openHomePlaylistClient.pause(device)
                        DesktopUpnpTransportCommand.STOP -> openHomePlaylistClient.stop(device)
                    }
                    return@runNetworkRendererOperation readOpenHomeRendererStatus(device)
                }
            }
            var commandError: Exception? = null
            try {
                val action = when (command) {
                    DesktopUpnpTransportCommand.PLAY -> "Play"
                    DesktopUpnpTransportCommand.PAUSE -> "Pause"
                    DesktopUpnpTransportCommand.STOP -> "Stop"
                }
                // Stop intent is latched before any network work. Do not let a failed status
                // pre-read turn an explicit Stop into a future automatic Play.
                if (command != DesktopUpnpTransportCommand.STOP) {
                    val before = networkRendererClient.readStatus(device)
                    if (!desktopUpnpActionEnabled(before, action)) {
                        throw IOException(tr("settings.network_renderer.action_unsupported", action))
                    }
                }
                networkRendererClient.control(device, command)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                commandError = error
            }
            if (command == DesktopUpnpTransportCommand.STOP && commandError == null) {
                closeActiveNetworkRendererMediaPlayback(device.identity)
            }
            val status = networkRendererClient.readStatus(device)
            activeAtStop
                ?.takeIf { networkRendererActiveMediaPlayback?.sessionToken === it.sessionToken }
                ?.let { active ->
                    active.recoveryState.observePlaybackPosition(
                        expectedUri = active.current.lease.mediaUri.toASCIIString(),
                        observedUri = status.trackUri,
                        transportState = status.transportState,
                        positionMillis = status.positionMillis,
                        durationMillis = status.durationMillis,
                    )
                }
            if (commandError != null) {
                networkRendererStatusByIdentity = networkRendererStatusByIdentity + (device.identity to status)
                throw IOException("${commandError.message ?: commandError.javaClass.simpleName}. Renderer state was read again.")
            }
            status
        }
    }

    internal fun skipNetworkRendererPlaylist(device: DesktopUpnpRendererDevice, previous: Boolean) {
        if (!shouldUseOpenHomePlaylist(device)) return
        val session = openHomeActiveQueueSessions[device.identity]
        runNetworkRendererOperation(device) {
            suspend fun skip(targetDevice: DesktopUpnpRendererDevice): DesktopUpnpRendererStatus {
                // Read first so that an empty/unavailable queue is reported before sending a control
                // action. The OpenHome client validates the action signature against SCPD.
                openHomeQueueCoordinator.readSnapshot(targetDevice)
                if (previous) openHomePlaylistClient.previous(targetDevice) else openHomePlaylistClient.next(targetDevice)
                if (openHomeActiveTargetIdentity == targetDevice.identity) {
                    openHomeMediaDevices[targetDevice.identity] = targetDevice
                }
                return readOpenHomeRendererStatus(targetDevice)
            }
            if (session != null) {
                session.operationMutex.withLock { skip(session.device) }
            } else {
                skip(device)
            }
        }
    }

    internal fun usesOpenHomePlaylistForControls(device: DesktopUpnpRendererDevice): Boolean =
        desktopUpnpShouldUseOpenHomePlaylist(
            device = device,
            activeAvSessionIdentity = networkRendererActiveMediaPlayback
                ?.takeIf { it.device.identity == device.identity }
                ?.device?.identity,
        )

    private fun shouldUseOpenHomePlaylist(device: DesktopUpnpRendererDevice): Boolean =
        usesOpenHomePlaylistForControls(device)

    private suspend fun readOpenHomeRendererStatus(
        device: DesktopUpnpRendererDevice,
    ): DesktopUpnpRendererStatus = desktopOpenHomeRendererStatus(openHomeQueueCoordinator.readSnapshot(device))

    private suspend fun pauseOpenHomeActiveQueuePolling(
        deviceIdentity: String,
    ): DesktopOpenHomeActiveQueueSession? {
        val session = openHomeActiveQueueSessions[deviceIdentity] ?: return null
        val job = synchronized(session) {
            session.pollingJob.also { session.pollingJob = null }
        }
        withContext(NonCancellable) { job?.cancelAndJoin() }
        return session.takeIf { openHomeActiveQueueSessions[deviceIdentity] === session }
    }

    private fun resumeOpenHomeActiveQueuePolling(session: DesktopOpenHomeActiveQueueSession?) {
        if (session != null) startOpenHomeActiveQueuePolling(session)
    }

    private fun startOpenHomeActiveQueuePolling(session: DesktopOpenHomeActiveQueueSession) {
        synchronized(session) {
            if (openHomeActiveQueueSessions[session.device.identity] !== session || !controllerJob.isActive) return
            if (session.pollingJob?.isActive == true) return
            val job = scope.launch(start = CoroutineStart.LAZY) {
                val ownJob = currentCoroutineContext()[Job]
                try {
                    pollOpenHomeActiveQueue(session)
                } finally {
                    synchronized(session) {
                        if (session.pollingJob === ownJob) session.pollingJob = null
                    }
                }
            }
            session.pollingJob = job
            job.start()
        }
        startOpenHomeGenaSubscription(session)
    }

    private fun startOpenHomeGenaSubscription(session: DesktopOpenHomeActiveQueueSession) {
        val device = session.device
        synchronized(session) {
            if (session.device !== device || openHomeActiveQueueSessions[device.identity] !== session || !controllerJob.isActive ||
                session.eventSubscriptionJob?.isActive == true
            ) return
            val job = scope.launch(start = CoroutineStart.LAZY) {
                val ownJob = currentCoroutineContext()[Job]
                try {
                    while (currentCoroutineContext().isActive &&
                        session.device === device && openHomeActiveQueueSessions[device.identity] === session
                    ) {
                        if (!session.eventReceiverRetryPolicy.isAttemptDue(System.nanoTime())) {
                            delay(OPENHOME_QUEUE_POLL_INTERVAL_MILLIS)
                            continue
                        }
                        val resources = session.mediaResources ?: return@launch
                        val endpoint = device.services[DesktopUpnpRendererServiceKind.OPENHOME_PLAYLIST]?.eventSubUri
                        if (!endpoint?.scheme.equals("http", ignoreCase = true)) return@launch

                        try {
                            val capabilities = withContext(Dispatchers.IO) {
                                openHomePlaylistClient.capabilities(device)
                            }
                            if (capabilities.eventedStateVariables.keys.none { it in OPENHOME_EVENT_WAKE_PROPERTIES }) {
                                return@launch
                            }
                            val rendererAddress = desktopUpnpNumericAddress(device.descriptionUri)
                                ?: return@launch
                            var createdReceiver: DesktopUpnpEventReceiver? = null
                            val receiver = try {
                                withContext(NonCancellable + Dispatchers.IO) {
                                    lateinit var receiverRef: DesktopUpnpEventReceiver
                                    receiverRef = DesktopUpnpEventReceiver(
                                        bindAddress = resources.localAddress,
                                        rendererAddress = rendererAddress,
                                        maxEventBodyBytes = DESKTOP_OPENHOME_MAX_GENA_EVENT_BODY_BYTES,
                                        onEvent = {
                                            if (session.device === device && openHomeActiveQueueSessions[device.identity] === session &&
                                                session.eventReceiver === receiverRef
                                            ) {
                                                session.eventRefreshRequests.trySend(Unit)
                                            }
                                        },
                                    ).also { createdReceiver = it }
                                    receiverRef
                                }
                            } catch (error: Throwable) {
                                createdReceiver?.close()
                                throw error
                            }
                            val installed = synchronized(session) {
                                if (session.device === device && openHomeActiveQueueSessions[device.identity] === session &&
                                    session.mediaResources === resources && session.eventReceiver == null &&
                                    session.genaBindingState.attach(receiver, device, rendererAddress)
                                ) {
                                    true
                                } else {
                                    false
                                }
                            }
                            if (!installed) {
                                receiver.close()
                                return@launch
                            }
                            session.eventReceiverRetryPolicy.reset()
                            runOpenHomeGenaSubscriptionManager(
                                session,
                                device,
                                receiver,
                                rendererAddress,
                                resources.localAddress,
                                CoroutineScope(currentCoroutineContext()),
                            )
                            return@launch
                        } catch (error: CancellationException) {
                            throw error
                        } catch (_: Exception) {
                            if (session.device !== device || openHomeActiveQueueSessions[device.identity] !== session) return@launch
                            if (session.eventReceiver != null) {
                                closeOpenHomeGenaSubscription(session, closeRefreshChannel = false)
                            }
                            session.eventReceiverRetryPolicy.recordFailure(System.nanoTime())
                            delay(OPENHOME_QUEUE_POLL_INTERVAL_MILLIS)
                        }
                    }
                } finally {
                    synchronized(session) {
                        if (session.eventSubscriptionJob === ownJob) session.eventSubscriptionJob = null
                    }
                }
            }
            session.eventSubscriptionJob = job
            job.start()
        }
    }

    private suspend fun runOpenHomeGenaSubscriptionManager(
        session: DesktopOpenHomeActiveQueueSession,
        device: DesktopUpnpRendererDevice,
        receiver: DesktopUpnpEventReceiver,
        rendererAddress: InetAddress,
        localAddress: InetAddress,
        parentScope: CoroutineScope,
    ) {
        val serviceKind = DesktopUpnpRendererServiceKind.OPENHOME_PLAYLIST
        DesktopUpnpGenaSubscriptionManager(
            initialLease = session.eventLease,
            refreshRequests = session.genaRefreshRequests,
            retryDelayMillis = RETRY_UPNP_EVENT_SUBSCRIPTION_MILLIS,
            isCurrent = {
                session.device === device && openHomeActiveQueueSessions[device.identity] === session &&
                    session.eventReceiver === receiver
            },
            subscribe = {
                withContext(Dispatchers.IO) {
                    networkRendererGenaClient.subscribe(
                        device,
                        rendererAddress,
                        localAddress,
                        receiver.callbackUri,
                        serviceKind = serviceKind,
                    )
                }
            },
            renew = { sid ->
                withContext(Dispatchers.IO) {
                    networkRendererGenaClient.renew(
                        device,
                        rendererAddress,
                        localAddress,
                        sid,
                        serviceKind = serviceKind,
                    )
                }
            },
            installLease = { lease ->
                synchronized(session) {
                if (session.device === device && openHomeActiveQueueSessions[device.identity] === session &&
                    session.eventReceiver === receiver && session.genaBindingState.installLease(receiver, lease)
                ) {
                    receiver.acceptSid(lease.sid)
                    true
                    } else {
                        false
                    }
                }
            },
            onLeaseChanged = { lease ->
                synchronized(session) {
                    session.genaBindingState.updateLease(receiver, lease)
                }
            },
            onSidCleared = {
                val cleared = synchronized(session) { session.genaBindingState.clearLease(receiver) }
                if (cleared) {
                        receiver.clearSid()
                }
            },
            abandonLease = { lease ->
                withContext(Dispatchers.IO) {
                    runCatching {
                        networkRendererGenaClient.unsubscribe(
                            device,
                            rendererAddress,
                            localAddress,
                            lease.sid,
                            serviceKind = serviceKind,
                        )
                    }
                }
            },
        ).start(parentScope).join()
    }

    private fun closeOpenHomeGenaSubscription(
        session: DesktopOpenHomeActiveQueueSession,
        closeRefreshChannel: Boolean,
    ) {
        val (detached, subscriptionJob) = synchronized(session) {
            val active = session.genaBindingState.detach(session.device)
            // Clearing eventReceiver under the same lock used by installLease fences any in-flight
            // SUBSCRIBE result. Its manager will then abandon that new SID against the captured device.
            val job = session.eventSubscriptionJob
            session.eventSubscriptionJob = null
            active to job
        }
        subscriptionJob?.cancel()
        detached.receiver?.let {
            runCatching { it.clearSid() }
            runCatching { it.close() }
        }
        if (closeRefreshChannel) {
            session.eventRefreshRequests.close()
            session.genaRefreshRequests.close()
        }
        val localAddress = detached.receiver?.localAddress?.address
        if (detached.lease != null && localAddress != null) {
            val remoteAddress = detached.rendererAddress
                ?: desktopUpnpNumericAddress(detached.device.descriptionUri) ?: return
            Thread({
                runCatching {
                    networkRendererGenaClient.unsubscribe(
                        detached.device,
                        remoteAddress,
                        localAddress,
                        detached.lease.sid,
                        serviceKind = DesktopUpnpRendererServiceKind.OPENHOME_PLAYLIST,
                    )
                }
            }, "openhome-gena-unsubscribe").apply {
                isDaemon = true
                start()
            }
        }
    }

    private suspend fun pollOpenHomeActiveQueue(session: DesktopOpenHomeActiveQueueSession) {
        var nextDelayMillis = OPENHOME_QUEUE_POLL_INTERVAL_MILLIS
        while (currentCoroutineContext().isActive) {
            withTimeoutOrNull(nextDelayMillis) { session.eventRefreshRequests.receive() }
            if (openHomeActiveQueueSessions[session.device.identity] !== session) return
            val (snapshot, snapshotIsCurrent) = try {
                withContext(Dispatchers.IO) {
                    val previous = session.lastSnapshot
                    val light = openHomeQueueCoordinator.readCurrentState(session.device, previous)
                    if (light != null) {
                        light to true
                    } else {
                        val full = openHomeQueueCoordinator.readSnapshot(session.device)
                        full to openHomeQueueCoordinator.snapshotStillCurrent(session.device, full)
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                session.consecutivePollFailures = (session.consecutivePollFailures + 1).coerceAtMost(5)
                val errorMessage = error.message ?: "OpenHome status read failed."
                networkRendererOperationErrors = networkRendererOperationErrors + (
                    session.device.identity to errorMessage
                )
                if (session.consecutivePollFailures >= 2) {
                    val currentStatus = networkRendererStatusByIdentity[session.device.identity] ?: DesktopUpnpRendererStatus()
                    networkRendererStatusByIdentity = networkRendererStatusByIdentity + (
                        session.device.identity to currentStatus.copy(
                            connectionState = DesktopUpnpConnectionState.UNKNOWN,
                            connectionError = errorMessage,
                        )
                    )
                }
                val recovered = recoverOpenHomeActiveQueueAfterDisconnect(session)
                if (recovered != null) {
                    session.lastSnapshot = recovered
                    updateOpenHomeActiveQueueState(session, recovered)
                    nextDelayMillis = OPENHOME_QUEUE_POLL_INTERVAL_MILLIS
                    continue
                }
                nextDelayMillis = (nextDelayMillis * 2).coerceAtMost(OPENHOME_QUEUE_POLL_MAX_BACKOFF_MILLIS)
                continue
            }
            if (openHomeActiveQueueSessions[session.device.identity] !== session) return
            if (!snapshotIsCurrent) {
                nextDelayMillis = (nextDelayMillis * 2).coerceAtMost(OPENHOME_QUEUE_POLL_MAX_BACKOFF_MILLIS)
                continue
            }

            // A stable Playlist read proves the renderer is reachable even if a local route
            // rebind, MIME negotiation, or lease operation below later fails.
            session.consecutivePollFailures = 0
            session.reconnectBackoff.reset()
            session.lastSnapshot = snapshot
            updateOpenHomeActiveQueueState(session, snapshot)
            networkRendererOperationErrors = networkRendererOperationErrors - session.device.identity
            try {
                val confirmedSnapshot = recoverOpenHomeActiveQueueRouteIfNeeded(session, snapshot)
                if (openHomeActiveQueueSessions[session.device.identity] !== session) return
                if (confirmedSnapshot != snapshot) {
                    session.lastSnapshot = confirmedSnapshot
                    updateOpenHomeActiveQueueState(session, confirmedSnapshot)
                }
                try {
                    openHomeMediaRetention.reconcile(
                        deviceIdentity = session.device.identity,
                        snapshotDeviceIdentity = session.device.identity,
                        snapshot = confirmedSnapshot,
                        snapshotStillCurrent = true,
                    )
                } catch (error: Exception) {
                    networkRendererOperationErrors = networkRendererOperationErrors + (
                        session.device.identity to (error.message ?: "Could not reconcile OpenHome media leases.")
                    )
                }
                nextDelayMillis = OPENHOME_QUEUE_POLL_INTERVAL_MILLIS
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                val errorMessage = error.message ?: "OpenHome route recovery failed."
                networkRendererOperationErrors = networkRendererOperationErrors + (
                    session.device.identity to errorMessage
                )
                nextDelayMillis = (nextDelayMillis * 2).coerceAtMost(OPENHOME_QUEUE_POLL_MAX_BACKOFF_MILLIS)
            }
        }
    }

    private suspend fun recoverOpenHomeActiveQueueAfterDisconnect(
        session: DesktopOpenHomeActiveQueueSession,
    ): DesktopOpenHomeQueueSnapshot? {
        val nowNanos = System.nanoTime()
        if (!session.reconnectBackoff.isAttemptDue(nowNanos)) return null

        var descriptorChanged = false
        try {
            val discoveredDevices = withContext(Dispatchers.IO) {
                DesktopUpnpRendererDiscovery().discover(timeoutMillis = 1_000L)
            }
            val recoveryDevice = selectDesktopOpenHomeRecoveryDevice(session.device.identity, discoveredDevices)
                ?: throw IOException("The same OpenHome renderer was not found during rediscovery.")
            if (openHomeActiveQueueSessions[session.device.identity] !== session) return null
            val confirmedSnapshot = session.operationMutex.withLock {
                if (openHomeActiveQueueSessions[session.device.identity] !== session) return@withLock null
                val recoveryRendererAddress = desktopUpnpNumericAddress(recoveryDevice.descriptionUri)
                    ?: throw IOException("The rediscovered OpenHome renderer address is unavailable.")

                openHomePlaylistClient.invalidateCapabilities(recoveryDevice)
                val (snapshot, snapshotIsCurrent) = withContext(Dispatchers.IO) {
                    val stableSnapshot = openHomeQueueCoordinator.readSnapshot(recoveryDevice)
                    stableSnapshot to openHomeQueueCoordinator.snapshotStillCurrent(recoveryDevice, stableSnapshot)
                }
                if (!snapshotIsCurrent) {
                    throw IOException("The rediscovered OpenHome queue did not produce a stable snapshot.")
                }
                if (openHomeActiveQueueSessions[session.device.identity] !== session) return@withLock null

                val previousDevice = session.device
                if (recoveryDevice != previousDevice) {
                    // Fence and retire the old SID before making the new descriptor visible.
                    closeOpenHomeGenaSubscription(session, closeRefreshChannel = false)
                    session.device = recoveryDevice
                    openHomeMediaDevices[recoveryDevice.identity] = recoveryDevice
                    networkRendererDevices = if (networkRendererDevices.any { it.identity == recoveryDevice.identity }) {
                        networkRendererDevices.map { device ->
                            if (device.identity == recoveryDevice.identity) recoveryDevice else device
                        }
                    } else {
                        networkRendererDevices + recoveryDevice
                    }
                    descriptorChanged = true
                }

                session.lastSnapshot = snapshot
                updateOpenHomeActiveQueueState(session, snapshot)
                val reboundSnapshot = recoverOpenHomeActiveQueueRouteIfNeededLocked(session, snapshot)
                if (openHomeActiveQueueSessions[session.device.identity] !== session) return@withLock null
                if (reboundSnapshot != snapshot) {
                    session.lastSnapshot = reboundSnapshot
                    updateOpenHomeActiveQueueState(session, reboundSnapshot)
                }
                openHomeMediaRetention.reconcile(
                    deviceIdentity = session.device.identity,
                    snapshotDeviceIdentity = session.device.identity,
                    snapshot = reboundSnapshot,
                    snapshotStillCurrent = true,
                )
                reboundSnapshot
            }
            if (confirmedSnapshot == null) return null
            session.consecutivePollFailures = 0
            session.reconnectBackoff.reset()
            if (descriptorChanged) startOpenHomeGenaSubscription(session)
            networkRendererOperationErrors = networkRendererOperationErrors - session.device.identity
            return confirmedSnapshot
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            session.reconnectBackoff.recordFailure(System.nanoTime())
            networkRendererOperationErrors = networkRendererOperationErrors + (
                session.device.identity to (error.message ?: "OpenHome renderer rediscovery failed.")
            )
            if (descriptorChanged) startOpenHomeGenaSubscription(session)
            return null
        }
    }

    private suspend fun recoverOpenHomeActiveQueueRouteIfNeeded(
        session: DesktopOpenHomeActiveQueueSession,
        snapshot: DesktopOpenHomeQueueSnapshot,
    ): DesktopOpenHomeQueueSnapshot {
        val resources = session.mediaResources ?: return snapshot
        if (session.binding == null || session.localTracks == null) return snapshot
        val rendererAddress = desktopUpnpNumericAddress(session.device.descriptionUri) ?: return snapshot
        val routeAddress = withContext(Dispatchers.IO) {
            DesktopUpnpMediaServer.routeLocalAddress(
                rendererAddress,
                openHomeRendererRoutePort(session.device),
            )
        }
        val routeChanged = routeAddress != resources.localAddress ||
            rendererAddress != session.boundRendererAddress ||
            session.device != session.boundDeviceDescriptor
        if (!routeChanged) return snapshot

        return session.operationMutex.withLock {
            val (latestSnapshot, latestIsCurrent) = withContext(Dispatchers.IO) {
                val latest = openHomeQueueCoordinator.readSnapshot(session.device)
                latest to openHomeQueueCoordinator.snapshotStillCurrent(session.device, latest)
            }
            if (!latestIsCurrent) {
                throw IOException("OpenHome Playlist changed while route recovery was waiting to run.")
            }
            recoverOpenHomeActiveQueueRouteIfNeededLocked(session, latestSnapshot)
        }
    }

    private suspend fun recoverOpenHomeActiveQueueRouteIfNeededLocked(
        session: DesktopOpenHomeActiveQueueSession,
        snapshot: DesktopOpenHomeQueueSnapshot,
    ): DesktopOpenHomeQueueSnapshot {
        val resources = session.mediaResources ?: return snapshot
        val binding = session.binding ?: return snapshot
        val localTracks = session.localTracks ?: return snapshot
        val rendererAddress = desktopUpnpNumericAddress(session.device.descriptionUri) ?: return snapshot
        val routeAddress = withContext(Dispatchers.IO) {
            DesktopUpnpMediaServer.routeLocalAddress(
                rendererAddress,
                openHomeRendererRoutePort(session.device),
            )
        }
        val plan = planDesktopOpenHomeRouteRecovery(
            deviceIdentity = session.device.identity,
            generation = session.generation,
            binding = binding,
            snapshot = snapshot,
            snapshotStillCurrent = true,
            localTrackCount = localTracks.size,
            routeChanged = routeAddress != resources.localAddress ||
                rendererAddress != session.boundRendererAddress ||
                session.device != session.boundDeviceDescriptor,
            intentOverride = session.requestedTransportCommand?.let(::desktopOpenHomePlaybackIntentFor),
        ) ?: return snapshot
        if (openHomeActiveQueueSessions[session.device.identity] !== session ||
            session.binding !== binding || session.mediaResources !== resources
        ) return snapshot

        val requiredActions = buildList {
            addAll(listOf("TracksMax", "IdArray", "IdArrayChanged", "Id", "ReadList", "DeleteAll", "Insert", "SeekId"))
            add(when (plan.intent) {
                DesktopOpenHomePlaybackIntent.PLAY -> "Play"
                DesktopOpenHomePlaybackIntent.PAUSE -> "Pause"
                DesktopOpenHomePlaybackIntent.STOP -> "Stop"
            })
        }
        val capabilities = openHomePlaylistClient.capabilities(session.device)
        requiredActions.firstOrNull { it !in capabilities.actions }?.let { missing ->
            throw IOException("OpenHome Playlist does not advertise $missing for route recovery.")
        }
        val protocolInfo = openHomePlaylistClient.protocolInfo(session.device)
        val replacementMimeTypes = resources.queue.map { media ->
            val source = media.track.playbackSource as? DesktopTrackSource.LocalFile
                ?: throw IOException("OpenHome route recovery requires local-file queue sources.")
            chooseDesktopUpnpHttpMime(
                protocolInfo,
                desktopUpnpMimeCandidates(source.absolutePath),
            ) ?: throw IOException("The rediscovered OpenHome renderer does not advertise a supported queue format.")
        }

        var stagedServer: DesktopUpnpMediaServer? = null
        var stagedResources: DesktopUpnpMediaResources? = null
        var stagedRegistrationCreated = false
        var queueMutationMayHaveReachedRenderer = false
        try {
            val server = withContext(NonCancellable + Dispatchers.IO) {
                DesktopUpnpMediaServer(
                    bindAddress = routeAddress,
                    rendererAddress = rendererAddress,
                    leaseTtl = java.time.Duration.ofHours(12),
                ).also { stagedServer = it }
            }
            val replacementMedia = withContext(Dispatchers.IO) {
                try {
                    resources.queue.mapIndexed { index, media ->
                        val mimeType = replacementMimeTypes[index]
                        val lease = server.reissueLease(media.lease, mimeType)
                            ?: throw IOException("A local source changed while its OpenHome route was being rebound.")
                        DesktopUpnpQueuedMedia(media.track, mimeType, lease)
                    }
                } catch (error: Throwable) {
                    server.close()
                    throw error
                }
            }
            stagedResources = DesktopUpnpMediaResources(replacementMedia, server, routeAddress)
            openHomeMediaRetention.register(
                deviceIdentity = session.device.identity,
                uris = replacementMedia.mapTo(linkedSetOf()) { it.lease.mediaUri.toASCIIString() },
                close = { checkNotNull(stagedResources).close() },
                renew = {
                    val allRenewed = withContext(Dispatchers.IO) {
                        replacementMedia.map { it.lease.renew() }.all { it }
                    }
                    if (!allRenewed) throw IOException("One or more rebound OpenHome media leases could not be renewed.")
                },
            )
            stagedRegistrationCreated = true
            ensureOpenHomeMediaLeaseRenewal()

            val candidates = replacementMedia.mapIndexed { index, media ->
                DesktopOpenHomeQueueCandidate(
                    localIndex = index,
                    uri = media.lease.mediaUri.toASCIIString(),
                    metadata = buildDesktopUpnpDidlMetadata(
                        title = media.track.title,
                        artist = media.track.artist,
                        album = media.track.album,
                        resourceUri = media.lease.mediaUri,
                        mimeType = media.mimeType,
                        fileSize = media.lease.fileSize,
                        durationMillis = media.track.durationMillis,
                    ),
                )
            }
            val actionIntent = session.requestedTransportCommand
                ?.let(::desktopOpenHomePlaybackIntentFor)
                ?: plan.intent
            val requiredTransportAction = when (actionIntent) {
                DesktopOpenHomePlaybackIntent.PLAY -> "Play"
                DesktopOpenHomePlaybackIntent.PAUSE -> "Pause"
                DesktopOpenHomePlaybackIntent.STOP -> "Stop"
            }
            if (requiredTransportAction !in capabilities.actions) {
                throw IOException("OpenHome Playlist does not advertise $requiredTransportAction for route recovery.")
            }
            queueMutationMayHaveReachedRenderer = true
            val replacement = openHomeQueueCoordinator.replace(session.device, snapshot, candidates)
            if (replacement !is DesktopOpenHomeQueueReplacement.Replaced) {
                replacement as DesktopOpenHomeQueueReplacement.Failed
                throw IOException(replacement.message, replacement.cause)
            }
            val selectedId = replacement.idToLocalIndex.entries
                .singleOrNull { it.value == plan.localIndex }
                ?.key ?: throw IOException("OpenHome route recovery did not return an ID for the current track.")

            openHomePlaylistClient.seekId(session.device, selectedId)
            when (actionIntent) {
                DesktopOpenHomePlaybackIntent.PLAY -> openHomePlaylistClient.play(session.device)
                DesktopOpenHomePlaybackIntent.PAUSE -> openHomePlaylistClient.pause(session.device)
                DesktopOpenHomePlaybackIntent.STOP -> openHomePlaylistClient.stop(session.device)
            }
            val confirmed = openHomeQueueCoordinator.readSnapshot(session.device)
            val expectedUriById = replacement.idToLocalIndex.mapValues { (_, localIndex) ->
                replacementMedia.getOrNull(localIndex)?.lease?.mediaUri?.toASCIIString()
                    ?: throw IOException("OpenHome route recovery refers to a missing local track.")
            }
            if (confirmed.token != replacement.token ||
                confirmed.ids != replacement.idToLocalIndex.keys.toList() ||
                confirmed.currentId != selectedId ||
                confirmed.tracksById[selectedId]?.uri != expectedUriById[selectedId] ||
                !openHomeIntentMatches(actionIntent, confirmed.transportState) ||
                !openHomeQueueCoordinator.snapshotStillCurrent(session.device, confirmed)
            ) {
                throw IOException("OpenHome Playlist did not confirm the rebound route, current track, and playback state.")
            }
            val reboundBinding = DesktopOpenHomeActiveQueueBinding.create(
                deviceIdentity = session.device.identity,
                generation = session.generation,
                snapshot = confirmed,
                idToLocalIndex = replacement.idToLocalIndex,
                expectedUriById = expectedUriById,
                snapshotStillCurrent = true,
            ) ?: throw IOException("OpenHome route recovery did not produce a complete local queue binding.")
            if (openHomeActiveQueueSessions[session.device.identity] !== session ||
                session.binding !== binding || session.mediaResources !== resources
            ) throw CancellationException("OpenHome route recovery session was superseded.")

            closeOpenHomeGenaSubscription(session, closeRefreshChannel = false)
            session.mediaResources = checkNotNull(stagedResources)
            session.boundRendererAddress = rendererAddress
            session.boundDeviceDescriptor = session.device
            session.binding = reboundBinding
            session.lastSnapshot = confirmed
            startOpenHomeGenaSubscription(session)
            networkRendererOperationErrors = networkRendererOperationErrors - session.device.identity
            return confirmed
        } catch (error: CancellationException) {
            withContext(NonCancellable) {
                runCatching { reconcileOpenHomeMediaResources(session.device) }
            }
            throw error
        } catch (error: Throwable) {
            if (!stagedRegistrationCreated) {
                stagedResources?.close() ?: stagedServer?.close()
            }
            // A stable read can prove whether a staged URL is still referenced, including after a
            // partial DeleteAll/Insert or a lost response. If the read is inconclusive, retention
            // deliberately keeps both resource groups alive for a later poll.
            runCatching {
                if (queueMutationMayHaveReachedRenderer || stagedRegistrationCreated) {
                    reconcileOpenHomeMediaResources(session.device)
                }
            }
            throw error
        }
    }

    private fun updateOpenHomeActiveQueueState(
        session: DesktopOpenHomeActiveQueueSession,
        snapshot: DesktopOpenHomeQueueSnapshot,
    ) {
        val identity = session.device.identity
        val currentStatus = networkRendererStatusByIdentity[identity] ?: DesktopUpnpRendererStatus()
        val openHomeStatus = desktopOpenHomeRendererStatus(snapshot)
        networkRendererStatusByIdentity = networkRendererStatusByIdentity + (
            identity to mergeDesktopOpenHomeRendererStatus(currentStatus, openHomeStatus)
        )

        val binding = session.binding
        val observation = binding?.observe(
            deviceIdentity = identity,
            generation = session.generation,
            snapshot = snapshot,
            snapshotStillCurrent = true,
        )
        when (observation) {
            is DesktopOpenHomeActiveQueueObservation.Invalidated -> {
                session.binding = null
                session.localTracks = null
            }
            is DesktopOpenHomeActiveQueueObservation.Unavailable,
            is DesktopOpenHomeActiveQueueObservation.Mapped,
            null -> Unit
        }

        if (openHomeActiveTargetIdentity != identity && networkRendererQueueIdentity != identity) return

        val mappedObservation = observation as? DesktopOpenHomeActiveQueueObservation.Mapped
        val mappedTrack = mappedObservation?.let { mapped -> session.localTracks?.getOrNull(mapped.localIndex) }
        if (mappedObservation != null && mappedTrack == null) {
            session.binding = null
            session.localTracks = null
        }
        val localQueueIsKnown = session.binding != null
        val queueIndex = if (mappedTrack != null) {
            checkNotNull(mappedObservation).localIndex
        } else {
            snapshot.ids.indexOf(snapshot.currentId).takeIf { it >= 0 }
        }
        val count = if (localQueueIsKnown) {
            session.localTracks?.size
        } else {
            snapshot.ids.size
        }

        networkRendererPlayingIdentity = identity
        networkRendererPlayingTrackTitle = mappedTrack?.title
        networkRendererQueueIdentity = identity
        networkRendererQueuePosition = if (queueIndex != null && count != null) {
            "${queueIndex + 1} / $count"
        } else {
            null
        }
        networkRendererQueueExcludedItems = if (localQueueIsKnown) session.excludedItems else 0
        networkRendererQueueIsLocal = localQueueIsKnown
    }

    private suspend fun sendCurrentLocalQueueToOpenHomePlaylist(
        device: DesktopUpnpRendererDevice,
        queueSnapshot: List<TrackItem>,
        queueCurrentIndex: Int,
    ): DesktopUpnpRendererStatus {
        val requiredActions = listOf(
            "TracksMax", "IdArray", "IdArrayChanged", "Id", "TransportState", "ReadList",
            "DeleteAll", "Insert", "SeekId", "Play",
        )
        val capabilities = openHomePlaylistClient.capabilities(device)
        val missingAction = requiredActions.firstOrNull { it !in capabilities.actions }
        if (missingAction != null) {
            throw IOException("OpenHome Playlist does not advertise $missingAction.")
        }

        val protocolInfo = openHomePlaylistClient.protocolInfo(device)
        val supportedMimeTypes = queueSnapshot.map { queueTrack ->
            if (!isNetworkRendererEligibleLocalTrack(queueTrack)) null
            else {
                val source = queueTrack.playbackSource as DesktopTrackSource.LocalFile
                chooseDesktopUpnpHttpMime(protocolInfo, desktopUpnpMimeCandidates(source.absolutePath))
            }
        }
        val queueSegment = desktopUpnpQueueSegment(
            supported = supportedMimeTypes.map { it != null },
            currentIndex = queueCurrentIndex,
        ) ?: throw IOException(tr("settings.network_renderer.local.format_unsupported"))
        val rendererQueueTracks = (queueSegment.startIndex until queueSegment.endExclusive).map { index ->
            queueSnapshot[index] to checkNotNull(supportedMimeTypes[index])
        }
        val rendererQueueIndex = queueSegment.currentIndex
        val rendererAddress = desktopUpnpNumericAddress(device.descriptionUri)
            ?: throw IOException(tr("settings.network_renderer.local.device_address_unavailable"))
        val routePort = networkRendererRoutePort(device)
        val bindAddress = try {
            withContext(Dispatchers.IO) {
                DesktopUpnpMediaServer.routeLocalAddress(rendererAddress, routePort)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            throw IOException(tr("settings.network_renderer.local.route_failed"), error)
        }
        val server = try {
            withContext(Dispatchers.IO) {
                DesktopUpnpMediaServer(
                    bindAddress = bindAddress,
                    rendererAddress = rendererAddress,
                    leaseTtl = java.time.Duration.ofHours(12),
                )
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            throw IOException(tr("settings.network_renderer.local.server_failed"), error)
        }
        val queuedMedia = try {
            withContext(Dispatchers.IO) {
                rendererQueueTracks.map { (queueTrack, mimeType) ->
                    val source = queueTrack.playbackSource as DesktopTrackSource.LocalFile
                    DesktopUpnpQueuedMedia(
                        track = queueTrack,
                        mimeType = mimeType,
                        lease = server.createLease(source, mimeType),
                    )
                }
            }
        } catch (error: Throwable) {
            server.close()
            throw error
        }
        val resources = DesktopUpnpMediaResources(queuedMedia, server, bindAddress)
        val pausedOpenHomeSession = pauseOpenHomeActiveQueuePolling(device.identity)
        try {
            openHomeMediaDevices[device.identity] = device
            openHomeMediaRetention.register(
                deviceIdentity = device.identity,
                uris = queuedMedia.mapTo(linkedSetOf()) { it.lease.mediaUri.toASCIIString() },
                close = { resources.close() },
                renew = {
                    val allRenewed = withContext(Dispatchers.IO) {
                        queuedMedia.map { it.lease.renew() }.all { it }
                    }
                    if (!allRenewed) throw IOException("One or more OpenHome media leases could not be renewed.")
                },
            )
            ensureOpenHomeMediaLeaseRenewal()
        } catch (error: Throwable) {
            resources.close()
            resumeOpenHomeActiveQueuePolling(pausedOpenHomeSession)
            throw error
        }

        var queueReplacementMayHaveReachedRenderer = false
        return try {
            val previousOpenHomeIdentity = openHomeActiveTargetIdentity
            if (previousOpenHomeIdentity != null && previousOpenHomeIdentity != device.identity) {
                openHomeMediaDevices[previousOpenHomeIdentity]?.let { previousDevice ->
                    try {
                        stopOpenHomeSession(previousOpenHomeIdentity, previousDevice)
                        if (openHomeActiveTargetIdentity == previousOpenHomeIdentity) {
                            openHomeActiveTargetIdentity = null
                        }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                        // Keep its queue leases; a later stable snapshot can determine when they are unused.
                    }
                }
            }
            networkRendererActiveMediaPlayback?.let { previous ->
                previous.explicitStopRequested.set(true)
                try {
                    networkRendererClient.control(previous.device, DesktopUpnpTransportCommand.STOP)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    // Keep the previous lease cleanup behavior; this new OpenHome group remains owned.
                }
                closeActiveNetworkRendererMediaPlayback()
            }

            val initialSnapshot = openHomeQueueCoordinator.readSnapshot(device)
            val candidates = queuedMedia.mapIndexed { index, media ->
                DesktopOpenHomeQueueCandidate(
                    localIndex = index,
                    uri = media.lease.mediaUri.toASCIIString(),
                    metadata = buildDesktopUpnpDidlMetadata(
                        title = media.track.title,
                        artist = media.track.artist,
                        album = media.track.album,
                        resourceUri = media.lease.mediaUri,
                        mimeType = media.mimeType,
                        fileSize = media.lease.fileSize,
                        durationMillis = media.track.durationMillis,
                    ),
                )
            }
            openHomeActiveTargetIdentity = device.identity
            queueReplacementMayHaveReachedRenderer = true
            val replacement = openHomeQueueCoordinator.replace(device, initialSnapshot, candidates)
            if (replacement !is DesktopOpenHomeQueueReplacement.Replaced) {
                replacement as DesktopOpenHomeQueueReplacement.Failed
                throw IOException(replacement.message, replacement.cause)
            }
            val selectedId = replacement.idToLocalIndex.entries
                .singleOrNull { it.value == rendererQueueIndex }
                ?.key ?: throw IOException("OpenHome Insert did not return an ID for the selected track.")

            openHomePlaylistClient.seekId(device, selectedId)
            openHomePlaylistClient.play(device)
            val confirmed = openHomeQueueCoordinator.readSnapshot(device)
            if (confirmed.token != replacement.token ||
                confirmed.ids != replacement.idToLocalIndex.keys.toList() ||
                confirmed.currentId != selectedId ||
                confirmed.tracksById[selectedId]?.uri != queuedMedia[rendererQueueIndex].lease.mediaUri.toASCIIString() ||
                !openHomeQueueCoordinator.snapshotStillCurrent(device, confirmed)
            ) {
                throw IOException("OpenHome Playlist did not confirm the selected local track and queue token.")
            }

            val selectedMedia = queuedMedia[rendererQueueIndex]
            val sessionGeneration = openHomeQueueSessionGeneration.incrementAndGet()
            val expectedUriById = replacement.idToLocalIndex.mapValues { (_, localIndex) ->
                queuedMedia.getOrNull(localIndex)?.lease?.mediaUri?.toASCIIString()
                    ?: throw IOException("OpenHome queue mapping refers to a missing local track.")
            }
            val activeQueueBinding = DesktopOpenHomeActiveQueueBinding.create(
                deviceIdentity = device.identity,
                generation = sessionGeneration,
                snapshot = confirmed,
                idToLocalIndex = replacement.idToLocalIndex,
                expectedUriById = expectedUriById,
                snapshotStillCurrent = true,
            ) ?: throw IOException("OpenHome Playlist did not produce a complete local queue binding.")
            val session = DesktopOpenHomeActiveQueueSession(
                device = device,
                boundRendererAddress = rendererAddress,
                boundDeviceDescriptor = device,
                generation = sessionGeneration,
                lastSnapshot = confirmed,
                binding = activeQueueBinding,
                localTracks = queuedMedia.map { it.track },
                mediaResources = resources,
                excludedItems = queueSnapshot.size - queuedMedia.size,
            )
            networkRendererPlayingIdentity = device.identity
            networkRendererPlayingTrackTitle = selectedMedia.track.title
            networkRendererQueueIdentity = device.identity
            networkRendererQueuePosition = "${rendererQueueIndex + 1} / ${queuedMedia.size}"
            networkRendererQueueExcludedItems = queueSnapshot.size - queuedMedia.size
            networkRendererQueueIsLocal = true
            stopLocalPlaybackAfterNetworkHandoff()

            val confirmedStillCurrent = try {
                openHomeQueueCoordinator.snapshotStillCurrent(device, confirmed)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                false
            }
            try {
                openHomeMediaRetention.reconcile(
                    deviceIdentity = device.identity,
                    snapshotDeviceIdentity = device.identity,
                    snapshot = confirmed,
                    snapshotStillCurrent = confirmedStillCurrent,
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                networkRendererOperationErrors = networkRendererOperationErrors + (
                    device.identity to (error.message ?: "Could not reconcile OpenHome media leases.")
                )
            }
            val replacedOpenHomeSession = openHomeActiveQueueSessions.put(device.identity, session)
            if (replacedOpenHomeSession != null && replacedOpenHomeSession !== session) {
                closeOpenHomeGenaSubscription(replacedOpenHomeSession, closeRefreshChannel = true)
            }
            startOpenHomeActiveQueuePolling(session)
            desktopOpenHomeRendererStatus(confirmed)
        } catch (error: CancellationException) {
            // Once replacement may have been sent, keep this group until a later stable reconciliation.
            if (!queueReplacementMayHaveReachedRenderer) {
                withContext(NonCancellable) {
                    runCatching { reconcileOpenHomeMediaResources(device) }
                }
            }
            withContext(NonCancellable) { resumeOpenHomeActiveQueuePolling(pausedOpenHomeSession) }
            throw error
        } catch (error: Throwable) {
            runCatching { reconcileOpenHomeMediaResources(device) }
            resumeOpenHomeActiveQueuePolling(pausedOpenHomeSession)
            throw error
        }
    }

    private suspend fun reconcileOpenHomeMediaResources(device: DesktopUpnpRendererDevice) {
        var snapshot: DesktopOpenHomeQueueSnapshot? = null
        var snapshotIsCurrent = false
        var readError: Throwable? = null
        try {
            snapshot = openHomeQueueCoordinator.readSnapshot(device)
            snapshotIsCurrent = openHomeQueueCoordinator.snapshotStillCurrent(device, checkNotNull(snapshot))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            readError = error
        }
        openHomeMediaRetention.reconcile(
            deviceIdentity = device.identity,
            snapshotDeviceIdentity = device.identity,
            snapshot = snapshot,
            snapshotStillCurrent = snapshotIsCurrent,
            readError = readError,
        )
    }

    private suspend fun stopOpenHomeTargetBeforeAvHandoff(target: DesktopUpnpRendererDevice) {
        val activeIdentity = openHomeActiveTargetIdentity ?: return
        if (activeIdentity == target.identity) return
        val activeDevice = openHomeMediaDevices[activeIdentity] ?: return
        try {
            val status = stopOpenHomeSession(activeIdentity, activeDevice)
            if (desktopOpenHomeCommandMatches(DesktopUpnpTransportCommand.STOP, status)) {
                openHomeActiveTargetIdentity = null
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            networkRendererOperationErrors = networkRendererOperationErrors + (
                activeIdentity to (error.message ?: tr("settings.network_renderer.action_failed_generic"))
            )
        }
    }

    private suspend fun stopOpenHomeSession(
        deviceIdentity: String,
        fallbackDevice: DesktopUpnpRendererDevice,
    ): DesktopUpnpRendererStatus {
        val session = openHomeActiveQueueSessions[deviceIdentity]
        if (session == null) {
            openHomePlaylistClient.stop(fallbackDevice)
            return readOpenHomeRendererStatus(fallbackDevice)
        }
        val revision = session.recordTransportCommand(DesktopUpnpTransportCommand.STOP)
        val status = session.operationMutex.withLock {
            val targetDevice = session.device
            openHomePlaylistClient.stop(targetDevice)
            readOpenHomeRendererStatus(targetDevice)
        }
        if (desktopOpenHomeCommandMatches(DesktopUpnpTransportCommand.STOP, status)) {
            session.clearTransportCommand(DesktopUpnpTransportCommand.STOP, revision)
        }
        return status
    }

    private fun ensureOpenHomeMediaLeaseRenewal() {
        if (openHomeLeaseRenewalJob?.isActive == true) return
        openHomeLeaseRenewalJob = scope.launch {
            while (isActive) {
                delay(60_000L)
                for (group in openHomeMediaRetention.dueRenewalGroups()) {
                    val device = openHomeMediaDevices[group.deviceIdentity] ?: continue
                    try {
                        openHomeMediaRetention.renew(group)
                        openHomeRenewalFailures.remove(group.registrationId)
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Exception) {
                        if (openHomeRenewalFailures.add(group.registrationId)) {
                            networkRendererOperationErrors = networkRendererOperationErrors + (
                                device.identity to (error.message ?: "Could not renew OpenHome media leases.")
                            )
                        }
                    }
                }
            }
        }
    }

    internal fun sendCurrentLocalTrackToNetworkRenderer(device: DesktopUpnpRendererDevice) {
        val track = nowPlaying
        if (track == null || !isNetworkRendererEligibleLocalTrack(track)) {
            networkRendererOperationErrors = networkRendererOperationErrors + (
                device.identity to tr(
                    if (currentLocalTrackIsCue) {
                        "settings.network_renderer.local.cue_unsupported"
                    } else {
                        "settings.network_renderer.local.track_required"
                    },
                )
            )
            return
        }
        val queueSnapshot = effectiveQueue().takeIf { queue -> queue.any { it.id == track.id } }
            ?: listOf(track)
        val queueCurrentIndex = queueSnapshot.indexOfFirst { it.id == track.id }.takeIf { it >= 0 } ?: 0
        runNetworkRendererOperation(device) {
            if (device.hasOpenHomePlaylist) {
                return@runNetworkRendererOperation sendCurrentLocalQueueToOpenHomePlaylist(
                    device = device,
                    queueSnapshot = queueSnapshot,
                    queueCurrentIndex = queueCurrentIndex,
                )
            }
            val status = networkRendererClient.readStatus(device)
            networkRendererStatusByIdentity = networkRendererStatusByIdentity + (device.identity to status)
            val unavailableRequiredAction = listOf("SetAVTransportURI", "Play")
                .firstOrNull { !desktopUpnpActionAdvertised(status, it) }
            if (unavailableRequiredAction != null) {
                throw IOException(tr("settings.network_renderer.action_unsupported", unavailableRequiredAction))
            }
            val supportedMimeTypes = queueSnapshot.map { queueTrack ->
                if (!isNetworkRendererEligibleLocalTrack(queueTrack)) null
                else {
                    val queueSource = queueTrack.playbackSource as DesktopTrackSource.LocalFile
                    chooseDesktopUpnpHttpMime(
                        status.sinkProtocolInfo,
                        desktopUpnpMimeCandidates(queueSource.absolutePath),
                    )
                }
            }
            val queueSegment = desktopUpnpQueueSegment(
                supported = supportedMimeTypes.map { it != null },
                currentIndex = queueCurrentIndex,
            ) ?: throw IOException(tr("settings.network_renderer.local.format_unsupported"))
            val rendererQueueTracks = (queueSegment.startIndex until queueSegment.endExclusive).map { index ->
                queueSnapshot[index] to checkNotNull(supportedMimeTypes[index])
            }
            val rendererQueueIndex = queueSegment.currentIndex
            val rendererAddress = desktopUpnpNumericAddress(device.descriptionUri)
                ?: throw IOException(tr("settings.network_renderer.local.device_address_unavailable"))
            val routePort = networkRendererRoutePort(device)
            val bindAddress = try {
                withContext(Dispatchers.IO) {
                    DesktopUpnpMediaServer.routeLocalAddress(rendererAddress, routePort)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                throw IOException(tr("settings.network_renderer.local.route_failed"), error)
            }
            val server = try {
                withContext(Dispatchers.IO) {
                    DesktopUpnpMediaServer(
                        bindAddress = bindAddress,
                        rendererAddress = rendererAddress,
                        leaseTtl = java.time.Duration.ofHours(12),
                    )
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                throw IOException(tr("settings.network_renderer.local.server_failed"), error)
            }
            val queue = try {
                withContext(Dispatchers.IO) {
                    rendererQueueTracks.map { (queueTrack, mimeType) ->
                        val queueSource = queueTrack.playbackSource as DesktopTrackSource.LocalFile
                        DesktopUpnpQueuedMedia(
                            track = queueTrack,
                            mimeType = mimeType,
                            lease = server.createLease(queueSource, mimeType),
                        )
                    }
                }
            } catch (error: Throwable) {
                // All queue leases must be in place before local playback is handed off.
                server.close()
                throw error
            }
            val initialMedia = queue[rendererQueueIndex]

            try {
                stopOpenHomeTargetBeforeAvHandoff(device)
            } catch (error: CancellationException) {
                queue.forEach { it.lease.revoke() }
                server.close()
                throw error
            }
            networkRendererActiveMediaPlayback?.let { previous ->
                previous.explicitStopRequested.set(true)
                try {
                    networkRendererClient.control(previous.device, DesktopUpnpTransportCommand.STOP)
                } catch (error: CancellationException) {
                    queue.forEach { it.lease.revoke() }
                    server.close()
                    throw error
                } catch (_: Exception) {
                    // Replacing the lease still cuts off later reads from the previous track.
                }
                closeActiveNetworkRendererMediaPlayback()
            }

            val sessionToken = Any()
            val sessionReady = AtomicBoolean(false)
            val eventRevision = AtomicLong(0L)
            var eventReceiver: DesktopUpnpEventReceiver? = null
            var eventLease: DesktopUpnpGenaLease? = null
            val eventEndpoint = device.services[DesktopUpnpRendererServiceKind.AV_TRANSPORT]?.eventSubUri
            if (eventEndpoint?.scheme.equals("http", ignoreCase = true)) {
                eventReceiver = try {
                    withContext(Dispatchers.IO) {
                        createNetworkRendererEventReceiver(
                            bindAddress = bindAddress,
                            rendererAddress = rendererAddress,
                            deviceIdentity = device.identity,
                            sessionToken = sessionToken,
                            sessionReady = sessionReady,
                            eventRevision = eventRevision,
                        )
                    }
                } catch (error: CancellationException) {
                    queue.forEach { it.lease.revoke() }
                    server.close()
                    throw error
                } catch (_: Exception) {
                    null
                }
                eventReceiver?.let { receiver ->
                    try {
                        withContext(NonCancellable) {
                            val subscription = withContext(Dispatchers.IO) {
                                networkRendererGenaClient.subscribe(
                                    device = device,
                                    rendererAddress = rendererAddress,
                                    localAddress = bindAddress,
                                    callbackUri = receiver.callbackUri,
                                )
                            }
                            try {
                                receiver.acceptSid(subscription.sid)
                                eventLease = subscription
                            } catch (error: Exception) {
                                withContext(Dispatchers.IO) {
                                    runCatching {
                                        networkRendererGenaClient.unsubscribe(
                                            device,
                                            rendererAddress,
                                            bindAddress,
                                            subscription.sid,
                                        )
                                    }
                                }
                                throw error
                            }
                        }
                    } catch (error: CancellationException) {
                        closeNetworkRendererGenaSubscription(
                            device,
                            rendererAddress,
                            bindAddress,
                            receiver,
                            eventLease,
                        )
                        queue.forEach { it.lease.revoke() }
                        server.close()
                        throw error
                    } catch (_: Exception) {
                        // Keep the callback alive and let the session worker retry this transient
                        // failure while status polling remains available as a fallback.
                    }
                }
            }

            try {
                val didl = buildDesktopUpnpDidlMetadata(
                    title = initialMedia.track.title,
                    artist = initialMedia.track.artist,
                    album = initialMedia.track.album,
                    resourceUri = initialMedia.lease.mediaUri,
                    mimeType = initialMedia.mimeType,
                    fileSize = initialMedia.lease.fileSize,
                    durationMillis = initialMedia.track.durationMillis,
                )
                networkRendererClient.setMediaUri(device, initialMedia.lease.mediaUri, didl)
                networkRendererClient.control(device, DesktopUpnpTransportCommand.PLAY)
            } catch (error: Throwable) {
                queue.forEach { it.lease.revoke() }
                server.close()
                closeNetworkRendererGenaSubscription(
                    device,
                    rendererAddress,
                    bindAddress,
                    eventReceiver,
                    eventLease,
                )
                throw error
            }

            val active = DesktopUpnpActiveMediaPlayback(
                binding = DesktopUpnpActiveMediaBinding(
                    device = device,
                    mediaResources = DesktopUpnpMediaResources(queue, server, bindAddress),
                    rendererAddress = rendererAddress,
                    eventReceiver = eventReceiver,
                    eventLease = eventLease,
                ),
                queueIndex = rendererQueueIndex,
                sessionToken = sessionToken,
                sessionReady = sessionReady,
                eventRevision = eventRevision,
                advanceInProgress = AtomicBoolean(false),
                explicitStopRequested = AtomicBoolean(false),
                recoveryState = DesktopUpnpRecoveryState(),
            )
            networkRendererActiveMediaPlayback = active
            sessionReady.set(true)
            networkRendererPlayingIdentity = device.identity
            networkRendererPlayingTrackTitle = initialMedia.track.title
            networkRendererQueueIdentity = device.identity
            networkRendererQueuePosition = "${rendererQueueIndex + 1} / ${queue.size}"
            networkRendererQueueExcludedItems = queueSnapshot.size - queue.size
            networkRendererQueueIsLocal = true
            active.shuffleHistoryIndices += rendererQueueIndex
            stopLocalPlaybackAfterNetworkHandoff()
            val revisionAtRead = eventRevision.get()
            val playbackStatus = try {
                networkRendererClient.readStatus(device)
            } finally {
                startNetworkRendererPlaybackUpdates(active)
            }
            if (eventRevision.get() == revisionAtRead || active.appliedEventRevision <= revisionAtRead) {
                networkRendererStatusByIdentity = networkRendererStatusByIdentity + (device.identity to playbackStatus)
            }
            observeNetworkRendererPlayback(
                active = active,
                freshTrackUri = playbackStatus.trackUri,
                freshTransportState = playbackStatus.transportState,
                freshTransportStatus = playbackStatus.transportStatus,
                freshPositionMillis = playbackStatus.positionMillis,
                freshDurationMillis = playbackStatus.durationMillis,
            )
            networkRendererStatusByIdentity[device.identity] ?: playbackStatus
        }
    }

    private fun observeNetworkRendererPlayback(
        active: DesktopUpnpActiveMediaPlayback,
        freshTrackUri: String?,
        freshTransportState: String?,
        freshTransportStatus: String?,
        freshPositionMillis: Long?,
        freshDurationMillis: Long?,
    ) {
        if (networkRendererActiveMediaPlayback?.sessionToken !== active.sessionToken ||
            !active.sessionReady.get() || active.advanceInProgress.get()
        ) return
        val expectedUri = active.current.lease.mediaUri.toASCIIString()
        active.recoveryState.observePlaybackPosition(
            expectedUri = expectedUri,
            observedUri = freshTrackUri,
            transportState = freshTransportState,
            positionMillis = freshPositionMillis,
            durationMillis = freshDurationMillis,
        )
        active.recoveryState.observeTransportState(freshTransportState)
        freshTrackUri?.takeIf(String::isNotBlank)?.let { uri ->
            active.lastObservedTrackUri = uri
            if (uri != expectedUri) {
                active.naturalEndPending = false
                active.observedPlayingForCurrentTrack = false
                active.lastObservedTransportState = null
                active.lastObservedPositionMillis = null
                active.lastObservedDurationMillis = null
                active.lastObservedAtMillis = 0L
                return
            }
        }
        if (active.lastObservedTrackUri != expectedUri) return
        freshTransportStatus?.takeIf(String::isNotBlank)?.let { active.lastObservedTransportStatus = it }
        val observedStatus = freshTransportStatus ?: active.lastObservedTransportStatus
        val now = System.currentTimeMillis()

        if (freshTransportState.equals("PLAYING", ignoreCase = true)) {
            active.observedPlayingForCurrentTrack = true
            active.naturalEndPending = false
            active.advanceRetryAfterNanos = 0L
            active.advanceFailureCount = 0
            active.lastObservedTransportState = freshTransportState
            active.lastObservedTransportStatus = observedStatus
            freshPositionMillis?.let { active.lastObservedPositionMillis = it }
            freshDurationMillis?.let { active.lastObservedDurationMillis = it }
            active.lastObservedAtMillis = now
            return
        }

        if (!freshTransportState.equals("STOPPED", ignoreCase = true)) {
            if (freshTransportState != null) {
                active.lastObservedTransportState = freshTransportState
                active.lastObservedTransportStatus = observedStatus
                active.lastObservedAtMillis = now
            }
            return
        }

        val previousSampleIsFresh = now - active.lastObservedAtMillis <= NETWORK_RENDERER_END_SAMPLE_MAX_AGE_MILLIS
        val looksNatural = active.observedPlayingForCurrentTrack && desktopUpnpIsNaturalEnd(
            transportState = freshTransportState,
            trackUri = active.lastObservedTrackUri,
            expectedTrackUri = expectedUri,
            transportStatus = observedStatus,
            positionMillis = freshPositionMillis,
            durationMillis = freshDurationMillis ?: active.lastObservedDurationMillis,
            previousTransportState = active.lastObservedTransportState,
            previousTransportStatus = active.lastObservedTransportStatus,
            previousPositionMillis = active.lastObservedPositionMillis,
            previousDurationMillis = active.lastObservedDurationMillis,
            previousSampleIsFresh = previousSampleIsFresh,
            observedPlayingForCurrentTrack = active.observedPlayingForCurrentTrack,
            explicitStopRequested = active.explicitStopRequested.get(),
        )
        if (looksNatural) {
            active.naturalEndPending = true
            requestNetworkRendererQueueAdvance(active, previous = false, naturalEnd = true)
        } else {
            active.lastObservedTransportState = freshTransportState
            active.lastObservedTransportStatus = observedStatus
            freshPositionMillis?.let { active.lastObservedPositionMillis = it }
            freshDurationMillis?.let { active.lastObservedDurationMillis = it }
            active.lastObservedAtMillis = now
        }
    }

    private fun requestNetworkRendererQueueAdvance(
        active: DesktopUpnpActiveMediaPlayback,
        previous: Boolean,
        naturalEnd: Boolean,
    ) {
        if (!naturalEnd) {
            active.explicitStopRequested.set(false)
            active.recoveryState.requestPlay()
        }
        val requestedPlayMode = playModeState
        if (networkRendererActiveMediaPlayback?.sessionToken !== active.sessionToken ||
            !active.sessionReady.get() || active.explicitStopRequested.get() ||
            (naturalEnd && (!active.naturalEndPending ||
                (active.advanceFailureCount > 0 && System.nanoTime() < active.advanceRetryAfterNanos)))
        ) return
        if (!active.advanceInProgress.compareAndSet(false, true)) return
        if (networkRendererOperationLoadingIdentity != null) {
            active.advanceInProgress.set(false)
            return
        }
        runNetworkRendererOperation(active.device) {
            var changedTrack = false
            var uriChanged = false
            var previousMedia: DesktopUpnpQueuedMedia? = null
            try {
                if (networkRendererActiveMediaPlayback?.sessionToken !== active.sessionToken ||
                    !active.sessionReady.get() || active.explicitStopRequested.get()
                ) return@runNetworkRendererOperation networkRendererClient.readPlaybackSnapshot(active.device)

                if (naturalEnd) {
                    val confirmation = networkRendererClient.readPlaybackSnapshot(active.device)
                    val confirmedNaturalEnd = active.observedPlayingForCurrentTrack &&
                        desktopUpnpIsNaturalEnd(
                            transportState = confirmation.transportState,
                            trackUri = confirmation.trackUri?.takeIf(String::isNotBlank),
                            expectedTrackUri = active.current.lease.mediaUri.toASCIIString(),
                            transportStatus = confirmation.transportStatus,
                            positionMillis = confirmation.positionMillis,
                            durationMillis = confirmation.durationMillis,
                            previousTransportState = active.lastObservedTransportState,
                            previousTransportStatus = active.lastObservedTransportStatus,
                            previousPositionMillis = active.lastObservedPositionMillis,
                            previousDurationMillis = active.lastObservedDurationMillis,
                            previousSampleIsFresh = System.currentTimeMillis() - active.lastObservedAtMillis <=
                                NETWORK_RENDERER_END_SAMPLE_MAX_AGE_MILLIS,
                            observedPlayingForCurrentTrack = active.observedPlayingForCurrentTrack,
                            explicitStopRequested = active.explicitStopRequested.get(),
                        )
                    if (!confirmedNaturalEnd) {
                        active.naturalEndPending = false
                        if (confirmation.transportState.equals("PLAYING", ignoreCase = true) &&
                            confirmation.trackUri == active.current.lease.mediaUri.toASCIIString()
                        ) {
                            observeNetworkRendererPlayback(
                                active,
                                confirmation.trackUri,
                                confirmation.transportState,
                                confirmation.transportStatus,
                                confirmation.positionMillis,
                                confirmation.durationMillis,
                            )
                        }
                        return@runNetworkRendererOperation confirmation
                    }
                }

                if (requestedPlayMode == DesktopPlayMode.Shuffle &&
                    active.shuffleHistoryIndices.lastOrNull() != active.queueIndex
                ) {
                    active.shuffleHistoryIndices += active.queueIndex
                }
                val targetIndex = if (previous && requestedPlayMode == DesktopPlayMode.Shuffle) {
                    active.shuffleHistoryIndices
                        .takeIf { it.lastOrNull() == active.queueIndex && it.size > 1 }
                        ?.get(active.shuffleHistoryIndices.lastIndex - 1)
                } else if (previous) {
                    desktopUpnpPreviousQueueIndex(active.queue.size, active.queueIndex)
                } else if (requestedPlayMode == DesktopPlayMode.Shuffle) {
                    drawNetworkRendererShuffleIndex(active)
                } else {
                    desktopUpnpNextQueueIndex(
                        active.queue.size,
                        active.queueIndex,
                        requestedPlayMode,
                        naturalEnd = naturalEnd,
                    )
                }
                if (targetIndex == null) {
                    if (previous) return@runNetworkRendererOperation networkRendererClient.readPlaybackSnapshot(active.device)
                    active.naturalEndPending = false
                    if (naturalEnd) {
                        closeActiveNetworkRendererMediaPlayback(
                            active.device.identity,
                            preserveStoppedDisplay = true,
                        )
                        return@runNetworkRendererOperation networkRendererStatusByIdentity[active.device.identity]
                            ?: DesktopUpnpRendererStatus(transportState = "STOPPED", transportStatus = "OK")
                    } else {
                        networkRendererClient.control(active.device, DesktopUpnpTransportCommand.STOP)
                        closeActiveNetworkRendererMediaPlayback(active.device.identity)
                    }
                    return@runNetworkRendererOperation networkRendererClient.readPlaybackSnapshot(active.device)
                }

                val nextMedia = active.queue[targetIndex]
                val nextDidl = buildDesktopUpnpDidlMetadata(
                    title = nextMedia.track.title,
                    artist = nextMedia.track.artist,
                    album = nextMedia.track.album,
                    resourceUri = nextMedia.lease.mediaUri,
                    mimeType = nextMedia.mimeType,
                    fileSize = nextMedia.lease.fileSize,
                    durationMillis = nextMedia.track.durationMillis,
                )
                val previousIndex = active.queueIndex
                previousMedia = active.current
                networkRendererClient.setMediaUri(active.device, nextMedia.lease.mediaUri, nextDidl)
                uriChanged = true
                networkRendererClient.control(active.device, DesktopUpnpTransportCommand.PLAY)
                if (requestedPlayMode == DesktopPlayMode.Shuffle) {
                    if (previous) {
                        if (active.shuffleHistoryIndices.lastOrNull() == previousIndex) {
                            active.shuffleHistoryIndices.removeAt(active.shuffleHistoryIndices.lastIndex)
                        }
                        active.shuffleRemainingIndices.addFirst(previousIndex)
                    } else {
                        if (active.shuffleHistoryIndices.lastOrNull() != targetIndex) {
                            active.shuffleHistoryIndices += targetIndex
                            if (active.shuffleHistoryIndices.size > 200) {
                                active.shuffleHistoryIndices.removeAt(0)
                            }
                        }
                    }
                }
                active.queueIndex = targetIndex
                active.naturalEndPending = false
                active.observedPlayingForCurrentTrack = false
                active.advanceRetryAfterNanos = 0L
                active.advanceFailureCount = 0
                active.lastObservedTrackUri = nextMedia.lease.mediaUri.toASCIIString()
                active.lastObservedTransportState = null
                active.lastObservedTransportStatus = null
                active.lastObservedPositionMillis = null
                active.lastObservedDurationMillis = null
                active.lastObservedAtMillis = 0L
                active.recoveryState.acknowledgeRestoredSession()
                active.recoveryRetryAfterNanos = 0L
                active.recoveryFailureCount = 0
                changedTrack = true

                networkRendererPlayingTrackTitle = nextMedia.track.title
                networkRendererQueuePosition = "${targetIndex + 1} / ${active.queue.size}"
                nowPlaying = nextMedia.track
                progress = 0f
                bufferedProgress = 0f
                isLiked = false
                publishSystemMedia(statusOverride = SystemMediaPlaybackStatus.STOPPED, forcePosition = true)
                networkRendererStatusByIdentity = networkRendererStatusByIdentity + (
                    active.device.identity to (networkRendererStatusByIdentity[active.device.identity]
                        ?: DesktopUpnpRendererStatus()).copy(
                        transportState = "PLAYING",
                        transportStatus = "OK",
                        trackUri = nextMedia.lease.mediaUri.toASCIIString(),
                        trackMetadata = nextDidl,
                        positionMillis = 0L,
                        durationMillis = nextMedia.track.durationMillis.takeIf { it > 0L },
                    )
                )
                val revisionAtRead = active.eventRevision.get()
                val refreshedStatus = networkRendererClient.readStatus(active.device)
                if (active.eventRevision.get() == revisionAtRead) refreshedStatus
                else networkRendererStatusByIdentity[active.device.identity] ?: refreshedStatus
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                val restoreMedia = previousMedia
                if (uriChanged && !changedTrack && restoreMedia != null) {
                    try {
                        val rollbackDidl = buildDesktopUpnpDidlMetadata(
                            title = restoreMedia.track.title,
                            artist = restoreMedia.track.artist,
                            album = restoreMedia.track.album,
                            resourceUri = restoreMedia.lease.mediaUri,
                            mimeType = restoreMedia.mimeType,
                            fileSize = restoreMedia.lease.fileSize,
                            durationMillis = restoreMedia.track.durationMillis,
                        )
                        networkRendererClient.setMediaUri(active.device, restoreMedia.lease.mediaUri, rollbackDidl)
                        if (!naturalEnd) {
                            networkRendererClient.control(active.device, DesktopUpnpTransportCommand.PLAY)
                        }
                        networkRendererStatusByIdentity = networkRendererStatusByIdentity + (
                            active.device.identity to (networkRendererStatusByIdentity[active.device.identity]
                                ?: DesktopUpnpRendererStatus()).copy(
                                transportState = if (naturalEnd) "STOPPED" else "PLAYING",
                                trackUri = restoreMedia.lease.mediaUri.toASCIIString(),
                                trackMetadata = rollbackDidl,
                                positionMillis = if (naturalEnd) restoreMedia.track.durationMillis else 0L,
                                durationMillis = restoreMedia.track.durationMillis.takeIf { it > 0L },
                            )
                        )
                    } catch (_: Exception) {
                        // The renderer may still be serving either queued URI. Keep its HTTP
                        // server and every queue lease alive until a later Stop or replacement
                        // session confirms that the device no longer needs them.
                    }
                }
                if (naturalEnd && !changedTrack) {
                    active.advanceFailureCount = (active.advanceFailureCount + 1).coerceAtMost(5)
                    active.advanceRetryAfterNanos = System.nanoTime() +
                        desktopUpnpAdvanceRetryDelayMillis(active.advanceFailureCount) * 1_000_000L
                }
                throw error
            } finally {
                active.advanceInProgress.set(false)
            }
        }
    }

    private fun drawNetworkRendererShuffleIndex(active: DesktopUpnpActiveMediaPlayback): Int? {
        if (active.queue.size <= 1) return active.queue.indices.firstOrNull()
        if (active.shuffleRemainingIndices.isEmpty()) {
            val visited = active.shuffleHistoryIndices.toSet()
            val remaining = active.queue.indices.filter { it != active.queueIndex && it !in visited }
                .ifEmpty { active.queue.indices.filter { it != active.queueIndex } }
                .shuffled()
            active.shuffleRemainingIndices.addAll(remaining)
        }
        while (active.shuffleRemainingIndices.isNotEmpty()) {
            val candidate = active.shuffleRemainingIndices.removeFirst()
            if (candidate != active.queueIndex) return candidate
        }
        return null
    }

    private fun closeActiveNetworkRendererMediaPlayback(
        identity: String? = null,
        preserveStoppedDisplay: Boolean = false,
    ) {
        val active = networkRendererActiveMediaPlayback ?: return
        if (identity != null && active.device.identity != identity) return
        val recoveryOperation = networkRendererOperationJob
        val (closeState, bindingToClose) = synchronized(active.eventSubscriptionLock) {
            if (networkRendererActiveMediaPlayback?.sessionToken !== active.sessionToken) return
            val stopAfterRecoveryCancellation = active.recoveryState.isInProgress
            active.sessionReady.set(false)
            active.recoveryState.cancel()
            networkRendererActiveMediaPlayback = null
            val binding = active.binding
            active.binding = binding.copy(eventReceiver = null, eventLease = null)
            Triple(stopAfterRecoveryCancellation, binding.eventReceiver, binding.eventLease) to binding
        }
        val (stopAfterRecoveryCancellation, eventReceiver, eventLease) = closeState
        active.eventRenewalJob?.cancel()
        active.eventRefreshRequests.close()
        active.statusPollingJob?.cancel()
        closeNetworkRendererGenaSubscription(
            bindingToClose.device,
            bindingToClose.rendererAddress,
            bindingToClose.mediaResources.localAddress,
            eventReceiver,
            eventLease,
        )
        bindingToClose.mediaResources.close()
        if (stopAfterRecoveryCancellation) {
            Thread({
                runCatching {
                    runBlocking {
                        recoveryOperation?.join()
                        networkRendererClient.control(bindingToClose.device, DesktopUpnpTransportCommand.STOP)
                    }
                }
            }, "upnp-stop-after-recovery-cancel").apply {
                isDaemon = true
                start()
            }
        }
        if (networkRendererQueueIdentity == bindingToClose.device.identity) {
            networkRendererQueueIdentity = null
        }
        if (networkRendererPlayingIdentity == bindingToClose.device.identity) {
            if (!preserveStoppedDisplay) {
                networkRendererPlayingIdentity = null
                networkRendererPlayingTrackTitle = null
                networkRendererQueuePosition = null
                networkRendererQueueExcludedItems = 0
                networkRendererQueueIsLocal = false
            }
        }
    }

    private fun startNetworkRendererPlaybackUpdates(active: DesktopUpnpActiveMediaPlayback) {
        active.statusPollingJob = scope.launch {
            var leaseRenewalResources = active.mediaResources
            while (isActive) {
                delay(if (active.eventLease == null) 3_000L else 1_800L)
                if (networkRendererActiveMediaPlayback?.sessionToken !== active.sessionToken) break
                val currentResources = active.binding.mediaResources
                if (currentResources !== leaseRenewalResources) {
                    leaseRenewalResources = currentResources
                    active.mediaLeaseRenewalSchedule.reset()
                }
                if (active.mediaLeaseRenewalSchedule.isDue(System.nanoTime())) {
                    val resourcesToRenew = leaseRenewalResources
                    val renewed = withContext(Dispatchers.IO) {
                        resourcesToRenew.queue.all { it.lease.renew() }
                    }
                    if (renewed) {
                        if (active.mediaResources === resourcesToRenew) {
                            active.mediaLeaseRenewalSchedule.reset()
                        }
                    } else {
                        val shouldStop = synchronized(active.eventSubscriptionLock) {
                            if (networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken &&
                                active.sessionReady.get() && active.mediaResources === resourcesToRenew
                            ) {
                                active.explicitStopRequested.set(true)
                                active.recoveryState.cancel()
                                true
                            } else {
                                false
                            }
                        }
                        if (shouldStop) {
                            stopNetworkRendererPlaybackAfterLeaseFailure(active)
                            break
                        }
                        leaseRenewalResources = active.mediaResources
                        active.mediaLeaseRenewalSchedule.reset()
                    }
                }
                val revisionAtRead = active.eventRevision.get()
                val operationGenerationAtRead = networkRendererOperationGeneration
                val bindingAtRead = active.binding
                try {
                    val snapshot = withContext(Dispatchers.IO) {
                        networkRendererClient.readPlaybackSnapshot(bindingAtRead.device)
                    }
                    if (networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken &&
                        active.binding === bindingAtRead &&
                        active.eventRevision.get() == revisionAtRead &&
                        networkRendererOperationGeneration == operationGenerationAtRead
                    ) {
                        if (snapshot.connectionState == DesktopUpnpConnectionState.CONNECTED &&
                            networkRendererRouteChanged(active)
                        ) {
                            active.recoveryState.requestRecovery()
                            active.eventReconnectRefreshSent = true
                        }
                        if (snapshot.connectionState == DesktopUpnpConnectionState.DISCONNECTED) {
                            active.eventReconnectRefreshSent = false
                        }
                        val reconnected = active.recoveryState.observeConnection(snapshot.connectionState)
                        if (reconnected && !active.eventReconnectRefreshSent) {
                            active.eventReconnectRefreshSent = true
                            active.eventRefreshRequests.trySend(Unit)
                        }
                        val current = networkRendererStatusByIdentity[bindingAtRead.device.identity]
                            ?: DesktopUpnpRendererStatus()
                        val merged = mergeDesktopUpnpPlaybackSnapshot(current, snapshot)
                        networkRendererStatusByIdentity = networkRendererStatusByIdentity + (
                            bindingAtRead.device.identity to merged
                        )
                        observeNetworkRendererPlayback(
                            active = active,
                            freshTrackUri = snapshot.trackUri,
                            freshTransportState = snapshot.transportState,
                            freshTransportStatus = snapshot.transportStatus,
                            freshPositionMillis = snapshot.positionMillis,
                            freshDurationMillis = snapshot.durationMillis,
                        )
                        if (snapshot.connectionState != DesktopUpnpConnectionState.UNKNOWN &&
                            active.recoveryState.isPending && !active.naturalEndPending &&
                            !active.advanceInProgress.get() &&
                            System.nanoTime() >= active.recoveryRetryAfterNanos
                        ) {
                            requestNetworkRendererRecovery(active, snapshot)
                        }
                        if (snapshot.connectionState == DesktopUpnpConnectionState.CONNECTED) {
                            recoverNetworkRendererEventReceiver(active)
                        }
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    // Keep the last known renderer state; the next short poll can recover transient errors.
                }
            }
        }

        synchronized(active.eventSubscriptionLock) {
            val receiver = active.eventReceiver ?: return
            if (active.eventRenewalJob == null && active.sessionReady.get() &&
                networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken
            ) {
                startNetworkRendererEventRenewal(active, receiver, active.localAddress)
            }
        }
    }

    private suspend fun stopNetworkRendererPlaybackAfterLeaseFailure(
        active: DesktopUpnpActiveMediaPlayback,
    ) {
        withContext(NonCancellable) {
            var rendererStopped = false
            try {
                if (networkRendererOperationLoadingIdentity == active.device.identity) {
                    networkRendererOperationJob?.cancelAndJoin()
                }
                if (networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken) {
                    val status = withContext(Dispatchers.IO) {
                        networkRendererClient.control(active.device, DesktopUpnpTransportCommand.STOP)
                        networkRendererClient.readStatus(active.device)
                    }
                    networkRendererStatusByIdentity = networkRendererStatusByIdentity +
                        (active.device.identity to status)
                    rendererStopped = true
                }
            } catch (_: Exception) {
                // Revoke the local capability below even when the renderer is unreachable.
            } finally {
                networkRendererOperationErrors = networkRendererOperationErrors + (
                    active.device.identity to tr(
                        if (rendererStopped) {
                            "settings.network_renderer.local.lease_invalid"
                        } else {
                            "settings.network_renderer.local.lease_stop_failed"
                        },
                    )
                )
                closeActiveNetworkRendererMediaPlayback(active.device.identity)
            }
        }
    }

    private fun networkRendererRoutePort(device: DesktopUpnpRendererDevice): Int {
        val service = device.services[DesktopUpnpRendererServiceKind.AV_TRANSPORT]
        return service?.eventSubUri?.let(::desktopUpnpEffectivePort)
            ?: service?.controlUri?.let(::desktopUpnpEffectivePort)
            ?: 80
    }

    private fun openHomeRendererRoutePort(device: DesktopUpnpRendererDevice): Int {
        val service = device.services[DesktopUpnpRendererServiceKind.OPENHOME_PLAYLIST]
        return service?.eventSubUri?.let(::desktopUpnpEffectivePort)
            ?: service?.controlUri?.let(::desktopUpnpEffectivePort)
            ?: networkRendererRoutePort(device)
    }

    private fun openHomeIntentMatches(
        intent: DesktopOpenHomePlaybackIntent,
        transportState: String,
    ): Boolean = when (intent) {
        DesktopOpenHomePlaybackIntent.PLAY -> transportState.trim().lowercase() in setOf("playing", "buffering", "waiting")
        DesktopOpenHomePlaybackIntent.PAUSE -> transportState.trim().lowercase() in setOf("paused", "paused_playback")
        DesktopOpenHomePlaybackIntent.STOP -> transportState.equals("Stopped", ignoreCase = true)
    }

    private suspend fun networkRendererRouteChanged(active: DesktopUpnpActiveMediaPlayback): Boolean = try {
        withContext(Dispatchers.IO) {
            DesktopUpnpMediaServer.routeLocalAddress(
                active.rendererAddress,
                networkRendererRoutePort(active.device),
            )
        } != active.localAddress
    } catch (error: CancellationException) {
        throw error
    } catch (_: Exception) {
        false
    }

    private fun createNetworkRendererEventReceiver(
        bindAddress: InetAddress,
        rendererAddress: InetAddress,
        deviceIdentity: String,
        sessionToken: Any,
        sessionReady: AtomicBoolean,
        eventRevision: AtomicLong,
    ): DesktopUpnpEventReceiver {
        lateinit var receiver: DesktopUpnpEventReceiver
        receiver = DesktopUpnpEventReceiver(
            bindAddress = bindAddress,
            rendererAddress = rendererAddress,
            onEvent = { event ->
                val current = networkRendererActiveMediaPlayback
                if (sessionReady.get() && current != null && current.sessionToken === sessionToken &&
                    current.eventReceiver === receiver
                ) {
                    val revision = eventRevision.incrementAndGet()
                    scope.launch {
                        val active = networkRendererActiveMediaPlayback
                        if (active?.sessionToken !== sessionToken || active.eventReceiver !== receiver) return@launch
                        val previousStatus = networkRendererStatusByIdentity[deviceIdentity]
                            ?: DesktopUpnpRendererStatus()
                        val mergedStatus = mergeDesktopUpnpEventStatus(previousStatus, event)
                        networkRendererStatusByIdentity = networkRendererStatusByIdentity + (
                            deviceIdentity to mergedStatus
                        )
                        active.appliedEventRevision = revision
                        observeNetworkRendererPlayback(
                            active = active,
                            freshTrackUri = event.currentTrackUri ?: event.avTransportUri,
                            freshTransportState = event.transportState,
                            freshTransportStatus = event.transportStatus,
                            freshPositionMillis = event.relativeTimePosition?.let(::parseDesktopUpnpTime),
                            freshDurationMillis = event.currentTrackDuration?.let(::parseDesktopUpnpTime),
                        )
                    }
                }
            },
        )
        return receiver
    }

    private suspend fun recoverNetworkRendererEventReceiver(active: DesktopUpnpActiveMediaPlayback) {
        if (networkRendererActiveMediaPlayback?.sessionToken !== active.sessionToken ||
            !active.sessionReady.get() || active.eventReceiver != null
        ) return
        val eventEndpoint = active.device.services[DesktopUpnpRendererServiceKind.AV_TRANSPORT]?.eventSubUri
        if (!eventEndpoint?.scheme.equals("http", ignoreCase = true)) return
        if (!active.eventReceiverRetryPolicy.isAttemptDue(System.nanoTime())) return

        var createdReceiver: DesktopUpnpEventReceiver? = null
        val receiver = try {
            withContext(NonCancellable + Dispatchers.IO) {
                createNetworkRendererEventReceiver(
                    bindAddress = active.localAddress,
                    rendererAddress = active.rendererAddress,
                    deviceIdentity = active.device.identity,
                    sessionToken = active.sessionToken,
                    sessionReady = active.sessionReady,
                    eventRevision = active.eventRevision,
                ).also { createdReceiver = it }
            }
        } catch (error: CancellationException) {
            createdReceiver?.close()
            throw error
        } catch (_: Exception) {
            if (networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken &&
                active.sessionReady.get()
            ) {
                active.eventReceiverRetryPolicy.recordFailure(System.nanoTime())
            }
            return
        }

        var installed = false
        synchronized(active.eventSubscriptionLock) {
            if (networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken &&
                active.sessionReady.get() && active.eventReceiver == null
            ) {
                active.eventReceiver = receiver
                active.eventReceiverRetryPolicy.reset()
                startNetworkRendererEventRenewal(active, receiver, active.localAddress)
                installed = true
            }
        }
        if (!installed) receiver.close()
    }

    private fun startNetworkRendererEventRenewal(
        active: DesktopUpnpActiveMediaPlayback,
        receiver: DesktopUpnpEventReceiver,
        localAddress: InetAddress,
    ) {
        if (active.eventRenewalJob != null) return
        val rendererDevice = active.device
        val rendererAddress = active.rendererAddress
        val job = DesktopUpnpGenaSubscriptionManager(
            initialLease = active.eventLease,
            refreshRequests = active.eventRefreshRequests,
            retryDelayMillis = RETRY_UPNP_EVENT_SUBSCRIPTION_MILLIS,
            isCurrent = {
                networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken &&
                    active.eventReceiver === receiver
            },
            subscribe = {
                withContext(Dispatchers.IO) {
                    networkRendererGenaClient.subscribe(
                        rendererDevice,
                        rendererAddress,
                        localAddress,
                        receiver.callbackUri,
                    )
                }
            },
            renew = { sid ->
                withContext(Dispatchers.IO) {
                    networkRendererGenaClient.renew(
                        rendererDevice,
                        rendererAddress,
                        localAddress,
                        sid,
                    )
                }
            },
            installLease = { lease ->
                synchronized(active.eventSubscriptionLock) {
                    if (networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken &&
                        active.sessionReady.get() && active.eventReceiver === receiver
                    ) {
                        receiver.acceptSid(lease.sid)
                        active.eventLease = lease
                        true
                    } else {
                        false
                    }
                }
            },
            onLeaseChanged = { lease ->
                synchronized(active.eventSubscriptionLock) {
                    if (networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken &&
                        active.eventReceiver === receiver
                    ) {
                        active.eventLease = lease
                    }
                }
            },
            onSidCleared = {
                synchronized(active.eventSubscriptionLock) {
                    if (networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken &&
                        active.eventReceiver === receiver
                    ) {
                        receiver.clearSid()
                        active.eventLease = null
                    }
                }
            },
            abandonLease = { lease ->
                withContext(Dispatchers.IO) {
                    runCatching {
                        networkRendererGenaClient.unsubscribe(
                            rendererDevice,
                            rendererAddress,
                            localAddress,
                            lease.sid,
                        )
                    }
                }
            },
        ).start(scope)
        active.eventRenewalJob = job
        job.invokeOnCompletion {
            synchronized(active.eventSubscriptionLock) {
                if (active.eventRenewalJob === job) active.eventRenewalJob = null
            }
        }
    }

    private suspend fun createNetworkRendererMediaResources(
        active: DesktopUpnpActiveMediaPlayback,
        bindAddress: InetAddress,
        rendererAddress: InetAddress = active.rendererAddress,
        mimeTypes: List<String>? = null,
    ): DesktopUpnpMediaResources {
        var createdServer: DesktopUpnpMediaServer? = null
        val server = try {
            withContext(NonCancellable + Dispatchers.IO) {
                DesktopUpnpMediaServer(
                    bindAddress = bindAddress,
                    rendererAddress = rendererAddress,
                    leaseTtl = java.time.Duration.ofHours(12),
                ).also { createdServer = it }
            }
        } catch (error: Throwable) {
            createdServer?.close()
            throw error
        }
        return try {
            val originalQueue = active.mediaResources.queue
            require(mimeTypes == null || mimeTypes.size == originalQueue.size) {
                "Replacement media MIME list does not match the active queue."
            }
            val queue = withContext(Dispatchers.IO) {
                originalQueue.mapIndexed { index, media ->
                    val mimeType = mimeTypes?.get(index) ?: media.mimeType
                    val lease = server.reissueLease(media.lease, mimeType)
                        ?: throw DesktopUpnpMediaLeaseAuthorizationException(active.sessionToken)
                    DesktopUpnpQueuedMedia(
                        track = media.track,
                        mimeType = mimeType,
                        lease = lease,
                    )
                }
            }
            DesktopUpnpMediaResources(queue, server, bindAddress)
        } catch (error: Throwable) {
            server.close()
            throw error
        }
    }

    private suspend fun createOptionalNetworkRendererEventReceiver(
        active: DesktopUpnpActiveMediaPlayback,
        bindAddress: InetAddress,
        device: DesktopUpnpRendererDevice = active.device,
        rendererAddress: InetAddress = active.rendererAddress,
    ): DesktopUpnpEventReceiver? {
        val eventEndpoint = device.services[DesktopUpnpRendererServiceKind.AV_TRANSPORT]?.eventSubUri
        if (!eventEndpoint?.scheme.equals("http", ignoreCase = true)) return null
        var createdReceiver: DesktopUpnpEventReceiver? = null
        return try {
            withContext(NonCancellable + Dispatchers.IO) {
                createNetworkRendererEventReceiver(
                    bindAddress = bindAddress,
                    rendererAddress = rendererAddress,
                    deviceIdentity = device.identity,
                    sessionToken = active.sessionToken,
                    sessionReady = active.sessionReady,
                    eventRevision = active.eventRevision,
                ).also { createdReceiver = it }
            }
        } catch (error: CancellationException) {
            createdReceiver?.close()
            throw error
        } catch (_: Exception) {
            createdReceiver?.close()
            null
        }
    }

    private fun requestNetworkRendererRecovery(
        active: DesktopUpnpActiveMediaPlayback,
        snapshot: DesktopUpnpRendererStatus,
    ) {
        if (networkRendererActiveMediaPlayback?.sessionToken !== active.sessionToken ||
            !active.sessionReady.get() || active.explicitStopRequested.get() ||
            active.recoveryState.isCancelled || active.advanceInProgress.get() ||
            networkRendererOperationLoadingIdentity != null
        ) return
        val recoveryToken = active.recoveryState.beginRecovery() ?: return
        runNetworkRendererOperation(active.device) {
            var restored = false
            var stagedResources: DesktopUpnpMediaResources? = null
            var stagedReceiver: DesktopUpnpEventReceiver? = null
            var resourcesCommitted = false
            try {
                fun stillCurrent(): Boolean =
                    networkRendererActiveMediaPlayback?.sessionToken === active.sessionToken &&
                        active.sessionReady.get() && !active.explicitStopRequested.get() &&
                        !active.advanceInProgress.get() && active.recoveryState.isCurrentRecovery(recoveryToken)

                if (!stillCurrent()) return@runNetworkRendererOperation snapshot
                val originalBinding = active.binding
                val originalDevice = originalBinding.device
                val originalRendererAddress = originalBinding.rendererAddress
                val refreshRendererDescription = snapshot.connectionState == DesktopUpnpConnectionState.DISCONNECTED
                val recoveryDevice = if (refreshRendererDescription) {
                    networkRendererDiscovery.discover(timeoutMillis = 1_000L)
                        .firstOrNull { it.identity == originalDevice.identity && it.supportsAvTransport }
                        ?: throw IOException(tr("settings.network_renderer.recovery.device_not_found"))
                } else {
                    originalDevice
                }
                val recoveryRendererAddress = if (refreshRendererDescription) {
                    desktopUpnpNumericAddress(recoveryDevice.descriptionUri)
                        ?: throw IOException(tr("settings.network_renderer.local.device_address_unavailable"))
                } else {
                    originalRendererAddress
                }
                if (refreshRendererDescription) networkRendererClient.invalidateCapabilities(recoveryDevice)
                val originalResources = originalBinding.mediaResources
                val intent = active.recoveryState.intent
                val recoveryStatus = networkRendererClient.readStatus(recoveryDevice)
                if (!stillCurrent()) return@runNetworkRendererOperation snapshot
                val refreshedMimeTypes = if (refreshRendererDescription) {
                    originalResources.queue.map { media ->
                        val source = media.track.playbackSource as DesktopTrackSource.LocalFile
                        chooseDesktopUpnpHttpMime(
                            recoveryStatus.sinkProtocolInfo,
                            desktopUpnpMimeCandidates(source.absolutePath),
                        ) ?: throw IOException(tr("settings.network_renderer.local.format_unsupported"))
                    }
                } else {
                    null
                }
                val routedAddress = withContext(Dispatchers.IO) {
                    DesktopUpnpMediaServer.routeLocalAddress(
                        recoveryRendererAddress,
                        networkRendererRoutePort(recoveryDevice),
                    )
                }
                val resourcesChanged = refreshRendererDescription || routedAddress != originalResources.localAddress
                val targetResources = if (resourcesChanged) {
                    createNetworkRendererMediaResources(
                        active = active,
                        bindAddress = routedAddress,
                        rendererAddress = recoveryRendererAddress,
                        mimeTypes = refreshedMimeTypes,
                    ).also { stagedResources = it }
                } else {
                    originalResources
                }
                val media = targetResources.queue[active.queueIndex]
                val oldExpectedUri = originalResources.queue[active.queueIndex].lease.mediaUri.toASCIIString()
                val expectedUri = media.lease.mediaUri.toASCIIString()
                var plan = active.recoveryState.plan(
                    expectedUri,
                    recoveryStatus.trackUri,
                    recoveryStatus.transportState,
                ) ?: DesktopUpnpRecoveryPlan(
                    setMediaUri = false,
                    command = null,
                    intent = intent,
                )
                if (resourcesChanged) plan = plan.copy(setMediaUri = true)
                val savedCheckpoint = active.recoveryState.positionCheckpointForRecovery(oldExpectedUri)
                val checkpoint = if (resourcesChanged) {
                    desktopUpnpRebindPositionCheckpoint(savedCheckpoint, oldExpectedUri, expectedUri)
                } else {
                    savedCheckpoint
                }
                val seekTarget = when {
                    recoveryStatus.supportsRelativeTimeSeek != true -> null
                    resourcesChanged -> desktopUpnpRouteRebindSeekTarget(
                        checkpoint = savedCheckpoint,
                        previousUri = oldExpectedUri,
                        observedUri = recoveryStatus.trackUri,
                        observedState = recoveryStatus.transportState,
                        observedPositionMillis = recoveryStatus.positionMillis,
                        observedDurationMillis = recoveryStatus.durationMillis,
                        trackDurationMillis = media.track.durationMillis,
                    )
                    else -> desktopUpnpRecoverySeekTarget(
                        checkpoint = checkpoint,
                        expectedUri = expectedUri,
                        observedUri = recoveryStatus.trackUri,
                        observedState = recoveryStatus.transportState,
                        observedPositionMillis = recoveryStatus.positionMillis,
                        trackDurationMillis = media.track.durationMillis,
                    )
                }
                val recoveryPlan = plan.copy(seekPositionMillis = seekTarget)
                val didl = if (plan.setMediaUri) {
                    buildDesktopUpnpDidlMetadata(
                        title = media.track.title,
                        artist = media.track.artist,
                        album = media.track.album,
                        resourceUri = media.lease.mediaUri,
                        mimeType = media.mimeType,
                        fileSize = media.lease.fileSize,
                        durationMillis = media.track.durationMillis,
                    )
                } else {
                    ""
                }
                if (resourcesChanged) {
                    stagedReceiver = createOptionalNetworkRendererEventReceiver(
                        active,
                        targetResources.localAddress,
                        device = recoveryDevice,
                        rendererAddress = recoveryRendererAddress,
                    )
                }
                val positionSeekApplied = executeDesktopUpnpRecoveryPlan(
                    plan = recoveryPlan,
                    isCancelled = { !stillCurrent() },
                    setMediaUri = {
                        networkRendererClient.setMediaUri(recoveryDevice, media.lease.mediaUri, didl)
                    },
                    control = { command -> networkRendererClient.control(recoveryDevice, command) },
                    isSeekEnabled = {
                        var enabled = false
                        for (attempt in 0..3) {
                            if (!stillCurrent()) break
                            val currentStatus = networkRendererClient.readStatus(recoveryDevice)
                            enabled = stillCurrent() &&
                                currentStatus.trackUri == expectedUri &&
                                desktopUpnpRelativeTimeSeekEnabled(currentStatus)
                            if (enabled || attempt == 3) break
                            delay(250L)
                        }
                        enabled
                    },
                    seek = { target ->
                        if (stillCurrent()) networkRendererClient.seek(recoveryDevice, target)
                    },
                )
                if (!stillCurrent()) return@runNetworkRendererOperation snapshot
                val finalSnapshot = networkRendererClient.readPlaybackSnapshot(recoveryDevice)
                val positionRestored = when {
                    seekTarget == null -> true
                    positionSeekApplied -> desktopUpnpRecoveryPositionConfirmed(
                        targetPositionMillis = seekTarget,
                        observedPositionMillis = finalSnapshot.positionMillis,
                    )
                    else -> desktopUpnpRecoverySeekTarget(
                        checkpoint = checkpoint,
                        expectedUri = expectedUri,
                        observedUri = finalSnapshot.trackUri,
                        observedState = finalSnapshot.transportState,
                        observedPositionMillis = finalSnapshot.positionMillis,
                        trackDurationMillis = media.track.durationMillis,
                    ) == null
                }
                restored = desktopUpnpRecoveryConfirmed(
                    intent = intent,
                    expectedUri = expectedUri,
                    connectionState = finalSnapshot.connectionState,
                    observedUri = finalSnapshot.trackUri,
                    observedState = finalSnapshot.transportState,
                    observedTransportStatus = finalSnapshot.transportStatus,
                ) && positionRestored
                if (restored && resourcesChanged && stillCurrent()) {
                    var oldReceiver: DesktopUpnpEventReceiver? = null
                    var oldLease: DesktopUpnpGenaLease? = null
                    var oldRenewalJob: Job? = null
                    synchronized(active.eventSubscriptionLock) {
                        val currentBinding = active.binding
                        if (stillCurrent() && currentBinding.device === originalDevice &&
                            currentBinding.rendererAddress == originalRendererAddress &&
                            currentBinding.mediaResources === originalResources
                        ) {
                            oldReceiver = currentBinding.eventReceiver
                            oldLease = currentBinding.eventLease
                            oldRenewalJob = active.eventRenewalJob
                            active.eventRenewalJob = null
                            active.binding = currentBinding.copy(
                                device = recoveryDevice,
                                rendererAddress = recoveryRendererAddress,
                                mediaResources = targetResources,
                                eventReceiver = stagedReceiver,
                                eventLease = null,
                            )
                            resourcesCommitted = true
                            active.mediaLeaseRenewalSchedule.reset()
                            active.eventReceiverRetryPolicy.reset()
                            active.eventReconnectRefreshSent = false
                            active.appliedEventRevision = active.eventRevision.get()
                        }
                    }
                    if (resourcesCommitted) {
                        oldRenewalJob?.cancel()
                        stagedReceiver?.let { receiver ->
                            runCatching {
                                startNetworkRendererEventRenewal(
                                    active,
                                    receiver,
                                    targetResources.localAddress,
                                )
                            }
                        }
                        closeNetworkRendererGenaSubscription(
                            originalDevice,
                            originalRendererAddress,
                            originalResources.localAddress,
                            oldReceiver,
                            oldLease,
                        )
                        if (refreshRendererDescription) {
                            networkRendererDevices = networkRendererDevices.map { device ->
                                if (device.identity == recoveryDevice.identity) recoveryDevice else device
                            }
                        }
                        originalResources.close()
                        stagedResources = null
                        stagedReceiver = null
                    } else {
                        restored = false
                    }
                }
                finalSnapshot
            } finally {
                if (!resourcesCommitted) {
                    stagedReceiver?.close()
                    stagedResources?.close()
                }
                if (active.recoveryState.isCurrentRecovery(recoveryToken)) {
                    if (restored) {
                        active.recoveryFailureCount = 0
                        active.recoveryRetryAfterNanos = 0L
                    } else {
                        active.recoveryFailureCount = (active.recoveryFailureCount + 1).coerceAtMost(5)
                        active.recoveryRetryAfterNanos = System.nanoTime() +
                            desktopUpnpAdvanceRetryDelayMillis(active.recoveryFailureCount) * 1_000_000L
                    }
                }
                active.recoveryState.finishRecovery(recoveryToken, succeeded = restored)
            }
        }
    }

    private fun closeNetworkRendererGenaSubscription(
        device: DesktopUpnpRendererDevice,
        rendererAddress: InetAddress,
        localAddress: InetAddress,
        receiver: DesktopUpnpEventReceiver?,
        lease: DesktopUpnpGenaLease?,
    ) {
        receiver?.let {
            runCatching { it.clearSid() }
            it.close()
        }
        if (lease == null) return
        Thread({
            runCatching {
                networkRendererGenaClient.unsubscribe(device, rendererAddress, localAddress, lease.sid)
            }
        }, "upnp-gena-unsubscribe").apply {
            isDaemon = true
            start()
        }
    }

    private suspend fun stopNetworkRendererPlaybackBeforeLocalPlayback() {
        val openHomeIdentity = openHomeActiveTargetIdentity
        val openHomeDevice = openHomeIdentity?.let(openHomeMediaDevices::get)
        if (openHomeIdentity != null && openHomeDevice != null) {
            try {
                if (networkRendererOperationLoadingIdentity == openHomeIdentity) {
                    networkRendererOperationJob?.join()
                }
                val status = stopOpenHomeSession(openHomeIdentity, openHomeDevice)
                if (desktopOpenHomeCommandMatches(DesktopUpnpTransportCommand.STOP, status) &&
                    openHomeActiveTargetIdentity == openHomeIdentity
                ) {
                    openHomeActiveTargetIdentity = null
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                networkRendererOperationErrors = networkRendererOperationErrors + (
                    openHomeIdentity to (error.message ?: tr("settings.network_renderer.action_failed_generic"))
                )
            }
        }

        val active = networkRendererActiveMediaPlayback ?: return
        active.explicitStopRequested.set(true)
        active.recoveryState.cancel()
        try {
            // If a reconnect Play request was already on the wire, wait for that operation to
            // finish before sending Stop so the older request cannot arrive after the handoff.
            if (networkRendererOperationLoadingIdentity == active.device.identity) {
                networkRendererOperationJob?.join()
            }
            if (networkRendererActiveMediaPlayback?.sessionToken !== active.sessionToken) return
            networkRendererClient.control(active.device, DesktopUpnpTransportCommand.STOP)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            networkRendererOperationErrors = networkRendererOperationErrors + (
                active.device.identity to (error.message ?: tr("settings.network_renderer.action_failed_generic"))
            )
        } finally {
            closeActiveNetworkRendererMediaPlayback(active.device.identity)
        }
    }

    private fun stopLocalPlaybackAfterNetworkHandoff() {
        playJob?.cancel()
        val stopRequest = activePlaybackToken.beginRequest()
        standardPlayer.stop()
        nativePlayer?.let { player ->
            scope.launch {
                withContext(Dispatchers.IO) {
                    player.stopIfCurrent { activePlaybackToken.isCurrent(stopRequest) }
                }
            }
        }
        isPlaying = false
        isSeeking = false
        hifiStreamInfo = null
        hifiBitPerfectOpening = false
        hifiDoPOpening = false
        hifiNativeDsdOpening = false
        clearHifiOutputRecoveryIntent()
        progress = 0f
        bufferedProgress = 0f
        streamUrl = null
        streamBitrate = null
        publishSystemMedia(statusOverride = SystemMediaPlaybackStatus.STOPPED, forcePosition = true)
    }

    private fun runNetworkRendererOperation(
        device: DesktopUpnpRendererDevice,
        operation: suspend () -> DesktopUpnpRendererStatus,
    ) {
        if (networkRendererOperationLoadingIdentity != null) return
        val generation = ++networkRendererOperationGeneration
        val identity = device.identity
        networkRendererOperationLoadingIdentity = identity
        networkRendererOperationErrors = networkRendererOperationErrors - identity
        networkRendererOperationJob = scope.launch {
            try {
                val status = operation()
                if (generation == networkRendererOperationGeneration) {
                    val previousStatus = networkRendererStatusByIdentity[identity]
                    val publishedStatus = when {
                        status.isPlaybackSnapshot && previousStatus != null ->
                            mergeDesktopUpnpPlaybackSnapshot(previousStatus, status)
                        previousStatus != null && shouldUseOpenHomePlaylist(device) ->
                            mergeDesktopOpenHomeRendererStatus(previousStatus, status)
                        else -> status.copy(isPlaybackSnapshot = false)
                    }
                    networkRendererStatusByIdentity = networkRendererStatusByIdentity + (identity to publishedStatus)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (generation == networkRendererOperationGeneration &&
                    error is DesktopUpnpMediaLeaseAuthorizationException
                ) {
                    val active = networkRendererActiveMediaPlayback
                        ?.takeIf { it.sessionToken === error.sessionToken }
                    if (active != null) {
                        var rendererStopped = false
                        try {
                            networkRendererClient.control(active.device, DesktopUpnpTransportCommand.STOP)
                            rendererStopped = true
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Exception) {
                            // Revoke the old local capability even if the renderer cannot be stopped.
                        } finally {
                            networkRendererOperationErrors = networkRendererOperationErrors + (
                                identity to tr(
                                    if (rendererStopped) {
                                        "settings.network_renderer.local.lease_invalid"
                                    } else {
                                        "settings.network_renderer.local.lease_stop_failed"
                                    },
                                )
                            )
                            closeActiveNetworkRendererMediaPlayback(identity)
                        }
                    }
                } else if (generation == networkRendererOperationGeneration) {
                    networkRendererOperationErrors = networkRendererOperationErrors +
                        (identity to (error.message ?: tr("settings.network_renderer.action_failed_generic")))
                }
            } finally {
                if (generation == networkRendererOperationGeneration) {
                    networkRendererOperationLoadingIdentity = null
                    val deferredStop = networkRendererDeferredStopDevice
                    networkRendererDeferredStopDevice = null
                    if (deferredStop != null && controllerJob.isActive) {
                        controlNetworkRenderer(deferredStop, DesktopUpnpTransportCommand.STOP)
                    } else if (networkRendererDeferredOpenHomeCommands.isNotEmpty() && controllerJob.isActive) {
                        val (identity, deferred) = networkRendererDeferredOpenHomeCommands.entries.first()
                        networkRendererDeferredOpenHomeCommands.remove(identity)
                        controlNetworkRenderer(deferred.first, deferred.second)
                    }
                }
            }
        }
    }

    private fun resumeAfterOutputDeviceRefresh(fromAutomaticRecovery: Boolean = false) {
        val intent = hifiOutputRecoveryIntent ?: return
        val track = nowPlaying
        val selected = selectedHifiOutputDevice
        if (track == null || track.id != intent.trackId) {
            clearHifiOutputRecoveryIntent(cancelJob = !fromAutomaticRecovery)
            return
        }
        if (!canResumeAfterOutputRecovery(
                intent = intent,
                currentTrackId = track.id,
                selectedOutputIdentity = hifiOutputDeviceIdentity,
                selectedOutputAvailable = !hifiOutputDeviceUnavailable && selected?.active == true,
                selectedOutputIdentityStable = selected?.stableIdentity == true,
            )
        ) return

        clearHifiOutputRecoveryIntent(cancelJob = !fromAutomaticRecovery)
        val resumeProgress = intent.progressFor(track.durationMillis)
        // Any refresh can consume the loss intent, including one that began before the loss.
        // Keep the circuit breaker armed until this reopened stream actually advances.
        automaticResumeGuard.begin(resumeProgress)
        progress = resumeProgress
        bufferedProgress = 0f
        statusMessage = null
        resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = intent.wasPlaying)
    }

    private fun invalidateHifiEndpointVolume() {
        hifiEndpointVolumeGeneration += 1
        hifiEndpointVolumeScalar = null
        hifiEndpointVolumeLoading = false
        hifiEndpointVolumeError = false
    }

    fun refreshHifiEndpointVolume() {
        val device = selectedHifiEndpointVolumeDevice
        if (device?.reportsHardwareEndpointVolume != true) {
            invalidateHifiEndpointVolume()
            return
        }

        val request = ++hifiEndpointVolumeGeneration
        hifiEndpointVolumeLoading = true
        hifiEndpointVolumeError = false
        scope.launch {
            val result = runCatching {
                hifiEndpointVolumeMutex.withLock {
                    if (request != hifiEndpointVolumeGeneration) {
                        null
                    } else {
                        withContext(Dispatchers.IO) {
                            if (request == hifiEndpointVolumeGeneration) {
                                DesktopWasapiEndpointVolume.read(device.endpointId)
                            } else {
                                null
                            }
                        }
                    }
                }
            }
            if (request != hifiEndpointVolumeGeneration ||
                selectedHifiEndpointVolumeDevice?.identityKey != device.identityKey
            ) return@launch
            hifiEndpointVolumeLoading = false
            result.onSuccess { state ->
                if (state != null) hifiEndpointVolumeScalar = state.scalar
            }.onFailure {
                hifiEndpointVolumeScalar = null
                hifiEndpointVolumeError = true
            }
        }
    }

    fun setHifiEndpointVolume(value: Float) {
        val device = selectedHifiEndpointVolumeDevice ?: return
        if (!device.reportsHardwareEndpointVolume || !value.isFinite()) return
        val scalar = value.coerceIn(0f, 1f)
        val request = ++hifiEndpointVolumeGeneration
        hifiEndpointVolumeScalar = scalar
        hifiEndpointVolumeLoading = true
        hifiEndpointVolumeError = false
        scope.launch {
            val result = runCatching {
                hifiEndpointVolumeMutex.withLock {
                    if (request != hifiEndpointVolumeGeneration) {
                        null
                    } else {
                        withContext(Dispatchers.IO) {
                            if (request == hifiEndpointVolumeGeneration) {
                                DesktopWasapiEndpointVolume.write(device.endpointId, scalar)
                                DesktopWasapiEndpointVolume.read(device.endpointId)
                            } else {
                                null
                            }
                        }
                    }
                }
            }
            if (request != hifiEndpointVolumeGeneration ||
                selectedHifiEndpointVolumeDevice?.identityKey != device.identityKey
            ) return@launch
            hifiEndpointVolumeLoading = false
            result.onSuccess { state ->
                if (state != null) hifiEndpointVolumeScalar = state.scalar
            }.onFailure {
                hifiEndpointVolumeScalar = null
                hifiEndpointVolumeError = true
            }
        }
    }

    /** Queries the current endpoint's exact exclusive PCM candidates; it does not open a stream. */
    fun probeHifiOutputFormats() {
        if (!hifiEngineAvailable || hifiPcmFormatProbeLoading || hifiPcmSessionProbeLoading) return
        val device = hifiPcmFormatProbeDevice
        if (device == null || hifiOutputDeviceUnavailable) {
            clearHifiPcmFormatProbe()
            hifiPcmFormatProbeError = tr("settings.hifi.formats.no_device")
            return
        }

        val request = ++hifiPcmFormatProbeGeneration
        hifiPcmFormatProbeLoading = true
        hifiPcmFormatProbeError = null
        hifiPcmFormatProbeResults = emptyList()
        hifiPcmFormatProbeTarget = device
        hifiPcmFormatCapabilities = null
        scope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    DesktopWasapiPcmFormatProbe.probe(device.endpointId)
                }
            }
            if (request == hifiPcmFormatProbeGeneration && hifiPcmFormatProbeDevice?.identityKey == device.identityKey) {
                result.onSuccess { results ->
                    hifiPcmFormatProbeResults = results
                    hifiPcmFormatCapabilities = OutputCapabilities(
                        deviceId = device.identityKey,
                        displayName = device.friendlyName,
                        backend = AudioBackend.WasapiExclusive,
                        supportedFormats = results.asSequence()
                            .filter { it.status == DesktopWasapiPcmFormatProbeStatus.Supported }
                            .map { result ->
                                AudioFormat.Pcm(
                                    sampleRateHz = result.candidate.sampleRateHz,
                                    validBitsPerSample = result.candidate.validBits,
                                    containerBitsPerSample = result.candidate.containerBits,
                                    byteOrder = AudioByteOrder.LittleEndian,
                                    channelLayout = AudioChannelLayout.Stereo,
                                )
                            }
                            .distinct()
                            .toList(),
                        evidence = CapabilityEvidence.Probed,
                    )
                    if (results.any { it.status == DesktopWasapiPcmFormatProbeStatus.Error }) {
                        hifiPcmFormatProbeError = tr("settings.hifi.formats.partial_error")
                    }
                }.onFailure { error ->
                    hifiPcmFormatProbeResults = emptyList()
                    hifiPcmFormatCapabilities = null
                    hifiPcmFormatProbeError = "${tr("settings.hifi.formats.failed")}: ${error.message.orEmpty()}"
                }
            }
            if (request == hifiPcmFormatProbeGeneration) hifiPcmFormatProbeLoading = false
        }
    }

    /** Initializes each exact candidate once; no playback is started. */
    fun probeHifiOutputSessions() {
        if (!hifiEngineAvailable || hifiPcmSessionProbeLoading || hifiPcmFormatProbeLoading) return
        val device = hifiPcmFormatProbeDevice
        if (device == null || hifiOutputDeviceUnavailable) {
            clearHifiPcmSessionProbe()
            hifiPcmSessionProbeError = tr("settings.hifi.session_probe.no_device")
            return
        }
        val outputActive = isPlaying || streamUrl != null ||
            (usesNativeAudioFor(nowPlaying) && (hifiStreamInfo != null || hifiBitPerfectOpening)) ||
            hifiPcmTestToneStatus == DesktopHiFiTestToneStatus.Preparing ||
            hifiPcmTestToneStatus == DesktopHiFiTestToneStatus.Playing
        if (outputActive) {
            clearHifiPcmSessionProbe()
            hifiPcmSessionProbeError = tr("settings.hifi.session_probe.stop_output")
            return
        }

        val request = ++hifiPcmSessionProbeGeneration
        hifiPcmSessionProbeLoading = true
        hifiPcmSessionProbeError = null
        hifiPcmSessionProbeResults = emptyList()
        hifiPcmSessionProbeTarget = device
        scope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    DesktopWasapiPcmSessionProbe.probe(device.endpointId)
                }
            }
            if (request == hifiPcmSessionProbeGeneration &&
                hifiPcmFormatProbeDevice?.identityKey == device.identityKey
            ) {
                result.onSuccess { results ->
                    hifiPcmSessionProbeResults = results
                    if (results.any { it.status == DesktopWasapiPcmSessionProbeStatus.Error }) {
                        hifiPcmSessionProbeError = tr("settings.hifi.session_probe.partial_error")
                    }
                }.onFailure {
                    hifiPcmSessionProbeResults = emptyList()
                    hifiPcmSessionProbeError = tr("settings.hifi.session_probe.failed")
                }
            }
            if (request == hifiPcmSessionProbeGeneration) hifiPcmSessionProbeLoading = false
        }
    }

    private fun clearHifiPcmSessionProbe() {
        hifiPcmSessionProbeGeneration++
        hifiPcmSessionProbeLoading = false
        hifiPcmSessionProbeError = null
        hifiPcmSessionProbeResults = emptyList()
        hifiPcmSessionProbeTarget = null
    }

    private fun clearHifiPcmFormatProbe() {
        hifiPcmFormatProbeGeneration++
        hifiPcmFormatProbeLoading = false
        hifiPcmFormatProbeError = null
        hifiPcmFormatProbeResults = emptyList()
        hifiPcmFormatProbeTarget = null
        hifiPcmFormatCapabilities = null
        clearHifiPcmSessionProbe()
    }

    /** Saves only the allow-listed, privacy-conscious HiFi snapshot to the chosen destination. */
    internal fun exportHifiDiagnostics(destination: File) {
        if (hifiDiagnosticsExportStatus == DesktopHiFiDiagnosticsExportStatus.Exporting) return

        val report = runCatching {
            DesktopHiFiDiagnostics.toJson(
                DesktopHiFiDiagnosticsSnapshot(
                    nativeEngineAvailable = hifiEngineAvailable,
                    nativeEngineSelected = hifiEngineEnabled,
                    bitPerfectRequested = hifiBitPerfect,
                    bufferMillis = hifiBufferMillis,
                    equalizerEnabled = equalizer.enabled,
                    deviceSelection = when {
                        hifiOutputDeviceUnavailable -> DesktopHiFiDeviceSelection.SavedDeviceUnavailable
                        hifiOutputDeviceIdentity != null -> DesktopHiFiDeviceSelection.Explicit
                        else -> DesktopHiFiDeviceSelection.SystemDefault
                    },
                    activeOutputDeviceCount = hifiOutputDevices.count { it.active },
                    deviceCatalogLoading = hifiOutputDevicesLoading,
                    deviceCatalogFailed = hifiOutputDevicesError != null,
                    activeOutputDevice = selectedHifiOutputDevice ?: selectedHifiEndpointVolumeDevice,
                    endpointVolumeReadSucceeded = hifiEndpointVolumeScalar != null,
                    pcmFormatProbeLoading = hifiPcmFormatProbeLoading,
                    pcmFormatProbeFailed = hifiPcmFormatProbeError != null,
                    pcmFormatProbeResults = hifiPcmFormatProbeResults,
                    stream = hifiStreamInfo,
                ),
            )
        }.getOrElse {
            hifiDiagnosticsExportStatus = DesktopHiFiDiagnosticsExportStatus.Failed
            return
        }

        hifiDiagnosticsExportStatus = DesktopHiFiDiagnosticsExportStatus.Exporting
        scope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    destination.writeText(report, Charsets.UTF_8)
                }
            }
            hifiDiagnosticsExportStatus = if (result.isSuccess) {
                DesktopHiFiDiagnosticsExportStatus.Saved
            } else {
                DesktopHiFiDiagnosticsExportStatus.Failed
            }
        }
    }

    /** Plays a quiet generated PCM WAV through the native WASAPI path, outside the music queue. */
    internal fun playHiFiPcmTestTone(sampleRateHz: Int, bitDepth: Int) {
        if (hifiPcmTestToneStatus == DesktopHiFiTestToneStatus.Preparing ||
            hifiPcmTestToneStatus == DesktopHiFiTestToneStatus.Playing
        ) return
        val player = nativePlayer
        if (player == null || !hifiEngineEnabled || hifiOutputDeviceUnavailable) {
            hifiPcmTestToneStatus = DesktopHiFiTestToneStatus.Failed
            return
        }

        clearHifiOutputRecoveryIntent()
        val resume = nowPlaying?.let { track ->
            DesktopHiFiTestToneResume(track, progress.coerceIn(0f, 0.999f), isPlaying)
        }
        playJob?.cancel()
        activePlaybackToken.beginRequest()
        if (audioPlayer !== nativePlayer) audioPlayer.stop()
        isPlaying = false
        hifiStreamInfo = null
        hifiBitPerfectOpening = false
        hifiDoPOpening = false
        hifiNativeDsdOpening = false
        hifiPcmTestToneResume = resume
        val generation = ++hifiPcmTestToneGeneration
        hifiPcmTestToneStatus = DesktopHiFiTestToneStatus.Preparing
        hifiPcmTestToneJob?.cancel()
        hifiPcmTestToneJob = scope.launch {
            var testFile: File? = null
            var playerOwnsFile = false
            try {
                testFile = withContext(Dispatchers.IO) {
                    val path = Files.createTempFile("lazer-hifi-pcm-test-", ".wav")
                    try {
                        DesktopPcmTestWave.write(path, sampleRateHz, channels = 2, bitDepth = bitDepth)
                        path.toFile().apply { deleteOnExit() }
                    } catch (error: Throwable) {
                        Files.deleteIfExists(path)
                        throw error
                    }
                }
                if (generation != hifiPcmTestToneGeneration) {
                    testFile?.delete()
                    return@launch
                }

                val source = requireNotNull(testFile)
                playerOwnsFile = true
                withContext(Dispatchers.IO) {
                    player.playPcmTestFile(
                        file = source,
                        durationMillis = DesktopPcmTestWave.DURATION_MILLISECONDS.toLong(),
                        volume = volume,
                    ) { error ->
                        scope.launch { finishHiFiPcmTestTone(generation, error) }
                    }
                }
                if (generation == hifiPcmTestToneGeneration) {
                    hifiPcmTestToneStatus = DesktopHiFiTestToneStatus.Playing
                }
            } catch (error: CancellationException) {
                if (!playerOwnsFile) testFile?.delete()
                throw error
            } catch (_: Throwable) {
                if (!playerOwnsFile) testFile?.delete()
                finishHiFiPcmTestTone(generation, IllegalStateException("PCM test tone failed"))
            }
        }
    }

    /** Stops the test tone and, when requested, restores the interrupted music stream. */
    internal fun stopHiFiPcmTestTone(restorePlayback: Boolean = true) {
        if (hifiPcmTestToneStatus != DesktopHiFiTestToneStatus.Preparing &&
            hifiPcmTestToneStatus != DesktopHiFiTestToneStatus.Playing
        ) return

        ++hifiPcmTestToneGeneration
        hifiPcmTestToneJob?.cancel()
        hifiPcmTestToneJob = null
        val stopRequest = activePlaybackToken.beginRequest()
        nativePlayer?.let { player ->
            scope.launch {
                withContext(Dispatchers.IO) {
                    player.stopIfCurrent { activePlaybackToken.isCurrent(stopRequest) }
                }
            }
        }
        hifiStreamInfo = null
        hifiBitPerfectOpening = false
        hifiDoPOpening = false
        hifiNativeDsdOpening = false
        hifiPcmTestToneStatus = DesktopHiFiTestToneStatus.Idle
        val resume = hifiPcmTestToneResume
        hifiPcmTestToneResume = null
        if (resume != null && nowPlaying?.id == resume.track.id) {
            isPlaying = resume.wasPlaying
            if (restorePlayback) {
                resolveAndPlay(
                    resume.track,
                    resumeProgress = resume.progress,
                    playWhenReady = resume.wasPlaying,
                )
            }
        }
    }

    private fun finishHiFiPcmTestTone(generation: Long, error: Throwable?) {
        if (generation != hifiPcmTestToneGeneration) return
        if (hifiPcmTestToneStatus != DesktopHiFiTestToneStatus.Preparing &&
            hifiPcmTestToneStatus != DesktopHiFiTestToneStatus.Playing
        ) return

        hifiPcmTestToneJob = null
        hifiStreamInfo = null
        hifiBitPerfectOpening = false
        hifiDoPOpening = false
        hifiNativeDsdOpening = false
        hifiPcmTestToneStatus = if (error == null) {
            DesktopHiFiTestToneStatus.Completed
        } else {
            DesktopHiFiTestToneStatus.Failed
        }
        val resume = hifiPcmTestToneResume
        hifiPcmTestToneResume = null
        if (resume != null && nowPlaying?.id == resume.track.id) {
            resolveAndPlay(
                resume.track,
                resumeProgress = resume.progress,
                playWhenReady = resume.wasPlaying,
            )
        }
    }

    internal fun selectHifiOutputDevice(device: DesktopAudioOutputDevice?) {
        val identity = device?.identityKey
        if (hifiOutputDeviceIdentity == identity && !hifiOutputDeviceUnavailable) return
        val recovery = hifiOutputRecoveryIntent
        clearHifiOutputRecoveryIntent()
        stopHiFiPcmTestTone(restorePlayback = false)
        hifiOutputDeviceIdentity = identity
        hifiOutputDeviceUnavailable = false
        clearHifiPcmFormatProbe()
        DesktopSettings.hifiDeviceIdentity = identity
        nativePlayer?.setOutputDevice(device?.deviceToken)
        refreshHifiEndpointVolume()
        val track = nowPlaying ?: return
        if (usesNativeAudioFor(track) &&
            (isPlaying || streamUrl != null || recovery?.trackId == track.id ||
                (track.isLocalFile && hifiStreamInfo != null))
        ) {
            val matchingRecovery = recovery?.takeIf { it.trackId == track.id }
            val resumeProgress = matchingRecovery?.progressFor(track.durationMillis) ?: progress
            val playWhenReady = matchingRecovery?.wasPlaying ?: isPlaying
            progress = resumeProgress
            bufferedProgress = 0f
            resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = playWhenReady)
        }
    }

    fun updateHifiBitPerfect(enabled: Boolean) {
        val player = nativePlayer ?: return
        if (!supportsDesktopBitPerfectOutput() || hifiBitPerfect == enabled) return
        if (enabled && volume < 0.999999f) {
            statusMessage = tr("status.hifi.bit_perfect_volume")
            return
        }
        clearHifiOutputRecoveryIntent()
        stopHiFiPcmTestTone(restorePlayback = false)
        if (statusMessage == tr("status.hifi.bit_perfect_volume")) statusMessage = null
        if (enabled && desktopBitPerfectRequiresExclusiveRequest() && !exclusiveAudio) {
            exclusiveAudio = true
            DesktopSettings.exclusiveAudio = true
        }
        if (enabled && hifiDoPOutput) {
            hifiDoPOutput = false
            DesktopSettings.hifiDoPOutput = false
            player.setDoPOutput(false)
        }
        if (enabled && hifiNativeDsdOutput) {
            hifiNativeDsdOutput = false
            DesktopSettings.hifiNativeDsdOutput = false
            player.setNativeDsdOutput(false)
        }
        hifiBitPerfect = enabled
        hifiBitPerfectOpening = false
        hifiDoPOpening = false
        hifiNativeDsdOpening = false
        DesktopSettings.hifiBitPerfect = enabled
        val track = nowPlaying
        val shouldRebuildPlayback = usesNativeAudioFor(track) && track != null &&
            (isPlaying || streamUrl != null || hifiStreamInfo != null || hifiBitPerfectOpening)
        val resumeProgress = progress
        val playWhenReady = isPlaying
        scope.launch {
            player.setExclusiveAudio(exclusiveAudio)
            player.setBitPerfect(enabled)
            if (shouldRebuildPlayback) {
                bufferedProgress = 0f
                resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = playWhenReady)
            }
        }
    }

    fun updateHifiDoPOutput(enabled: Boolean) {
        val player = nativePlayer ?: return
        if (hifiDoPOutput == enabled) return
        if (enabled && volume < 0.999999f) {
            statusMessage = tr("status.hifi.dop_volume")
            return
        }
        clearHifiOutputRecoveryIntent()
        stopHiFiPcmTestTone(restorePlayback = false)
        if (statusMessage == tr("status.hifi.dop_volume")) statusMessage = null
        if (enabled && !exclusiveAudio) {
            exclusiveAudio = true
            DesktopSettings.exclusiveAudio = true
        }
        if (enabled && hifiBitPerfect) {
            hifiBitPerfect = false
            DesktopSettings.hifiBitPerfect = false
        }
        if (enabled && hifiNativeDsdOutput) {
            hifiNativeDsdOutput = false
            DesktopSettings.hifiNativeDsdOutput = false
            player.setNativeDsdOutput(false)
        }
        hifiDoPOutput = enabled
        DesktopSettings.hifiDoPOutput = enabled
        player.clearQueuedNext()
        val track = nowPlaying
        val currentSourceIsDsd = hifiStreamInfo?.hasDsdSource == true
        val shouldRebuildPlayback = usesNativeAudioFor(track) && currentSourceIsDsd && track != null &&
            (isPlaying || streamUrl != null)
        val resumeProgress = progress
        val playWhenReady = isPlaying
        scope.launch {
            player.setExclusiveAudio(exclusiveAudio)
            player.setBitPerfect(hifiBitPerfect)
            player.setDoPOutput(enabled)
            if (shouldRebuildPlayback) {
                bufferedProgress = 0f
                resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = playWhenReady)
            }
        }
    }

    fun updateHifiNativeDsdOutput(enabled: Boolean) {
        val player = nativePlayer ?: return
        if (enabled && !supportsDesktopNativeDsdOutput()) return
        if (hifiNativeDsdOutput == enabled) return
        val currentTrack = nowPlaying
        val currentSourceIsDsd = hifiStreamInfo?.hasDsdSource == true ||
            (currentTrack?.playbackSource as? DesktopTrackSource.LocalFile)?.let { source ->
                isDsdLocalAudioFile(File(source.absolutePath))
            } == true
        val currentDsdPlaybackWillReopen = currentSourceIsDsd && currentTrack != null &&
            (isPlaying || streamUrl != null || hifiStreamInfo != null)
        if (enabled && currentDsdPlaybackWillReopen && volume < 0.999999f) {
            statusMessage = tr("status.hifi.native_dsd_volume")
            return
        }
        if (enabled && currentDsdPlaybackWillReopen) {
            val currentGain = currentTrack?.let {
                resolveDesktopReplayGain(it.replayGain, replayGainMode).appliedGainDb
            } ?: 0.0
            if (equalizer.enabled || currentGain != 0.0) {
                statusMessage = tr("status.hifi.native_dsd_dsp")
                return
            }
        }
        if (statusMessage == tr("status.hifi.native_dsd_volume") ||
            statusMessage == tr("status.hifi.native_dsd_dsp")
        ) statusMessage = null
        clearHifiOutputRecoveryIntent()
        stopHiFiPcmTestTone(restorePlayback = false)
        if (enabled) {
            exclusiveAudio = true
            DesktopSettings.exclusiveAudio = true
        }
        val bitPerfectPreferenceWasActive = hifiBitPerfect
        if (enabled && hifiBitPerfect) {
            hifiBitPerfect = false
            DesktopSettings.hifiBitPerfect = false
        }
        if (enabled && hifiDoPOutput) {
            hifiDoPOutput = false
            DesktopSettings.hifiDoPOutput = false
            player.setDoPOutput(false)
        }
        hifiNativeDsdOutput = enabled
        DesktopSettings.hifiNativeDsdOutput = enabled
        hifiNativeDsdOpening = false
        player.clearQueuedNext()
        val track = currentTrack
        val modeRequiresRebuild = currentSourceIsDsd || (enabled && bitPerfectPreferenceWasActive)
        val shouldRebuildPlayback = usesNativeAudioFor(track) && modeRequiresRebuild && track != null &&
            (isPlaying || streamUrl != null || hifiStreamInfo != null)
        val resumeProgress = progress
        val playWhenReady = isPlaying
        scope.launch {
            player.setExclusiveAudio(exclusiveAudio)
            player.setBitPerfect(hifiBitPerfect)
            player.setNativeDsdOutput(enabled)
            if (shouldRebuildPlayback) {
                bufferedProgress = 0f
                resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = playWhenReady)
            }
        }
    }

    /** Persists the listener's equalizer and hands it to the audio engine immediately. */
    fun updateEqualizer(state: LazerEqualizerState) {
        if (hifiStreamInfo?.isNativeDsdOutput == true && state.enabled) {
            statusMessage = tr("status.hifi.native_dsd_dsp")
            return
        }
        equalizer = state
        DesktopSettings.equalizer = state
        standardPlayer.setEqualizer(state)
        nativePlayer?.setEqualizer(state)
    }

    fun updateReplayGainMode(mode: DesktopReplayGainMode) {
        if (replayGainMode == mode) return
        if (hifiStreamInfo?.isNativeDsdOutput == true && mode != DesktopReplayGainMode.Off) {
            val gain = nowPlaying?.let { resolveDesktopReplayGain(it.replayGain, mode).appliedGainDb } ?: 0.0
            if (gain != 0.0) {
                statusMessage = tr("status.hifi.native_dsd_dsp")
                return
            }
        }
        replayGainMode = mode
        DesktopSettings.replayGainMode = mode
        val track = nowPlaying?.takeIf(TrackItem::isLocalFile) ?: return
        val resumeProgress = progress
        val playWhenReady = isPlaying
        scope.launch { resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = playWhenReady) }
    }

    /** Live feedback while a slider is held; the disk write waits for the release. */
    fun previewEqualizer(state: LazerEqualizerState) {
        equalizer = state
        standardPlayer.setEqualizer(state)
        nativePlayer?.setEqualizer(state)
    }

    fun toggleLiked() {
        val track = nowPlaying ?: return
        if (track.isLocalFile) {
            statusMessage = tr("status.local_audio.like_unavailable")
            return
        }
        val user = currentUser
        if (user == null) {
            openLogin()
            return
        }
        val next = !isLiked
        val previousLikedTracks = likedTracks
        isLiked = next
        likedTracks = if (next) {
            listOf(track) + likedTracks.filterNot { it.id == track.id }
        } else {
            likedTracks.filterNot { it.id == track.id }
        }
        playlistCache.saveLikedTracks(user.userId, likedTracks)
        scope.launch {
            runCatching { gateway.updateSongLiked(track.id, user.userId, next) }
                .onFailure {
                    isLiked = !next
                    likedTracks = previousLikedTracks
                    playlistCache.saveLikedTracks(user.userId, previousLikedTracks)
                    statusMessage = tr("status.like_fail")
                }
        }
    }

    /** Start listening right away from one random track of this list, in shuffle mode. */
    fun shufflePlay(tracks: List<TrackItem>) {
        val track = tracks.randomOrNull() ?: return
        setPlayMode(DesktopPlayMode.Shuffle)
        playTrack(track)
    }

    /** One button walks through all four mutually exclusive playback modes. */
    fun cyclePlayMode() {
        setPlayMode(playModeState.nextOnClick())
    }

    fun setPlayMode(mode: DesktopPlayMode) {
        if (playModeState == mode) return
        if (!localPlaybackQueueRestoreCompleted) playModeChangedBeforeLocalQueueRestore = true
        playModeState = mode
        shuffleRemaining.clear()
        shuffleVisited.clear()
        if (mode == DesktopPlayMode.Shuffle) {
            nowPlaying?.let { shuffleVisited.addLast(it.id) }
        }
        // Say the new mode out loud; an icon tint alone reads as decoration.
        statusMessage = tr("player.mode.now", tr(mode.labelKey))
        refreshGaplessSuccessor()
        persistLocalPlaybackQueue(immediate = true)
    }

    /** The order playback follows, including any edit made in the queue card. */
    val queue: List<TrackItem> get() = effectiveQueue()

    fun playQueueAt(position: Int) {
        effectiveQueue().getOrNull(position)?.let { playTrack(it) }
    }

    fun removeFromQueue(position: Int) {
        val remaining = effectiveQueue().toMutableList()
        if (position !in remaining.indices) return
        val wasAudible = remaining[position].id == nowPlaying?.id
        remaining.removeAt(position)
        rememberQueueOrder(remaining)
        if (wasAudible) {
            // Dropping the last item while it plays wraps, rather than stopping with a queue left.
            (remaining.getOrNull(position) ?: remaining.firstOrNull())?.let(::playTrack)
                ?: stopFromQueueEnd()
        } else {
            refreshGaplessSuccessor()
        }
    }

    fun moveInQueue(from: Int, to: Int) {
        val reordered = effectiveQueue().toMutableList()
        if (from !in reordered.indices || to !in reordered.indices || from == to) return
        reordered.add(to, reordered.removeAt(from))
        rememberQueueOrder(reordered)
        refreshGaplessSuccessor()
    }

    private fun rememberQueueOrder(order: List<TrackItem>) {
        localPlaybackQueueNeedsFullWrite.set(true)
        queueEdit = QueueEdit(base = baseQueue(), order = order)
        persistLocalPlaybackQueue(immediate = true)
    }

    fun openPlaylist(playlist: PlaylistItem) {
        val requestGeneration = ++playlistRequestGeneration
        playlistJob?.cancel()
        // Publish the header immediately so the detail sheet doesn't flash empty.
        activePlaylist = playlist
        activePlaylistTracks = emptyList()
        playlistJob = scope.launch {
            val cached = withContext(Dispatchers.IO) { playlistCache.loadTracks(playlist.id) }
            if (!isCurrentPlaylistRequest(playlist.id, requestGeneration)) return@launch
            if (cached != null && cached.tracks.isNotEmpty()) {
                showPlaylist(playlist, cached.tracks)
                statusMessage = if (cached.complete) {
                    tr("status.opening_local")
                } else {
                    tr("status.opening_local_partial", cached.tracks.size)
                }
            }
            beginRequest(tr("status.opening_playlist", playlist.title))
            try {
                val tracks = loadCompletePlaylist(playlist, requestGeneration)
                if (isCurrentPlaylistRequest(playlist.id, requestGeneration) && tracks.isNotEmpty()) {
                    showPlaylist(playlist, tracks)
                    if (playlist.isLikedCollection) {
                        likedTracks = tracks
                    }
                }
                if (isCurrentPlaylistRequest(playlist.id, requestGeneration)) {
                    statusMessage = if (tracks.isEmpty()) tr("status.playlist_empty") else null
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isCurrentPlaylistRequest(playlist.id, requestGeneration)) {
                    statusMessage = error.toFriendlyMessage(tr("status.playlist_sync_fail"))
                }
            } finally {
                endRequest()
            }
        }
    }

    fun syncLibrary() {
        val profile = currentUser ?: run {
            openLogin()
            return
        }
        scope.launch {
            beginRequest(tr("status.syncing_playlists"))
            try {
                syncUserLibrary(profile)
                val syncedMessage = tr("status.synced")
                statusMessage = syncedMessage
                delay(1_600)
                if (statusMessage == syncedMessage) statusMessage = null
            } catch (error: Throwable) {
                statusMessage = error.toFriendlyMessage(tr("status.playlist_sync_fail"))
            } finally {
                endRequest()
            }
        }
    }

    fun clearSongCache() {
        maintenanceJob?.cancel()
        maintenanceJob = scope.launch {
            playJob?.cancel()
            activePlaybackToken.beginRequest()
            isPlaying = false
            isSeeking = false
            streamUrl = null
            streamBitrate = null
            streamUrls.clear()
            streamUrlPrefetches.clear()
            bufferedProgress = 0f
            val removed = withContext(Dispatchers.IO) {
                standardPlayer.clearCache() + (nativePlayer?.clearCache() ?: 0)
            }
            publishSystemMedia(
                statusOverride = SystemMediaPlaybackStatus.STOPPED,
                forcePosition = true,
            )
            statusMessage = if (removed > 0) tr("status.songs_cleared") else tr("status.songs_empty")
        }
    }

    fun clearPlaylistCache() {
        val removed = playlistCache.clearPlaylistData()
        statusMessage = if (removed > 0) tr("status.playlists_cleared") else tr("status.playlists_empty")
    }

    fun forceResync() {
        maintenanceJob?.cancel()
        bootstrapJob?.cancel()
        maintenanceJob = scope.launch {
            beginRequest(tr("status.resyncing"))
            try {
                currentUser?.let { syncUserLibrary(it, forceRefresh = true) }
                    ?: loadPublicLibrary(forceRefresh = true)
                statusMessage = tr("status.resynced")
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                statusMessage = error.toFriendlyMessage(tr("status.resync_fail"))
            } finally {
                endRequest()
            }
        }
    }

    fun openLogin() {
        isLoginVisible = true
        loginMethod = LoginMethod.QR_CODE
        loginError = null
        if (qrLoginState !in setOf(QrLoginState.CREATING, QrLoginState.WAITING_FOR_SCAN, QrLoginState.WAITING_FOR_CONFIRMATION)) {
            startQrLogin()
        }
    }

    fun closeLogin() {
        isLoginVisible = false
        qrLoginJob?.cancel()
        qrLoginState = QrLoginState.IDLE
        loginCookie = ""
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
                val tracks = gateway.artistTopSongs(artist.id).songs.map { it.toTrackItem() }
                if (activeArtist?.id == artist.id) activeArtistTracks = tracks
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (activeArtist?.id == artist.id) {
                    statusMessage = error.toFriendlyMessage(tr("artist.load_fail"))
                }
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

    fun saveArtwork(url: String, title: String, target: java.io.File) {
        scope.launch {
            beginRequest(tr("cover.save.saving"))
            try {
                withContext(Dispatchers.IO) {
                    val connection = java.net.URI(url).toURL().openConnection().apply {
                        connectTimeout = 12_000
                        readTimeout = 20_000
                        setRequestProperty("User-Agent", "Lazer/1.2")
                    }
                    target.parentFile?.mkdirs()
                    val temporary = java.io.File(target.parentFile, ".${target.name}.${System.nanoTime()}.part")
                    try {
                        connection.getInputStream().buffered().use { input ->
                            temporary.outputStream().buffered().use(input::copyTo)
                        }
                        java.nio.file.Files.move(
                            temporary.toPath(),
                            target.toPath(),
                            java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                        )
                    } finally {
                        temporary.delete()
                    }
                }
                statusMessage = tr("cover.save.success", title)
            } catch (error: Throwable) {
                statusMessage = error.toFriendlyMessage(tr("cover.save.fail"))
            } finally {
                endRequest()
            }
        }
    }

    fun selectLoginMethod(method: LoginMethod) {
        loginMethod = method
        loginError = null
        if (method != LoginMethod.QR_CODE) {
            qrLoginJob?.cancel()
            qrLoginState = QrLoginState.IDLE
        }
        if (method == LoginMethod.QR_CODE && qrLoginState !in setOf(
                QrLoginState.CREATING,
                QrLoginState.WAITING_FOR_SCAN,
                QrLoginState.WAITING_FOR_CONFIRMATION,
            )
        ) {
            startQrLogin()
        }
    }

    fun updateLoginIdentifier(value: String) {
        loginIdentifier = value
        loginError = null
    }

    fun updateLoginPassword(value: String) {
        loginPassword = value
        loginError = null
    }

    fun updateLoginCookie(value: String) {
        loginCookie = value
        loginError = null
    }

    fun startQrLogin() {
        qrLoginJob?.cancel()
        qrLoginJob = scope.launch {
            qrLoginState = QrLoginState.CREATING
            qrImageData = null
            qrFallbackUrl = null
            loginError = null
            try {
                val key = gateway.createQrKey().data?.unikey.orEmpty()
                check(key.isNotBlank()) { tr("login.qr_key_empty") }
                val code = gateway.createQrCode(key, includeImage = true).data
                qrImageData = code?.qrimg
                qrFallbackUrl = code?.qrurl?.let(::normalizeGatewayQrLoginUrl)
                check(!qrImageData.isNullOrBlank() || !qrFallbackUrl.isNullOrBlank()) { tr("login.qr_empty") }
                qrLoginState = QrLoginState.WAITING_FOR_SCAN

                while (isActive) {
                    // The desktop client polls once a second.
                    delay(1_000)
                    val result = gateway.checkQrCode(key)
                    when (result.code) {
                        QrCheckResponse.EXPIRED_CODE -> {
                            qrLoginState = QrLoginState.EXPIRED
                            return@launch
                        }
                        QrCheckResponse.WAITING_FOR_SCAN_CODE -> qrLoginState = QrLoginState.WAITING_FOR_SCAN
                        QrCheckResponse.WAITING_FOR_CONFIRMATION_CODE -> qrLoginState = QrLoginState.WAITING_FOR_CONFIRMATION
                        // Risk control: the scan landed, the phone has one more check to clear.
                        QrCheckResponse.RISK_CONTROL_CODE -> qrLoginState = QrLoginState.WAITING_FOR_CONFIRMATION
                        QrCheckResponse.AUTHORIZED_CODE -> {
                            qrLoginState = QrLoginState.AUTHORIZED
                            // Close the sheet immediately; library sync continues in the background.
                            finishSignInAndClose()
                            return@launch
                        }
                        else -> {
                            loginError = if (language == LazerLanguage.SIMPLIFIED_CHINESE) {
                                result.message ?: result.msg ?: tr("login.qr_code_fail", result.code)
                            } else {
                                tr("login.qr_code_fail", result.code)
                            }
                            qrLoginState = QrLoginState.ERROR
                            return@launch
                        }
                    }
                }
            } catch (error: Throwable) {
                qrLoginState = QrLoginState.ERROR
                loginError = error.toFriendlyMessage(tr("login.qr_gen_fail_retry"))
            }
        }
    }

    fun submitPasswordLogin() {
        val identifier = loginIdentifier.trim()
        if (identifier.isBlank() || loginPassword.isBlank()) {
            loginError = tr("login.enter_credentials")
            return
        }
        scope.launch {
            isSubmittingLogin = true
            loginError = null
            try {
                val response = if ('@' in identifier) {
                    gateway.loginWithEmail(identifier, loginPassword)
                } else {
                    gateway.loginWithPhonePassword(
                        phone = identifier.removePrefix("+86").replace(" ", ""),
                        password = loginPassword,
                        countryCode = "86",
                    )
                }
                if (response.code !in 200..299 || gateway.sessionCookie.isNullOrBlank()) {
                    error(response.failureMessage ?: tr("login.wrong_credentials"))
                }
                finishSignInAndClose(response.profile)
            } catch (error: Throwable) {
                loginError = error.toFriendlyMessage(tr("login.fail_check"))
            } finally {
                isSubmittingLogin = false
            }
        }
    }

    fun submitCookieLogin() {
        val cookie = loginCookie.trim()
        if (cookie.isBlank()) {
            loginError = tr("login.cookie.required")
            return
        }
        scope.launch {
            isSubmittingLogin = true
            loginError = null
            try {
                val response = gateway.loginWithCookie(cookie)
                val profile = response.data?.profile
                val hasAccount = (profile?.userId ?: 0L) > 0L ||
                    (response.data?.account?.id ?: 0L) > 0L
                check(hasAccount) { tr("login.cookie.fail") }
                finishSignInAndClose(profile)
            } catch (error: Throwable) {
                loginError = error.toFriendlyMessage(tr("login.cookie.fail"))
            } finally {
                isSubmittingLogin = false
            }
        }
    }

    fun logout() {
        playlistJob?.cancel()
        playlistRequestGeneration += 1
        scope.launch {
            beginRequest(tr("status.signing_out"))
            try {
                runCatching { gateway.logoutSession() }
            } finally {
                gateway.clearSession()
                currentUser = null
                playlistCache.clearCurrentUser()
                userPlaylists = emptyList()
                likedTracks = emptyList()
                isLiked = false
                activePlaylist = null
                activePlaylistTracks = emptyList()
                runCatching { gateway.anonymousLogin() }
                runCatching { loadPublicLibrary() }
                gateway.clearSession()
                statusMessage = null
                endRequest()
            }
        }
    }

    fun openListenTogether() {
        listenTogetherError = null
        isListenTogetherVisible = true
    }

    fun closeListenTogether() {
        isListenTogetherVisible = false
        listenTogetherError = null
    }

    var isQueuePanelVisible by mutableStateOf(false)
        private set

    /**
     * The room's shared order. A room decides what everyone hears, so while one is open the queue
     * panel reads this list instead of the local one and offers no edits.
     */
    var roomQueue by mutableStateOf<List<TrackItem>>(emptyList())
        private set

    fun openQueuePanel() {
        isQueuePanelVisible = true
    }

    fun closeQueuePanel() {
        isQueuePanelVisible = false
    }

    var isCommentPanelVisible by mutableStateOf(false)
        private set
    var comments by mutableStateOf(DesktopSongCommentState())
        private set

    private var commentJob: Job? = null
    private val commentPages = mutableMapOf<Long, DesktopSongCommentState>()

    /** Paints the cached page first, then asks the service for the same page again. */
    fun openSongComments() {
        val track = nowPlaying ?: return
        if (track.isLocalFile) return
        val songId = track.id
        isCommentPanelVisible = true
        comments = commentPages[songId] ?: DesktopSongCommentState(songId = songId, loading = true)
        requestSongComments(songId, offset = 0, append = false)
    }

    fun closeCommentPanel() {
        isCommentPanelVisible = false
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
                    statusMessage = tr("comment.reply_sent")
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
        patchComment(comment.commentId) {
            it.copy(
                liked = wanted,
                likedCount = (comment.likedCount + if (wanted) 1 else -1).coerceAtLeast(0),
            )
        }
        // Each like patches only its own comment, so they never need to cancel one another.
        scope.launch {
            runCatching { gateway.setSongCommentLiked(songId, comment.commentId, wanted) }.onFailure { error ->
                if (error is CancellationException) throw error
                patchComment(comment.commentId) { it.copy(liked = comment.liked, likedCount = comment.likedCount) }
                statusMessage = tr("comment.like_fail")
            }
        }
    }

    private fun patchComment(commentId: Long, transform: (SongComment) -> SongComment) {
        comments = comments.copy(
            hotComments = comments.hotComments.map { if (it.commentId == commentId) transform(it) else it },
            comments = comments.comments.map { if (it.commentId == commentId) transform(it) else it },
        )
    }

    private fun requestSongComments(songId: Long, offset: Int, append: Boolean) {
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
            val merged = DesktopSongCommentState(
                songId = songId,
                total = page.total,
                hasMore = page.more,
                hotComments = if (offset == 0) page.hotComments else comments.hotComments,
                comments = if (append) comments.comments + page.comments else page.comments,
            )
            commentPages[songId] = merged
            if (comments.songId == songId) comments = merged
        }
    }

    fun createListenTogetherRoom(kind: ListenTogetherRoomKind) {
        if (nowPlaying?.isLocalFile == true) {
            statusMessage = tr("status.local_audio.room_unavailable")
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
                        songId = nowPlaying?.id ?: error("no track to share"),
                        nextSongIds = upcomingRoomTrackIds(),
                        playedTimeMillis = positionMillis,
                    )
                }
                requireListenTogetherSuccess(response)
                val roomId = listenTogetherCreatedRoomId(response) ?: error("room id missing")
                requireListenTogetherSuccess(gateway.listenTogetherRoomCheck(roomId))
                listenTogether = DesktopListenTogetherState(
                    roomId = roomId,
                    inviterId = user.userId,
                    isHost = true,
                )
                resetListenTogetherSession()
                runCatching { reportPlaybackToRoom("GOTO", forceQueue = true) }
                startListenTogetherRefresh()
            }.onFailure { error ->
                if (error is CancellationException) throw error
                listenTogetherError = tr("listen_together.create_fail")
            }
            isListenTogetherBusy = false
        }
    }

    /** Joins from a pasted share link, a copied message, or a bare "roomId inviterId" pair. */
    fun joinListenTogether(invitation: String) {
        if (currentUser == null) {
            openLogin()
            return
        }
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
                listenTogether = DesktopListenTogetherState(
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
            runCatching { requireListenTogetherSuccess(gateway.listenTogetherEnd(roomId)) }
                .onSuccess {
                    clearListenTogetherSession()
                    isListenTogetherVisible = false
                    statusMessage = tr("listen_together.ended")
                }
                .onFailure { error ->
                    if (error is CancellationException) throw error
                    listenTogetherError = tr("listen_together.end_fail")
                }
            isListenTogetherBusy = false
        }
    }

    /**
     * Polls the room for its people, playlist and play command, and keeps the upstream informed of
     * this client's own position so late joiners can catch up.
     */
    private fun startListenTogetherRefresh() {
        listenTogetherRefreshJob?.cancel()
        listenTogetherRefreshJob = scope.launch {
            var missingRoomCount = 0
            while (isActive && listenTogether != null) {
                val room = listenTogether ?: break
                try {
                    val statusResponse = gateway.listenTogetherStatus()
                    if (isListenTogetherClosed(statusResponse)) {
                        closeRoomRemotely()
                        break
                    }
                    requireListenTogetherSuccess(statusResponse)
                    val status = listenTogetherRoomStatus(statusResponse)
                    if (status?.inRoom == false) {
                        missingRoomCount += 1
                        if (missingRoomCount >= 2) {
                            closeRoomRemotely()
                            break
                        }
                    } else {
                        missingRoomCount = 0
                    }
                    val playlistResponse = gateway.listenTogetherPlaylist(room.roomId)
                    if (isListenTogetherClosed(playlistResponse)) {
                        closeRoomRemotely()
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
                        if (remote.trackIds != lastRoomQueueIds) {
                            lastRoomQueueIds = remote.trackIds
                            // Naming the order only needs the rows a member can scroll through. Resolving a
                            // host's whole list would ask for hundreds of detail pages for songs nobody sees.
                            runCatching { loadRoomTracks(remote.trackIds.take(MAX_PLAYLIST_TRACKS)) }
                                .onSuccess { roomQueue = it }
                        }
                    }
                    listenTogether = room.copy(
                        connection = DesktopListenTogetherConnection.CONNECTED,
                        participants = status?.participants ?: room.participants,
                        remoteTrackId = remote?.targetSongId?.takeIf { it > 0L } ?: room.remoteTrackId,
                    )

                    val track = nowPlaying
                    val now = System.currentTimeMillis()
                    if (track != null && now - lastHeartbeatMillis >= LISTEN_TOGETHER_HEARTBEAT_MILLIS) {
                        val heartbeat = gateway.listenTogetherHeartbeat(
                            roomId = room.roomId,
                            songId = track.id,
                            playStatus = if (isPlaying) "PLAY" else "PAUSE",
                            progress = positionMillis,
                        )
                        if (isListenTogetherClosed(heartbeat)) {
                            closeRoomRemotely()
                            break
                        }
                        requireListenTogetherSuccess(heartbeat)
                        lastHeartbeatMillis = now
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Throwable) {
                    listenTogether = room.copy(connection = DesktopListenTogetherConnection.RECONNECTING)
                }
                delay(LISTEN_TOGETHER_REFRESH_MILLIS)
            }
        }
        watchListenTogetherPlayback()
    }

    private fun closeRoomRemotely() {
        clearListenTogetherSession()
        statusMessage = tr("listen_together.closed_remote")
    }

    /** Reports local play state changes the room has to hear about, without echoing remote ones. */
    private fun watchListenTogetherPlayback() {
        listenTogetherWatchJob?.cancel()
        listenTogetherWatchJob = scope.launch {
            while (isActive) {
                val key = DesktopListenTogetherPlaybackKey(nowPlaying?.id, isPlaying)
                val previous = lastStablePlayback
                lastStablePlayback = key
                if (pendingRemotePlayback == key) {
                    pendingRemotePlayback = null
                } else if (listenTogether != null && key.trackId != null && playJob?.isActive != true) {
                    when {
                        previous != null && previous.trackId != key.trackId ->
                            runCatching { reportPlaybackToRoom("GOTO", forceQueue = true) }
                        previous != null && previous.isPlaying != key.isPlaying ->
                            runCatching { reportPlaybackToRoom(if (key.isPlaying) "PLAY" else "PAUSE") }
                    }
                }
                delay(LISTEN_TOGETHER_WATCH_MILLIS)
            }
        }
    }

    private suspend fun reportPlaybackToRoom(commandType: String, forceQueue: Boolean = false) {
        val room = listenTogether ?: return
        val track = nowPlaying ?: return
        if (track.isLocalFile) return
        val queue = effectiveQueue().ifEmpty { listOf(track) }
        val queueIds = queue.map(TrackItem::id).distinct()
        if (forceQueue || queueIds != lastReportedQueueIds) {
            val userId = currentUser?.userId ?: return
            val versions = incrementListenTogetherVersion(listenTogetherVersions, userId)
            requireListenTogetherSuccess(
                gateway.listenTogetherSyncList(
                    roomId = room.roomId,
                    commandType = "REPLACE",
                    versions = versions,
                    playMode = listenTogetherPlaylistState?.playMode ?: "ORDER_LOOP",
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
        requireListenTogetherSuccess(
            gateway.listenTogetherPlayCommand(
                roomId = room.roomId,
                commandType = commandType,
                progress = positionMillis,
                playStatus = if (isPlaying) "PLAY" else "PAUSE",
                formerSongId = listenTogetherPlaylistState?.targetSongId?.takeIf { it > 0L } ?: -1L,
                targetSongId = track.id,
                clientSeq = listenTogetherSequence++,
            ),
        )
    }

    private suspend fun applyRemotePlayback(remote: ListenTogetherPlaybackState) {
        val targetId = remote.targetSongId.takeIf { it > 0L } ?: return
        if (remote.clientSequence <= lastAppliedRemoteSequence) return
        lastAppliedRemoteSequence = remote.clientSequence
        val shouldPlay = remote.playStatus.equals("PLAY", ignoreCase = true)
        val local = nowPlaying
        if (local?.id == targetId && isPlaying == shouldPlay &&
            abs(positionMillis - remote.progressMillis) < LISTEN_TOGETHER_SEEK_TOLERANCE_MILLIS
        ) {
            return
        }
        pendingRemotePlayback = DesktopListenTogetherPlaybackKey(targetId, shouldPlay)
        if (local?.id != targetId) {
            val ids = remote.trackIds.ifEmpty { listOf(targetId) }
            val tracks = loadRoomTracks(ids)
            val target = tracks.firstOrNull { it.id == targetId } ?: return
            playTrackAt(target, remote.progressMillis, shouldPlay)
            return
        }
        if (abs(positionMillis - remote.progressMillis) >= LISTEN_TOGETHER_SEEK_TOLERANCE_MILLIS &&
            remote.commandType.uppercase() in setOf("GOTO", "SEEK")
        ) {
            seekToLyricTime(remote.progressMillis)
        }
        when {
            shouldPlay != isPlaying -> togglePlayPause()
            else -> pendingRemotePlayback = null
        }
    }

    private suspend fun loadRoomTracks(ids: List<Long>): List<TrackItem> {
        val known = (activePlaylistTracks + activeArtistTracks + recentTracks + likedTracks + searchResults)
            .associateBy(TrackItem::id)
            .toMutableMap()
        known[nowPlaying?.id]?.let { known[it.id] = it }
        ids.filterNot(known::containsKey).chunked(200).forEach { missing ->
            gateway.songDetails(missing).songs.map { it.toTrackItem() }.forEach { known[it.id] = it }
        }
        return ids.mapNotNull(known::get).distinctBy(TrackItem::id)
    }

    private fun upcomingRoomTrackIds(): List<Long> {
        val currentId = nowPlaying?.id ?: return emptyList()
        val queue = effectiveQueue()
        val index = queue.indexOfFirst { it.id == currentId }
        if (index < 0) return emptyList()
        return queue.drop(index + 1).filterNot(TrackItem::isLocalFile).map(TrackItem::id).distinct()
    }

    private fun resetListenTogetherSession() {
        listenTogetherSequence = 1L
        listenTogetherPlaylistState = null
        listenTogetherVersions = emptyList()
        roomQueue = emptyList()
        lastRoomQueueIds = emptyList()
        lastReportedQueueIds = emptyList()
        lastAppliedRemoteSequence = -1L
        pendingRemotePlayback = null
        lastStablePlayback = DesktopListenTogetherPlaybackKey(nowPlaying?.id, isPlaying)
        lastHeartbeatMillis = 0L
    }

    private fun clearListenTogetherSession() {
        listenTogetherRefreshJob?.cancel()
        listenTogetherRefreshJob = null
        listenTogetherWatchJob?.cancel()
        listenTogetherWatchJob = null
        listenTogether = null
        resetListenTogetherSession()
    }

    /**
     * Resolves the signed-in profile, closes the login UI immediately, then syncs
     * the library in the background so the sheet never waits on playlist fetches.
     */
    private suspend fun finishSignInAndClose(profileHint: UserProfile? = null) {
        val profile = resolveSignedInProfile(profileHint)
        currentUser = profile
        playlistCache.saveCurrentUser(profile)
        restoreCachedUserLibrary(profile)
        loginPassword = ""
        loginCookie = ""
        loginError = null
        isLoginVisible = false
        qrLoginState = QrLoginState.IDLE
        qrLoginJob?.cancel()

        scope.launch {
            beginRequest(tr("status.syncing_music"))
            try {
                runCatching { syncUserLibrary(profile) }
                    .onSuccess {
                        val syncedMessage = tr("status.synced")
                        statusMessage = syncedMessage
                        delay(1_600)
                        if (statusMessage == syncedMessage) statusMessage = null
                    }
                    .onFailure { statusMessage = tr("status.login_success_sync_later") }
            } finally {
                endRequest()
            }
        }
    }

    private suspend fun resolveSignedInProfile(profileHint: UserProfile? = null): UserProfile {
        val profile = profileHint?.takeIf { it.userId > 0 }
            ?: resolveStoredProfile()
        check(profile != null && profile.userId > 0) { tr("login.no_profile") }
        return profile
    }

    private suspend fun resolveStoredProfile(): UserProfile? {
        val loginStatus = gateway.loginStatus().data
        return loginStatus?.profile?.takeIf { it.userId > 0 }
            ?: loginStatus?.account?.id
                ?.takeIf { it > 0 }
                ?.let { gateway.userDetail(it).profile }
    }

    private suspend fun loadPublicLibrary(forceRefresh: Boolean = false) {
        val playlists = ensurePlaylistCovers(
            gateway.topPlaylists(limit = 12, forceRefresh = forceRefresh).playlists.map { it.toPlaylistItem() },
            forceRefresh = forceRefresh,
        )
        featuredPlaylists = playlists
        playlistCache.savePlaylists(FEATURED_CACHE_KEY, playlists)
        if (recentTracks.isEmpty() && playlists.isNotEmpty()) {
            val tracks = runCatching {
                gateway.playlistTracks(
                    playlists.first().id,
                    limit = 18,
                    forceRefresh = forceRefresh,
                ).songs.map { it.toTrackItem() }
            }.getOrDefault(emptyList())
            recentTracks = tracks
            playlistCache.saveTracks(RECENT_TRACKS_CACHE_ID, tracks, complete = false)
            if (nowPlaying == null) nowPlaying = tracks.firstOrNull()
        }
        if (recentTracks.isEmpty()) {
            val fmTracks = runCatching { gateway.personalFm().data.map { it.toTrackItem() } }
                .getOrDefault(emptyList())
            recentTracks = fmTracks
            playlistCache.saveTracks(RECENT_TRACKS_CACHE_ID, fmTracks, complete = false)
            if (nowPlaying == null) nowPlaying = fmTracks.firstOrNull()
        }
    }

    private suspend fun restoreCachedUserLibrary(profile: UserProfile) {
        val cached = withContext(Dispatchers.IO) {
            DesktopCachedLibrary(
                playlists = playlistCache.loadPlaylists(userPlaylistCacheKey(profile.userId)),
                likedTracks = playlistCache.loadLikedTracks(profile.userId),
            )
        }
        userPlaylists = cached.playlists
        likedTracks = cached.likedTracks
        isLiked = nowPlaying?.let { current -> likedTracks.any { it.id == current.id } } ?: false
    }

    private suspend fun syncUserLibrary(profile: UserProfile, forceRefresh: Boolean = false) {
        val cacheKey = userPlaylistCacheKey(profile.userId)
        val personal = loadAllUserPlaylists(profile.userId, cacheKey, forceRefresh)
        userPlaylists = personal

        // `/recommend/resource` sometimes omits picUrl/coverImgUrl for radar-style lists.
        // Always resolve covers before publishing to the home strip.
        val recommended = runCatching {
            ensurePlaylistCovers(
                gateway.dailyRecommendedPlaylists(forceRefresh).recommend.map { it.toPlaylistItem() },
                forceRefresh,
            )
        }.getOrDefault(emptyList())
        if (recommended.isNotEmpty()) {
            featuredPlaylists = (recommended + featuredPlaylists)
                .distinctBy { it.id }
                .let { ensurePlaylistCovers(it, forceRefresh) }
                .take(12)
            playlistCache.savePlaylists(FEATURED_CACHE_KEY, featuredPlaylists)
        } else if (featuredPlaylists.isEmpty() || featuredPlaylists.all { it.coverUrl.isNullOrBlank() }) {
            loadPublicLibrary(forceRefresh)
        } else {
            featuredPlaylists = ensurePlaylistCovers(featuredPlaylists, forceRefresh)
            playlistCache.savePlaylists(FEATURED_CACHE_KEY, featuredPlaylists)
        }

        // Prefer the private liked playlist order; /song/detail alone does not keep likelist order.
        val liked = personal.firstOrNull { it.isLikedCollection }
        likedTracks = when {
            liked != null -> runCatching {
                gateway.playlistTracks(liked.id, limit = 200, forceRefresh = forceRefresh)
                    .songs.map { it.toTrackItem() }
            }.getOrDefault(likedTracks)
            else -> {
                val likedIds = runCatching { gateway.likedSongIds(profile.userId, forceRefresh).ids.take(200) }
                    .getOrDefault(emptyList())
                if (likedIds.isEmpty()) {
                    emptyList()
                } else {
                    runCatching {
                        val byId = gateway.songDetails(likedIds, forceRefresh).songs.associateBy { it.id }
                        likedIds.mapNotNull { id -> byId[id]?.toTrackItem() }
                    }.getOrDefault(emptyList())
                }
            }
        }
        playlistCache.saveLikedTracks(profile.userId, likedTracks)

        val dailyTracks = runCatching {
            gateway.dailyRecommendedSongs(forceRefresh).data?.dailySongs.orEmpty().map { it.toTrackItem() }
        }
            .getOrDefault(emptyList())
        if (dailyTracks.isNotEmpty()) {
            recentTracks = dailyTracks
            playlistCache.saveTracks(RECENT_TRACKS_CACHE_ID, dailyTracks, complete = false)
            if (nowPlaying == null) nowPlaying = dailyTracks.first()
        } else if (recentTracks.isEmpty() && personal.isNotEmpty()) {
            recentTracks = runCatching {
                gateway.playlistTracks(
                    personal.first().id,
                    limit = 24,
                    forceRefresh = forceRefresh,
                ).songs.map { it.toTrackItem() }
            }.getOrDefault(emptyList())
            playlistCache.saveTracks(RECENT_TRACKS_CACHE_ID, recentTracks, complete = false)
            if (nowPlaying == null) nowPlaying = recentTracks.firstOrNull()
        }
        isLiked = nowPlaying?.let { current -> likedTracks.any { it.id == current.id } } ?: false
    }

    private fun resolveAndPlay(
        track: TrackItem,
        resumeProgress: Float = 0f,
        playWhenReady: Boolean = true,
    ) {
        val playbackRequest = activePlaybackToken.beginRequest()
        playJob?.cancel()
        if (!track.isLocalFile) activeReplayGainResolution = null
        // The selected track may have a different source engine than the track it replaces.
        standardPlayer.stop()
        playJob = scope.launch {
            if (!activePlaybackToken.isCurrent(playbackRequest)) return@launch
            nativePlayer?.let { player ->
                withContext(Dispatchers.IO) {
                    player.stopIfCurrent { activePlaybackToken.isCurrent(playbackRequest) }
                }
            }
            if (!activePlaybackToken.isCurrent(playbackRequest)) return@launch
            stopNetworkRendererPlaybackBeforeLocalPlayback()
            if (track.playbackSource is DesktopTrackSource.LocalFile) {
                beginRequest(tr("status.local_audio.preparing"))
                try {
                    val file = File(track.playbackSource.absolutePath)
                    if (!file.isFile || !file.canRead()) {
                        throw IOException(tr("status.local_audio.file_unavailable"))
                    }
                    val player = nativePlayer ?: throw IOException(tr("status.local_audio.native_required"))
                    val nativeDsdTrack = hifiNativeDsdOutput && isDsdLocalAudioFile(file)
                    if (nativeDsdTrack && volume < 0.999999f) {
                        throw IOException(tr("status.hifi.native_dsd_volume"))
                    }
                    if (nativeDsdTrack && equalizer.enabled) {
                        throw IOException(tr("status.hifi.native_dsd_dsp"))
                    }
                    if (hifiOutputDeviceUnavailable) {
                        throw IOException(tr("status.hifi.device_unavailable"))
                    }
                    val replayGain = resolveDesktopReplayGain(track.replayGain, replayGainMode)
                    activeReplayGainResolution = replayGain.takeIf { replayGainMode != DesktopReplayGainMode.Off }
                    val pcmPlaybackPolicy = resolvePcmPlaybackPolicy(
                        bitPerfectRequested = hifiBitPerfect,
                        exclusiveRequested = exclusiveAudio,
                        processingActive = replayGain.appliedGainDb != 0.0,
                        bufferDurationMillis = hifiBufferMillis,
                    )
                    val effectiveBitPerfect = pcmPlaybackPolicy.toNativePcmBitPerfectFlag() == 1
                    if (effectiveBitPerfect && volume < 0.999999f) {
                        throw IOException(tr("status.hifi.bit_perfect_volume"))
                    }
                    if (nativeDsdTrack && replayGain.appliedGainDb != 0.0) {
                        throw IOException(tr("status.hifi.native_dsd_dsp"))
                    }
                    val safeResumeProgress = playableSeekProgress(resumeProgress, track.durationMillis)
                    progress = safeResumeProgress
                    bufferedProgress = 0f
                    isPlaying = playWhenReady
                    statusMessage = null
                    streamUrl = null
                    hifiStreamInfo = null
                    hifiBitPerfectOpening = effectiveBitPerfect
                    hifiDoPOpening = hifiDoPOutput && isDsdLocalAudioFile(file)
                    hifiNativeDsdOpening = nativeDsdTrack
                    val token = withContext(Dispatchers.IO) {
                        player.playLocalFile(
                            file = file,
                            trackId = track.id,
                            durationMillis = track.durationMillis,
                            fromProgress = safeResumeProgress,
                            volume = volume,
                            replayGainDb = replayGain.appliedGainDb,
                            pcmPlaybackPolicy = pcmPlaybackPolicy,
                            cueStartFrame75 = track.playbackSource.cueStartFrame75,
                            cueEndFrame75 = track.playbackSource.cueEndFrame75,
                            playWhenReady = playWhenReady,
                            onTokenActivated = { activatedToken ->
                                activePlaybackToken.activateIfCurrent(playbackRequest, activatedToken)
                            },
                        )
                    }
                    if (!activePlaybackToken.isActive(playbackRequest, token)) return@launch
                    PlaybackDebugLog.event(
                        "local-playback-start",
                        "token=$token track=${track.id} from=$safeResumeProgress playing=$playWhenReady",
                    )
                    refreshGaplessSuccessor(token, track)
                    publishSystemMedia(forcePosition = true)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    if (!activePlaybackToken.isCurrent(playbackRequest)) return@launch
                    isPlaying = false
                    hifiStreamInfo = null
                    hifiBitPerfectOpening = false
                    hifiDoPOpening = false
                    hifiNativeDsdOpening = false
                    statusMessage = error.toFriendlyMessage(tr("status.play_fail"))
                    publishSystemMedia(
                        statusOverride = SystemMediaPlaybackStatus.STOPPED,
                        forcePosition = true,
                    )
                } finally {
                    endRequest()
                }
                return@launch
            }
            beginRequest(tr("status.preparing_quality", audioQuality.label))
            try {
                val songUrl = resolveSongUrl(track.id, audioQuality)
                if (nowPlaying?.id != track.id) return@launch
                streamUrl = songUrl?.url
                streamBitrate = songUrl?.br
                streamCacheVariant = audioCacheVariant(songUrl?.br, songUrl?.md5, songUrl?.type)
                streamExpectedBytes = songUrl?.size
                val playableUrl = songUrl?.url
                if (playableUrl.isNullOrBlank()) {
                    isPlaying = false
                    statusMessage = tr("status.quality_unavailable")
                    publishSystemMedia(
                        statusOverride = SystemMediaPlaybackStatus.STOPPED,
                        forcePosition = true,
                    )
                } else {
                    val safeResumeProgress = playableSeekProgress(resumeProgress, track.durationMillis)
                    progress = safeResumeProgress
                    isPlaying = playWhenReady
                    statusMessage = null
                    startAudioPlayback(
                        url = playableUrl,
                        track = track,
                        fromProgress = safeResumeProgress,
                        playWhenReady = playWhenReady,
                    )
                    prefetchAdjacentSongUrls()
                    publishSystemMedia(forcePosition = true)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                isPlaying = false
                hifiStreamInfo = null
                hifiBitPerfectOpening = false
                hifiDoPOpening = false
                hifiNativeDsdOpening = false
                statusMessage = error.toFriendlyMessage(tr("status.play_fail"))
                publishSystemMedia(
                    statusOverride = SystemMediaPlaybackStatus.STOPPED,
                    forcePosition = true,
                )
            } finally {
                endRequest()
            }
        }
    }

    private suspend fun resolveSongUrl(trackId: Long, quality: AudioQuality): SongUrl? {
        val key = DesktopStreamCacheKey(trackId, quality)
        val now = System.currentTimeMillis()
        streamUrls[key]?.takeIf { it.expiresAtMillis > now }?.let { return it.songUrl }
        streamUrls.remove(key)

        val songUrl = withContext(Dispatchers.IO) {
            val requested = gateway.songUrls(listOf(trackId), quality = quality).data.firstOrNull()
            if (needsMp3PlaybackFallback(requested?.type, requested?.url)) {
                gateway.songUrls(listOf(trackId), quality = AudioQuality.EXHIGH).data.firstOrNull()
            } else {
                requested
            }
        }
        songUrl?.url?.takeIf(String::isNotBlank)?.let {
            val ttlMillis = (songUrl.expi?.coerceAtLeast(1)?.times(1_000L) ?: STREAM_URL_CACHE_TTL_MILLIS)
                .coerceAtMost(STREAM_URL_CACHE_TTL_MILLIS)
            streamUrls[key] = CachedDesktopSongUrl(songUrl, now + ttlMillis)
        }
        return songUrl
    }

    private fun prefetchAdjacentSongUrls() {
        val preferredQuality = audioQuality
        adjacentQueueTracks().forEach { track ->
            val key = DesktopStreamCacheKey(track.id, preferredQuality)
            val hasFreshUrl = streamUrls[key]?.expiresAtMillis ?: 0L
            if (hasFreshUrl > System.currentTimeMillis() || !streamUrlPrefetches.add(key)) return@forEach
            scope.launch {
                try {
                    resolveSongUrl(track.id, preferredQuality)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Throwable) {
                    // Prefetch is opportunistic: playback will still resolve normally if needed.
                } finally {
                    streamUrlPrefetches.remove(key)
                }
            }
        }
    }

    private fun startAudioPlayback(
        url: String,
        track: TrackItem,
        fromProgress: Float,
        playWhenReady: Boolean,
    ) {
        hifiStreamInfo = null
        hifiBitPerfectOpening = false
        hifiDoPOpening = false
        hifiNativeDsdOpening = false
        if (hifiEngineEnabled && hifiOutputDeviceUnavailable) {
            isPlaying = false
            streamUrl = null
            statusMessage = tr("status.hifi.device_unavailable")
            publishSystemMedia(
                statusOverride = SystemMediaPlaybackStatus.STOPPED,
                forcePosition = true,
            )
            return
        }
        if (hifiEngineEnabled && hifiBitPerfect && volume < 0.999999f) {
            isPlaying = false
            streamUrl = null
            streamBitrate = null
            statusMessage = tr("status.hifi.bit_perfect_volume")
            publishSystemMedia(
                statusOverride = SystemMediaPlaybackStatus.STOPPED,
                forcePosition = true,
            )
            return
        }
        clearHifiOutputRecoveryIntent()
        hifiBitPerfectOpening = hifiEngineEnabled && hifiBitPerfect
        val playbackRequest = activePlaybackToken.beginRequest()
        val token = audioPlayer.play(
            url = url,
            trackId = track.id,
            cacheVariant = streamCacheVariant,
            expectedBytes = streamExpectedBytes,
            durationMillis = track.durationMillis,
            fromProgress = playableSeekProgress(fromProgress, track.durationMillis),
            volume = volume,
            playWhenReady = playWhenReady,
        )
        activePlaybackToken.activateIfCurrent(playbackRequest, token)
        PlaybackDebugLog.event(
            "playback-start",
            "token=$token track=${track.id} from=$fromProgress playing=$playWhenReady",
        )
        refreshGaplessSuccessor(token, track)
    }

    private suspend fun loadCompletePlaylist(
        playlist: PlaylistItem,
        requestGeneration: Long,
    ): List<TrackItem> {
        val expectedCount = playlist.trackCount.coerceAtLeast(0)
        // Beyond the queue cap the extra rows can never be played, so they are not carried: an
        // oversized playlist is loaded as its first MAX tracks and the header keeps the real total.
        val reachable = minOf(expectedCount, MAX_PLAYLIST_TRACKS).takeIf { expectedCount > 0 } ?: MAX_PLAYLIST_TRACKS
        val allAtOnce = try {
            gateway.playlistTracks(
                playlist.id,
                limit = MAX_PLAYLIST_TRACKS,
                forceRefresh = true,
            ).songs.map { it.toTrackItem() }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            emptyList()
        }
        if (!isCurrentPlaylistRequest(playlist.id, requestGeneration)) return emptyList()
        val combined = allAtOnce.distinctBy { it.id }.take(MAX_PLAYLIST_TRACKS).toMutableList()
        if (combined.isNotEmpty()) {
            showPlaylist(playlist, combined)
            val complete = holdsWholePlaylist(expectedCount, combined.size)
            playlistCache.saveTracks(playlist.id, combined, complete)
            if (complete || combined.size >= reachable) return combined
        }

        var offset = combined.size
        while (combined.size < reachable) {
            val page = gateway.playlistTracks(
                id = playlist.id,
                limit = PLAYLIST_PAGE_SIZE,
                offset = offset,
                forceRefresh = true,
            ).songs.map { it.toTrackItem() }
            if (!isCurrentPlaylistRequest(playlist.id, requestGeneration)) return emptyList()
            if (page.isEmpty()) break
            val knownIds = combined.asSequence().map { it.id }.toHashSet()
            combined += page.filterNot { it.id in knownIds }
            while (combined.size > MAX_PLAYLIST_TRACKS) { combined.removeAt(combined.lastIndex) }
            offset += page.size
            showPlaylist(playlist, combined)
            val drained = page.size < PLAYLIST_PAGE_SIZE || combined.size >= reachable
            playlistCache.saveTracks(playlist.id, combined, holdsWholePlaylist(expectedCount, combined.size))
            statusMessage = if (expectedCount > 0) {
                tr("status.loaded_tracks", combined.size.coerceAtMost(expectedCount), expectedCount)
            } else {
                tr("status.loaded_tracks_n", combined.size)
            }
            if (drained) break
        }
        playlistCache.saveTracks(playlist.id, combined, holdsWholePlaylist(expectedCount, combined.size))
        return combined
    }

    /** A declared count of zero means the Gateway never told us the size, so what we hold is all we get. */
    private fun holdsWholePlaylist(expectedCount: Int, held: Int): Boolean =
        expectedCount == 0 || held >= expectedCount

    private fun isCurrentPlaylistRequest(playlistId: Long, requestGeneration: Long): Boolean =
        playlistRequestGeneration == requestGeneration && activePlaylist?.id == playlistId

    private suspend fun loadAllUserPlaylists(
        userId: Long,
        cacheKey: String,
        forceRefresh: Boolean = false,
    ): List<PlaylistItem> {
        val combined = mutableListOf<PlaylistItem>()
        var offset = 0
        do {
            val response = gateway.userPlaylists(
                userId,
                limit = USER_PLAYLIST_PAGE_SIZE,
                offset = offset,
                forceRefresh = forceRefresh,
            )
            val page = response.playlist.map { it.toPlaylistItem() }
            combined += page.filterNot { incoming -> combined.any { it.id == incoming.id } }
            userPlaylists = combined.toList()
            playlistCache.savePlaylists(cacheKey, userPlaylists)
            offset += page.size
        } while (response.more && page.isNotEmpty())
        return combined
    }

    /**
     * Some Gateway playlist payloads only carry a cover on `/playlist/detail`.
     * Fill missing artwork so the home strip never publishes bare gradient tiles when a cover exists.
     */
    private suspend fun ensurePlaylistCovers(
        playlists: List<PlaylistItem>,
        forceRefresh: Boolean = false,
    ): List<PlaylistItem> {
        if (playlists.isEmpty()) return playlists
        return playlists.map { playlist ->
            if (!playlist.coverUrl.isNullOrBlank()) return@map playlist
            val detailCover = runCatching {
                gateway.playlistDetail(playlist.id, forceRefresh = forceRefresh).playlist?.resolvedCoverUrl()
            }.getOrNull()?.takeIf { it.isNotBlank() }
            if (detailCover == null) playlist else playlist.copy(coverUrl = detailCover)
        }
    }

    private fun showPlaylist(playlist: PlaylistItem, tracks: List<TrackItem>) {
        val held = tracks.size
        // A list that stopped at the carry cap is a prefix, so the header keeps the declared total
        // instead of reporting the truncated length as the size of the playlist.
        val trackCount = when {
            held == 0 -> playlist.trackCount
            held >= MAX_PLAYLIST_TRACKS -> maxOf(held, playlist.trackCount)
            else -> held
        }
        activePlaylist = playlist.copy(trackCount = trackCount)
        activePlaylistTracks = tracks
        if (nowPlaying == null) nowPlaying = tracks.firstOrNull()
        isLiked = nowPlaying?.let { current -> likedTracks.any { it.id == current.id } } ?: false
    }

    private var localQueueTracks by mutableStateOf<List<TrackItem>>(emptyList())

    private fun baseQueue(): List<TrackItem> = when {
        localQueueTracks.isNotEmpty() -> localQueueTracks
        activeArtist != null && activeArtistTracks.isNotEmpty() -> activeArtistTracks
        activePlaylist != null && activePlaylistTracks.isNotEmpty() -> activePlaylistTracks
        searchResults.isNotEmpty() -> searchResults
        recentTracks.isNotEmpty() -> recentTracks
        else -> listOfNotNull(nowPlaying)
    }

    /**
     * The order the listener arranged, in full. Shuffle is decided per advance rather than by
     * rewriting this list, so turning shuffle off returns the queue to exactly the order it had.
     */
    private fun effectiveQueue(): List<TrackItem> {
        val base = baseQueue()
        return queueEdit?.takeIf { it.base === base }?.order ?: base
    }

    private fun adjacentQueueTracks(): List<TrackItem> {
        val queue = effectiveQueue()
        if (queue.size < 2) return emptyList()
        val index = queue.indexOfFirst { it.id == nowPlaying?.id }.let { if (it < 0) 0 else it }
        return listOf(
            queue[(index + 1) % queue.size],
            queue[(index - 1 + queue.size) % queue.size],
        ).distinctBy(TrackItem::id)
    }

    private fun publishSystemMedia(
        statusOverride: SystemMediaPlaybackStatus? = null,
        forcePosition: Boolean = false,
    ) {
        val track = nowPlaying
        val status = statusOverride ?: when {
            track == null -> SystemMediaPlaybackStatus.STOPPED
            isPlaying -> SystemMediaPlaybackStatus.PLAYING
            streamUrl.isNullOrBlank() && track.isLocalFile -> SystemMediaPlaybackStatus.PAUSED
            streamUrl.isNullOrBlank() -> SystemMediaPlaybackStatus.STOPPED
            else -> SystemMediaPlaybackStatus.PAUSED
        }
        systemMediaSession.publish(
            snapshot = SystemMediaSnapshot(
                trackId = track?.id,
                title = track?.title,
                artist = track?.artist,
                album = track?.album,
                coverUrl = track?.coverUrl,
                durationMillis = track?.durationMillis ?: 0L,
                playbackStatus = status,
                positionMillis = positionMillis,
            ),
            forcePosition = forcePosition,
        )
    }

    private fun beginRequest(message: String? = null) {
        activeRequests += 1
        isLoading = true
        if (message != null) statusMessage = message
    }

    private fun endRequest() {
        activeRequests = (activeRequests - 1).coerceAtLeast(0)
        isLoading = activeRequests > 0
    }

    private companion object {
        const val STREAM_URL_CACHE_SIZE = 6
        const val STREAM_URL_CACHE_TTL_MILLIS = 4 * 60_000L
        const val PLAYLIST_PAGE_SIZE = 500
        const val MAX_PLAYLIST_TRACKS = LazerPlaybackQueue.MAX_TRACKS
        const val USER_PLAYLIST_PAGE_SIZE = 100
        const val FEATURED_CACHE_KEY = "featured"
        const val RECENT_TRACKS_CACHE_ID = -1L
        const val LIKED_FALLBACK_PLAYLIST_ID = -5L

        fun userPlaylistCacheKey(userId: Long): String = "user-$userId"
    }
}

private fun createDesktopGateway(): NeteaseMusicGateway =
    NeteaseMusicGateway(
        sessionStore = DesktopGatewaySessionStore(),
    )

private fun Song.toTrackItem(): TrackItem = TrackItem(
    id = id,
    title = name.ifBlank { tr("track.unknown_song") },
    artist = artists.joinToString(" / ") { it.name }.ifBlank { tr("track.unknown_artist") },
    album = album?.name.orEmpty().ifBlank { tr("track.unknown_album") },
    durationMillis = durationMillis ?: 0L,
    coverUrl = album?.picUrl ?: album?.blurPictureUrl,
    artists = artists.filter { it.id > 0L && it.name.isNotBlank() },
    translatedTitle = translations
        .map(String::trim)
        .filter { it.isNotBlank() && it != name }
        .distinct()
        .joinToString(" / ")
        .takeIf(String::isNotBlank),
)

private fun Playlist.toPlaylistItem(): PlaylistItem {
    val creatorName = creator?.nickname?.takeIf { it.isNotBlank() }
    val liked = specialType == LIKED_SPECIAL_TYPE || name.endsWith("喜欢的音乐")
    return PlaylistItem(
        id = id,
        title = name.ifBlank { tr("playlist.unnamed") },
        subtitle = buildString {
            trackCount?.let { count -> append(tr("playlist.tracks", count)) }
            if (creatorName != null) {
                if (isNotEmpty()) append(" · ")
                append(creatorName)
            }
            if (isEmpty()) append(description?.take(24) ?: tr("playlist.curated"))
        },
        coverUrl = resolvedCoverUrl(),
        trackCount = trackCount ?: 0,
        creatorName = creatorName,
        isLikedCollection = liked,
    )
}

private const val LIKED_SPECIAL_TYPE = 5

/** Prefer non-blank cover fields; empty strings must not mask `picUrl`. */
private fun Playlist.resolvedCoverUrl(): String? =
    sequenceOf(coverImgUrl, picUrl)
        .mapNotNull { it?.trim()?.takeIf(String::isNotBlank) }
        .firstOrNull()

private fun Throwable.toFriendlyMessage(fallback: String): String =
    if (LazerI18n.language == LazerLanguage.SIMPLIFIED_CHINESE) {
        message?.takeIf { it.isNotBlank() && it.length <= 120 } ?: fallback
    } else {
        fallback
    }

internal fun formatDuration(millis: Long): String {
    if (millis <= 0L) return "00:00"
    val totalSeconds = (millis / 1000.0).roundToInt()
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return "%02d:%02d".format(minutes, seconds)
}

/** Keep lyric jumps inside the playable range even when an LRC tail exceeds track metadata. */
internal fun lyricSeekProgress(timeMillis: Long, durationMillis: Long): Float {
    if (durationMillis <= 0L) return 0f
    val requested = timeMillis.coerceAtLeast(0L).toDouble() / durationMillis.toDouble()
    return playableSeekProgress(requested.toFloat(), durationMillis)
}

internal fun shouldPublishDesktopUiUpdate(
    nowNanos: Long,
    lastUpdateNanos: Long,
    foreground: Boolean,
    value: Float,
): Boolean {
    if (lastUpdateNanos == 0L || value >= 1f) return true
    val interval = if (foreground) FOREGROUND_UI_UPDATE_NANOS else BACKGROUND_UI_UPDATE_NANOS
    return nowNanos < lastUpdateNanos || nowNanos - lastUpdateNanos >= interval
}

private const val FOREGROUND_UI_UPDATE_NANOS = 33_000_000L
private const val BACKGROUND_UI_UPDATE_NANOS = 1_000_000_000L

/** Stable cache variant: the content hash wins, with bitrate/type as a safe fallback. */
internal fun audioCacheVariant(bitrate: Int?, md5: String?, mediaType: String?): String {
    val hash = md5.orEmpty().trim().lowercase()
    return if (hash.isNotEmpty()) hash else "${bitrate ?: 0}-${mediaType.orEmpty().lowercase().ifBlank { "audio" }}"
}
