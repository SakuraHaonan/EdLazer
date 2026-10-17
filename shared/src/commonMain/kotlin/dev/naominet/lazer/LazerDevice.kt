package dev.naominet.lazer

import androidx.compose.ui.graphics.ImageBitmap
import dev.naominet.lazer.gateway.GatewaySessionStore
import dev.naominet.lazer.gateway.NeteaseMusicGateway
import dev.naominet.lazer.gateway.model.UserProfile
import kotlinx.coroutines.flow.StateFlow

/**
 * Restored metadata and complete track lists, so a screen shows what the listener saw last time
 * before the network answers. Both platforms keep the same entries under the same names.
 */
interface LazerLibraryCache {
    fun loadFeaturedPlaylists(): List<LazerPlaylist>

    fun saveFeaturedPlaylists(playlists: List<LazerPlaylist>)

    fun loadCurrentUser(): UserProfile?

    fun saveCurrentUser(profile: UserProfile)

    fun clearCurrentUser()

    fun loadUserPlaylists(userId: Long): List<LazerPlaylist>

    fun saveUserPlaylists(userId: Long, playlists: List<LazerPlaylist>)

    fun loadLikedSongIds(userId: Long): Set<Long>

    fun saveLikedSongIds(userId: Long, songIds: Set<Long>)

    fun loadTracks(playlistId: Long): List<LazerTrack>

    /** Already-decoded data only, so a click handler never waits on disk or JSON. */
    fun peekTracks(playlistId: Long): List<LazerTrack>?

    fun saveTracks(playlistId: Long, tracks: List<LazerTrack>)

    /** Drops playlist and track data while keeping the cached signed-in identity. Returns the count. */
    fun clearPlaylistData(): Int

    fun close()
}

/**
 * The audio the platform actually plays. Everything above this interface - the queue, the snapshot,
 * what a tap on a row does - is shared, so the player behaves the same everywhere and only the
 * output differs.
 */
interface LazerPlayer {
    val snapshot: StateFlow<LazerPlaybackSnapshot>
    val queue: StateFlow<LazerPlaybackQueueSnapshot>

    fun currentQueue(): List<LazerTrack>

    fun play(
        queue: List<LazerTrack>,
        track: LazerTrack,
        startPlaying: Boolean = true,
        positionMillis: Long = 0L,
    )

    fun playAt(position: Int)

    fun removeAt(position: Int)

    fun moveTrack(from: Int, to: Int)

    fun setPlayMode(mode: LazerPlayMode)

    fun toggle()

    fun resume()

    fun pause()

    fun next()

    fun previous()

    fun seekTo(positionMillis: Long)

    /** Whether the system may interrupt other audio while this is playing. */
    fun updateExclusiveAudio(exclusive: Boolean)

    /** Whether the platform's own transport surfaces should own playback. */
    fun updatePlaybackInterface(systemMedia: Boolean)

    /** Whether the platform should keep feeding the app the captured spectrum. */
    fun updateAudioLevels(enabled: Boolean)

    /**
     * Applies the listener's equalizer to the output. Platforms whose engine has no DSP inherit the
     * no-op default, which keeps the preference harmless there instead of an unsupported call.
     */
    fun updateEqualizer(state: LazerEqualizerState) {
    }

    /** Applies local-track loudness normalization where the platform has an app-owned PCM path. */
    fun updateReplayGainMode(mode: LazerReplayGainMode) {
    }

    fun stopAndClearSession()
}

/**
 * The file, cache and diagnostics work the shared state layer cannot do itself. Everything here is
 * decided by the platform's storage rules; the listener never sees it, so the screens stay identical.
 */
interface LazerPlatformHost {
    /** Decodes an image the platform can read from disk, or null when it no longer exists. */
    fun decodeImageFile(path: String): ImageBitmap?

    /** Copies a picked image into app storage so it survives the picker going away. */
    fun importImageFile(source: String, name: String): String?

    fun deleteImportedImage(path: String)

    fun deleteExportedFile(target: String)

    /** Copies a remote file to [target]; the platform decides whether both steps can be one job. */
    suspend fun saveRemoteFile(url: String, target: String): Boolean

    /** Fetches a cover at full size so the listener can keep it outside the app. */
    suspend fun downloadFile(url: String): ByteArray?

    /** Turns encoded image bytes into something the screens can draw. */
    fun decodeImageBytes(bytes: ByteArray): ImageBitmap?

    /**
     * Renders [content] as a square QR image, or null when the platform cannot. The Gateway
     * synthesizes the scan URL locally and has no encoder of its own, so the sign-in screen asks
     * the platform for the picture instead of expecting a base64 one from the service.
     */
    fun encodeQrCode(content: String, size: Int): ByteArray? = null

    /** Drops the platform's own downloaded media cache. Returns how many files went away. */
    fun clearPlatformCache(): Int

    /** Hands the loaded lyric lines to whatever lyric surface the platform owns. */
    fun publishLyrics(trackId: Long, lines: List<TimedLyricLine>)

    /**
     * What the exclusive-audio switch starts at for someone who never opens the settings. iOS ducks
     * other audio rather than being handed it back, so a player that intends to be the music takes it
     * by default; platforms that arbitrate focus through the system keep the sharing default.
     */
    val defaultsToExclusiveAudio: Boolean get() = false

    fun log(message: String, error: Throwable)
}

/** Everything a platform contributes to the shared app, in one object the UI is handed. */
class LazerDevice(
    val preferences: LazerPreferences,
    val sessionStore: GatewaySessionStore,
    val cache: LazerLibraryCache,
    val player: LazerPlayer,
    val host: LazerPlatformHost,
    /** A platform that plays through its own client builds the Gateway here so both share it. */
    val gateway: NeteaseMusicGateway? = null,
) {
    val settings: LazerSettingsStore = LazerSettingsStore(
        preferences,
        defaultsExclusiveAudio = host.defaultsToExclusiveAudio,
    )
}
