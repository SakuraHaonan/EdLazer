package dev.naominet.lazer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import dev.naominet.lazer.gateway.model.UserProfile
import kotlinx.coroutines.flow.StateFlow
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URL

// Android's answers to the seams the shared app is written against. The cache and the media session
// stay here because they are Android's own; everything above them is the shared code iOS reuses.

/** Restores playlists, tracks and the signed-in identity from Android's shared preferences. */
class AndroidLibraryCache(context: Context) : LazerLibraryCache {
    private val delegate = AndroidPlaylistCache(context)

    override fun loadFeaturedPlaylists(): List<LazerPlaylist> = delegate.loadFeaturedPlaylists()

    override fun saveFeaturedPlaylists(playlists: List<LazerPlaylist>) =
        delegate.saveFeaturedPlaylists(playlists)

    override fun loadCurrentUser(): UserProfile? = delegate.loadCurrentUser()

    override fun saveCurrentUser(profile: UserProfile) = delegate.saveCurrentUser(profile)

    override fun clearCurrentUser() = delegate.clearCurrentUser()

    override fun loadUserPlaylists(userId: Long): List<LazerPlaylist> =
        delegate.loadUserPlaylists(userId)

    override fun saveUserPlaylists(userId: Long, playlists: List<LazerPlaylist>) =
        delegate.saveUserPlaylists(userId, playlists)

    override fun loadLikedSongIds(userId: Long): Set<Long> = delegate.loadLikedSongIds(userId)

    override fun saveLikedSongIds(userId: Long, songIds: Set<Long>) =
        delegate.saveLikedSongIds(userId, songIds)

    override fun loadTracks(playlistId: Long): List<LazerTrack> = delegate.loadTracks(playlistId)

    override fun peekTracks(playlistId: Long): List<LazerTrack>? = delegate.peekTracks(playlistId)

    override fun saveTracks(playlistId: Long, tracks: List<LazerTrack>) =
        delegate.saveTracks(playlistId, tracks)

    override fun clearPlaylistData(): Int = delegate.clearPlaylistData()

    override fun close() = delegate.close()
}

/** Drives the foreground media session the way the Compose controls and the notification do today. */
class AndroidPlayer(private val context: Context) : LazerPlayer {
    override val snapshot: StateFlow<LazerPlaybackSnapshot> = AndroidPlaybackConnection.snapshot
    override val queue: StateFlow<LazerPlaybackQueueSnapshot> = AndroidPlaybackConnection.queue

    override fun currentQueue(): List<LazerTrack> = AndroidPlaybackConnection.currentQueue()

    override fun play(
        queue: List<LazerTrack>,
        track: LazerTrack,
        startPlaying: Boolean,
        positionMillis: Long,
    ) = AndroidPlaybackConnection.play(context, queue, track, startPlaying, positionMillis)

    override fun playAt(position: Int) = AndroidPlaybackConnection.playAt(context, position)

    override fun removeAt(position: Int) = AndroidPlaybackConnection.removeAt(context, position)

    override fun moveTrack(from: Int, to: Int) = AndroidPlaybackConnection.moveTrack(context, from, to)

    override fun setPlayMode(mode: LazerPlayMode) = AndroidPlaybackConnection.setPlayMode(context, mode)

    override fun toggle() = AndroidPlaybackConnection.toggle(context)

    override fun resume() = AndroidPlaybackConnection.resume(context)

    override fun pause() = AndroidPlaybackConnection.pause(context)

    override fun next() = AndroidPlaybackConnection.next(context)

    override fun previous() = AndroidPlaybackConnection.previous(context)

    override fun seekTo(positionMillis: Long) = AndroidPlaybackConnection.seekTo(context, positionMillis)

    override fun updateExclusiveAudio(exclusive: Boolean) =
        AndroidPlaybackConnection.updateExclusiveAudio(context)

    override fun updatePlaybackInterface(systemMedia: Boolean) =
        AndroidPlaybackConnection.updatePlaybackInterface(context)

    override fun updateAudioLevels(enabled: Boolean) = AndroidPlaybackConnection.updateAudioLevels(context)

    override fun updateEqualizer(state: LazerEqualizerState) =
        AndroidPlaybackConnection.updateEqualizer(context, state)

    override fun updateReplayGainMode(mode: LazerReplayGainMode) =
        AndroidPlaybackConnection.updateReplayGainMode(context, mode)

    override fun stopAndClearSession() = AndroidPlaybackConnection.stopAndClearSession(context)
}

/** Storage, export and diagnostics the shared state layer cannot reach by itself. */
class AndroidHost(private val context: Context) : LazerPlatformHost {
    override fun decodeImageFile(path: String): ImageBitmap? =
        BitmapFactory.decodeFile(path)?.asImageBitmap()

    override fun decodeImageBytes(bytes: ByteArray): ImageBitmap? =
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()

    override fun encodeQrCode(content: String, size: Int): ByteArray? = runCatching {
        val matrix = QRCodeWriter().encode(
            content,
            BarcodeFormat.QR_CODE,
            size,
            size,
            mapOf(EncodeHintType.MARGIN to 2),
        )
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        for (y in 0 until size) {
            for (x in 0 until size) {
                bitmap.setPixel(x, y, if (matrix[x, y]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt())
            }
        }
        ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            output.toByteArray()
        }
    }.getOrNull()

    override fun importImageFile(source: String, name: String): String? {
        val target = File(context.filesDir, name)
        context.contentResolver.openInputStream(Uri.parse(source))?.use { input ->
            target.outputStream().use(input::copyTo)
        } ?: return null
        return target.absolutePath
    }

    override fun deleteImportedImage(path: String) {
        File(path).delete()
    }

    override suspend fun saveRemoteFile(url: String, target: String): Boolean {
        val bytes = downloadFile(url) ?: return false
        return context.contentResolver.openOutputStream(Uri.parse(target), "w")?.use { output ->
            output.write(bytes)
            true
        } ?: false
    }

    override fun deleteExportedFile(target: String) {
        runCatching { context.contentResolver.delete(Uri.parse(target), null, null) }
    }

    override suspend fun downloadFile(url: String): ByteArray? {
        val connection = URL(url).openConnection().apply {
            connectTimeout = 12_000
            readTimeout = 20_000
            setRequestProperty("User-Agent", "Lazer/1.2")
        }
        return connection.getInputStream().use { it.readBytes() }
    }

    override fun clearPlatformCache(): Int =
        context.cacheDir.listFiles().orEmpty().count { it.deleteRecursively() }

    override fun publishLyrics(trackId: Long, lines: List<TimedLyricLine>) {
        SuperLyricPublisher.updateLyrics(trackId, lines)
    }

    override fun log(message: String, error: Throwable) {
        Log.w("LazerGatewayController", message, error)
    }
}

/** The Android answer to every seam the shared app is written against. */
fun androidDevice(context: Context): LazerDevice {
    val appContext = context.applicationContext
    return LazerDevice(
        preferences = androidPreferences(appContext),
        sessionStore = AndroidGatewaySessionStore(appContext),
        cache = AndroidLibraryCache(appContext),
        player = AndroidPlayer(appContext),
        host = AndroidHost(appContext),
    )
}

/** The screens and service still name these the way they always have. */
typealias AndroidGatewayController = LazerGatewayController

typealias AndroidRootDestination = LazerRootDestination

typealias AndroidLoginMethod = LazerLoginMethod

typealias AndroidListenTogetherState = LazerListenTogetherState

typealias AndroidSongCommentState = LazerSongCommentState

typealias AndroidListenTogetherConnection = LazerListenTogetherConnection

typealias AndroidQrLoginState = LazerQrLoginState

internal fun AndroidGatewayController(context: Context): LazerGatewayController =
    LazerGatewayController(androidDevice(context))

internal fun nextAndroidLibraryTipIndex(current: Int): Int = nextLazerLibraryTipIndex(current)
