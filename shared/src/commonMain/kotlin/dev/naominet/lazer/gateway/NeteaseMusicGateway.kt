package dev.naominet.lazer.gateway

import dev.naominet.lazer.tr
import dev.naominet.lazer.gateway.model.AlbumDetailResponse
import dev.naominet.lazer.gateway.model.ArtistDetailResponse
import dev.naominet.lazer.gateway.model.BannerResponse
import dev.naominet.lazer.gateway.model.DailyPlaylistsResponse
import dev.naominet.lazer.gateway.model.DailySongsResponse
import dev.naominet.lazer.gateway.model.LikedSongIdsResponse
import dev.naominet.lazer.gateway.model.ListenTogetherPlaylistVersion
import dev.naominet.lazer.gateway.model.LoginResponse
import dev.naominet.lazer.gateway.model.LoginStatusResponse
import dev.naominet.lazer.gateway.model.LyricResponse
import dev.naominet.lazer.gateway.model.MusicAvailabilityResponse
import dev.naominet.lazer.gateway.model.PersonalFmResponse
import dev.naominet.lazer.gateway.model.PlaylistDetailResponse
import dev.naominet.lazer.gateway.model.PlaylistTracksResponse
import dev.naominet.lazer.gateway.model.QrCheckResponse
import dev.naominet.lazer.gateway.model.QrCodeResponse
import dev.naominet.lazer.gateway.model.QrKeyResponse
import dev.naominet.lazer.gateway.model.SearchResponse
import dev.naominet.lazer.gateway.model.SongCommentResponse
import dev.naominet.lazer.gateway.model.SongDetailResponse
import dev.naominet.lazer.gateway.model.SongUrlResponse
import dev.naominet.lazer.gateway.model.TopPlaylistsResponse
import dev.naominet.lazer.gateway.model.UserDetailResponse
import dev.naominet.lazer.gateway.model.UserPlaylistsResponse
import io.ktor.client.HttpClient
import io.ktor.client.request.accept
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.util.date.getTimeMillis
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Search types supported by `/search` and `/cloudsearch`. */
enum class SearchType(internal val apiValue: Int) {
    SONG(1),
    ALBUM(10),
    ARTIST(100),
    PLAYLIST(1000),
    USER(1002),
    MUSIC_VIDEO(1004),
    LYRIC(1006),
    RADIO(1009),
    VIDEO(1014),
    COMPREHENSIVE(1018),
    VOICE(2000),
}

/** Playback qualities accepted by `/song/url/v1`. */
enum class AudioQuality(
    internal val apiValue: String,
    private val labelKey: String,
    private val descriptionKey: String,
) {
    STANDARD("standard", "quality.standard", "quality.standard.desc"),
    HIGHER("higher", "quality.higher", "quality.higher.desc"),
    EXHIGH("exhigh", "quality.exhigh", "quality.exhigh.desc"),
    LOSSLESS("lossless", "quality.lossless", "quality.lossless.desc"),
    HI_RES("hires", "quality.hires", "quality.hires.desc"),
    JYEFFECT("jyeffect", "quality.jyeffect", "quality.jyeffect.desc"),
    SKY("sky", "quality.sky", "quality.sky.desc"),
    DOLBY("dolby", "quality.dolby", "quality.dolby.desc"),
    JYMASTER("jymaster", "quality.jymaster", "quality.jymaster.desc");

    val label: String get() = tr(labelKey)
    val description: String get() = tr(descriptionKey)
}

/** Platform values accepted by `/banner`. */
enum class BannerPlatform(internal val apiValue: Int) {
    DESKTOP(0),
    ANDROID(1),
    IPHONE(2),
    IPAD(3),
}

/** The upstream caps a comment body at this length; the UI uses it for its own counter. */
const val SONG_COMMENT_CONTENT_LIMIT = 500

/**
 * A Kotlin Multiplatform Wrapper around NeteaseCloudMusicApi Enhanced Gateway.
 *
 * Every documented route remains available via [getRaw] and [postRaw]. The typed methods cover
 * login plus the discovery, library, and playback paths a player needs first.
 */
class NeteaseMusicGateway(
    val config: GatewayConfig = GatewayConfig(),
    val sessionStore: GatewaySessionStore = InMemoryGatewaySessionStore(),
    private val httpClient: HttpClient = createLazerHttpClient(config),
    private val closeHttpClient: Boolean = true,
    private val nowMillis: () -> Long = { getTimeMillis() },
) {
    /** The current raw Gateway session cookie, if the user has logged in. */
    val sessionCookie: String?
        get() {
            val stored = sessionStore.cookie
            val normalized = normalizeGatewaySessionCookie(stored)
            if (stored != normalized) sessionStore.cookie = normalized
            return normalized
        }

    /** Removes the locally held session cookie without making a network request. */
    fun clearSession() {
        sessionStore.cookie = null
    }

    /**
     * Installs a user-supplied Gateway cookie and verifies it against the documented login-status
     * route. An invalid cookie never replaces the session that was active before this call.
     */
    suspend fun loginWithCookie(cookie: String): LoginStatusResponse {
        val candidate = requireNotNull(normalizeGatewaySessionCookie(cookie)) {
            "cookie does not contain any valid cookie fields."
        }

        val previousCookie = sessionCookie
        sessionStore.cookie = candidate
        return try {
            loginStatus().also { response ->
                val profileId = response.data?.profile?.userId ?: 0L
                val accountId = response.data?.account?.id ?: 0L
                if (profileId <= 0L && accountId <= 0L) {
                    sessionStore.cookie = previousCookie
                }
            }
        } catch (error: Throwable) {
            sessionStore.cookie = previousCookie
            throw error
        }
    }

    /** Closes the owned HTTP client. Injected clients can opt out via `closeHttpClient = false`. */
    fun close() {
        if (closeHttpClient) {
            httpClient.close()
        }
    }

    /**
     * Calls any GET route exposed by the Gateway. Supply query parameters separately so they are
     * encoded correctly and a caller cannot accidentally replace the configured host.
     */
    suspend fun getRaw(
        path: String,
        parameters: Map<String, String> = emptyMap(),
    ): JsonElement = requestJson(HttpMethod.Get, path, parameters)

    /**
     * Calls any POST route exposed by the Gateway. A timestamp is included in the URL because
     * the Gateway documentation requires a unique POST URL to avoid its two-minute cache.
     */
    suspend fun postRaw(
        path: String,
        parameters: Map<String, String> = emptyMap(),
    ): JsonElement = requestJson(HttpMethod.Post, path, parameters)

    suspend inline fun <reified T> get(
        path: String,
        parameters: Map<String, String> = emptyMap(),
    ): T = gatewayJson.decodeFromJsonElement(getRaw(path, parameters))

    suspend inline fun <reified T> post(
        path: String,
        parameters: Map<String, String> = emptyMap(),
    ): T = gatewayJson.decodeFromJsonElement(postRaw(path, parameters))

    suspend fun anonymousLogin(): LoginResponse = rememberCookie(
        post<LoginResponse>("/register/anonimous"),
    )

    suspend fun loginWithPhonePassword(
        phone: String,
        password: String,
        countryCode: String? = null,
        sliderToken: String? = null,
    ): LoginResponse {
        require(phone.isNotBlank()) { "phone cannot be blank." }
        require(password.isNotBlank()) { "password cannot be blank." }
        return rememberCookie(
            post<LoginResponse>(
                "/login/cellphone",
                parametersOf(
                    "phone" to phone,
                    "password" to password,
                    "countrycode" to countryCode,
                    "sca" to sliderToken,
                ),
            ),
        )
    }

    suspend fun loginWithPhoneCaptcha(
        phone: String,
        captcha: String,
        countryCode: String = "86",
    ): LoginResponse {
        require(phone.isNotBlank()) { "phone cannot be blank." }
        require(captcha.isNotBlank()) { "captcha cannot be blank." }
        return rememberCookie(
            post<LoginResponse>(
                "/login/cellphone",
                parametersOf(
                    "phone" to phone,
                    "captcha" to captcha,
                    "countrycode" to countryCode,
                ),
            ),
        )
    }

    suspend fun loginWithEmail(email: String, password: String): LoginResponse {
        require(email.isNotBlank()) { "email cannot be blank." }
        require(password.isNotBlank()) { "password cannot be blank." }
        return rememberCookie(
            post<LoginResponse>("/login", parametersOf("email" to email, "password" to password)),
        )
    }

    /**
     * Mints a scan key. The QR the official desktop client renders is
     * `https://music.163.com/login?codekey=<unikey>` — no platform, trace or chain parameter.
     */
    suspend fun createQrKey(): QrKeyResponse = post("/login/qr/key")

    /** Synthesized locally from the key; the URL shape matches the desktop client exactly. */
    suspend fun createQrCode(key: String, includeImage: Boolean = true): QrCodeResponse {
        require(key.isNotBlank()) { "key cannot be blank." }
        return post("/login/qr/create", parametersOf("key" to key, "qrimg" to includeImage))
    }

    /**
     * Polls the scan key. [secureCaptcha] carries the Yidun token once the service answers 8821,
     * exactly like the desktop client's `checkQRCodeLogin`.
     */
    suspend fun checkQrCode(key: String, secureCaptcha: String = ""): QrCheckResponse {
        require(key.isNotBlank()) { "key cannot be blank." }
        return rememberCookie(
            post<QrCheckResponse>(
                "/login/qr/check",
                parametersOf("key" to key, "secureCaptcha" to secureCaptcha),
            ),
        )
    }

    suspend fun refreshLogin(): LoginResponse = rememberCookie(post<LoginResponse>("/login/refresh"))

    /**
     * Uses POST so the request receives a cache-busting timestamp. The Gateway caches identical
     * GET URLs for two minutes, which can otherwise return a pre-login status immediately after a
     * QR login has supplied a new cookie.
     */
    suspend fun loginStatus(): LoginStatusResponse = post("/login/status")

    suspend fun userDetail(uid: Long): UserDetailResponse {
        require(uid > 0) { "uid must be positive." }
        return post("/user/detail", parametersOf("uid" to uid))
    }

    /** Song comments are readable without a session; `more` reports whether another page exists. */
    suspend fun songComments(songId: Long, limit: Int = 20, offset: Int = 0): SongCommentResponse {
        require(songId > 0) { "songId must be positive." }
        return post(
            "/comment/music",
            parametersOf(
                "id" to songId,
                "limit" to limit.coerceIn(1, 100),
                "offset" to offset.coerceAtLeast(0),
            ),
        )
    }

    /** Liking and replying both need the session the comment reader does not. */
    suspend fun setSongCommentLiked(songId: Long, commentId: Long, liked: Boolean) {
        require(songId > 0 && commentId > 0) { "songId and commentId must be positive." }
        requireCommentSuccess(
            postRaw(
                if (liked) "/comment/like" else "/comment/unlike",
                parametersOf("id" to songId, "commentId" to commentId),
            ).jsonObject,
        )
    }

    suspend fun replyToSongComment(songId: Long, commentId: Long, content: String) {
        require(songId > 0 && commentId > 0) { "songId and commentId must be positive." }
        require(content.isNotBlank()) { "content must not be blank." }
        requireCommentSuccess(
            postRaw(
                "/comment/reply",
                parametersOf(
                    "id" to songId,
                    "commentId" to commentId,
                    "content" to content.trim().take(SONG_COMMENT_CONTENT_LIMIT),
                ),
            ).jsonObject,
        )
    }

    suspend fun logout(): JsonObject {
        val response = postRaw("/logout").jsonObject
        clearSession()
        return response
    }

    /** Logs out without exposing the transport JSON type to UI modules. */
    suspend fun logoutSession() {
        logout()
    }

    suspend fun sendCaptcha(phone: String, countryCode: String = "86"): JsonObject {
        require(phone.isNotBlank()) { "phone cannot be blank." }
        return postRaw("/captcha/sent/v1", parametersOf("phone" to phone, "ctcode" to countryCode)).jsonObject
    }

    suspend fun search(
        keywords: String,
        type: SearchType = SearchType.SONG,
        limit: Int = 30,
        offset: Int = 0,
        useCloudSearch: Boolean = false,
    ): SearchResponse {
        require(keywords.isNotBlank()) { "keywords cannot be blank." }
        require(limit > 0) { "limit must be greater than zero." }
        require(offset >= 0) { "offset cannot be negative." }
        return get(
            if (useCloudSearch) "/cloudsearch" else "/search",
            parametersOf(
                "keywords" to keywords,
                "type" to type.apiValue,
                "limit" to limit,
                "offset" to offset,
            ),
        )
    }

    suspend fun defaultSearchKeyword(): JsonObject = getRaw("/search/default").jsonObject

    suspend fun hotSearches(): JsonObject = getRaw("/search/hot/detail").jsonObject

    suspend fun searchSuggestions(keywords: String, mobile: Boolean = false): JsonObject {
        require(keywords.isNotBlank()) { "keywords cannot be blank." }
        return getRaw(
            "/search/suggest",
            parametersOf("keywords" to keywords, "type" to if (mobile) "mobile" else null),
        ).jsonObject
    }

    suspend fun songDetails(ids: Collection<Long>, forceRefresh: Boolean = false): SongDetailResponse {
        require(ids.isNotEmpty()) { "ids cannot be empty." }
        return get("/song/detail", freshParameters(forceRefresh, "ids" to ids.joinToString(",")))
    }

    suspend fun songUrls(
        ids: Collection<Long>,
        quality: AudioQuality = AudioQuality.EXHIGH,
        unblock: Boolean = false,
        immerseType: String? = null,
    ): SongUrlResponse {
        require(ids.isNotEmpty()) { "ids cannot be empty." }
        return get(
            "/song/url/v1",
            parametersOf(
                "id" to ids.joinToString(","),
                "level" to quality.apiValue,
                "unblock" to unblock,
                "immerseType" to immerseType,
            ),
        )
    }

    suspend fun isMusicAvailable(id: Long, bitrate: Int? = null): MusicAvailabilityResponse =
        get("/check/music", parametersOf("id" to id, "br" to bitrate))

    suspend fun lyrics(id: Long): LyricResponse = get("/lyric", parametersOf("id" to id))

    suspend fun wordByWordLyrics(id: Long): LyricResponse = get("/lyric/new", parametersOf("id" to id))

    /**
     * Prefers `/lyric/new`, but falls back when that successful response contains no timed lyric.
     * The Gateway documentation explicitly notes that some songs do not provide the `yrc` field;
     * a transport-only fallback misses that normal response shape.
     */
    suspend fun preferredLyrics(id: Long): LyricResponse {
        val enhanced = runCatching { wordByWordLyrics(id) }.getOrNull()
        if (enhanced?.pureMusic == true || enhanced?.hasTimedLyricPayload() == true) return enhanced

        return runCatching { lyrics(id) }.getOrElse { regularError ->
            enhanced ?: throw regularError
        }
    }

    suspend fun playlistDetail(
        id: Long,
        subscriberLimit: Int = 8,
        forceRefresh: Boolean = false,
    ): PlaylistDetailResponse {
        require(subscriberLimit >= 0) { "subscriberLimit cannot be negative." }
        return get("/playlist/detail", freshParameters(forceRefresh, "id" to id, "s" to subscriberLimit))
    }

    suspend fun playlistTracks(
        id: Long,
        limit: Int? = null,
        offset: Int = 0,
        forceRefresh: Boolean = false,
    ): PlaylistTracksResponse {
        require(limit == null || limit > 0) { "limit must be greater than zero." }
        require(offset >= 0) { "offset cannot be negative." }
        return get(
            "/playlist/track/all",
            freshParameters(forceRefresh, "id" to id, "limit" to limit, "offset" to offset),
        )
    }

    suspend fun userPlaylists(
        uid: Long,
        limit: Int = 30,
        offset: Int = 0,
        forceRefresh: Boolean = false,
    ): UserPlaylistsResponse {
        require(limit > 0) { "limit must be greater than zero." }
        require(offset >= 0) { "offset cannot be negative." }
        return get(
            "/user/playlist",
            freshParameters(forceRefresh, "uid" to uid, "limit" to limit, "offset" to offset),
        )
    }

    suspend fun topPlaylists(
        category: String? = null,
        order: String = "hot",
        limit: Int = 50,
        offset: Int = 0,
        forceRefresh: Boolean = false,
    ): TopPlaylistsResponse {
        require(limit > 0) { "limit must be greater than zero." }
        require(offset >= 0) { "offset cannot be negative." }
        return get(
            "/top/playlist",
            freshParameters(
                forceRefresh,
                "cat" to category,
                "order" to order,
                "limit" to limit,
                "offset" to offset,
            ),
        )
    }

    suspend fun albumDetail(id: Long): AlbumDetailResponse = get("/album", parametersOf("id" to id))

    suspend fun artistDetail(id: Long): ArtistDetailResponse = get("/artist/detail", parametersOf("id" to id))

    suspend fun artistTopSongs(id: Long): SongDetailResponse = get("/artist/top/song", parametersOf("id" to id))

    suspend fun banners(platform: BannerPlatform = BannerPlatform.DESKTOP): BannerResponse =
        get("/banner", parametersOf("type" to platform.apiValue))

    suspend fun dailyRecommendedSongs(forceRefresh: Boolean = false): DailySongsResponse =
        get("/recommend/songs", freshParameters(forceRefresh))

    suspend fun dailyRecommendedPlaylists(forceRefresh: Boolean = false): DailyPlaylistsResponse =
        get("/recommend/resource", freshParameters(forceRefresh))

    suspend fun personalFm(): PersonalFmResponse = get("/personal_fm")

    suspend fun likedSongIds(uid: Long, forceRefresh: Boolean = false): LikedSongIdsResponse =
        get("/likelist", freshParameters(forceRefresh, "uid" to uid))

    suspend fun setSongLiked(songId: Long, userId: Long, liked: Boolean): JsonObject =
        postRaw(
            "/song/like",
            parametersOf("id" to songId, "uid" to userId, "like" to liked),
        ).jsonObject

    /** Updates a liked song without exposing the transport JSON type to UI modules. */
    suspend fun updateSongLiked(songId: Long, userId: Long, liked: Boolean) {
        setSongLiked(songId, userId, liked)
    }

    suspend fun listenTogetherCreateRoom(): JsonObject = postRaw("/listentogether/room/create").jsonObject

    /** Opens a room that accepts more than one participant, seeded with the current queue. */
    suspend fun listenTogetherCreateMultiRoom(
        songId: Long,
        nextSongIds: List<Long> = emptyList(),
        playedTimeMillis: Long = 0L,
    ): JsonObject = postRaw(
        "/listentogether/multi/room/create",
        parametersOf(
            "id" to songId,
            "playedTime" to playedTimeMillis.coerceAtLeast(0L),
            "nextSongIds" to nextSongIds.joinToString(","),
        ),
    ).jsonObject

    suspend fun listenTogetherAccept(roomId: String, inviterId: Long): JsonObject = postRaw(
        "/listentogether/accept",
        parametersOf("roomId" to roomId, "inviterId" to inviterId),
    ).jsonObject

    suspend fun listenTogetherRoomCheck(roomId: String): JsonObject = postRaw(
        "/listentogether/room/check", parametersOf("roomId" to roomId),
    ).jsonObject

    suspend fun listenTogetherStatus(): JsonObject = getRaw("/listentogether/status").jsonObject

    suspend fun listenTogetherEnd(roomId: String): JsonObject = postRaw(
        "/listentogether/end", parametersOf("roomId" to roomId),
    ).jsonObject

    suspend fun listenTogetherHeartbeat(roomId: String, songId: Long, playStatus: String, progress: Long): JsonObject = postRaw(
        "/listentogether/heartbeat", parametersOf(
            "roomId" to roomId, "songId" to songId, "playStatus" to playStatus, "progress" to progress,
        ),
    ).jsonObject

    suspend fun listenTogetherPlayCommand(
        roomId: String,
        commandType: String,
        progress: Long,
        playStatus: String,
        formerSongId: Long,
        targetSongId: Long,
        clientSeq: Long,
    ): JsonObject {
        val commandInfo = buildJsonObject {
            put("commandType", commandType)
            put("progress", progress.coerceAtLeast(0L))
            put("playStatus", playStatus)
            put("formerSongId", formerSongId)
            put("targetSongId", targetSongId)
            put("clientSeq", clientSeq.coerceAtLeast(1L))
        }.toString()
        return postRaw(
            "/listentogether/play/command",
            parametersOf("roomId" to roomId, "commandInfo" to commandInfo),
        ).jsonObject
    }

    suspend fun listenTogetherSyncList(
        roomId: String,
        commandType: String,
        versions: List<ListenTogetherPlaylistVersion>,
        playMode: String,
        anchorSongId: Long?,
        anchorPosition: Int,
        randomList: List<Long>,
        displayList: List<Long>,
    ): JsonObject {
        val playlistParam = buildJsonObject {
            put("commandType", commandType)
            put("version", kotlinx.serialization.json.buildJsonArray {
                versions.forEach { item ->
                    add(buildJsonObject {
                        put("userId", item.userId)
                        put("version", item.version)
                    })
                }
            })
            put("playMode", playMode)
            put("anchorSongId", anchorSongId?.toString().orEmpty())
            put("anchorPosition", anchorPosition)
            put("randomList", kotlinx.serialization.json.buildJsonArray {
                randomList.forEach { add(kotlinx.serialization.json.JsonPrimitive(it.toString())) }
            })
            put("displayList", kotlinx.serialization.json.buildJsonArray {
                displayList.forEach { add(kotlinx.serialization.json.JsonPrimitive(it.toString())) }
            })
        }.toString()
        return postRaw(
            "/listentogether/sync/list/command",
            parametersOf("roomId" to roomId, "playlistParam" to playlistParam),
        ).jsonObject
    }

    suspend fun listenTogetherPlaylist(roomId: String): JsonObject = postRaw(
        "/listentogether/sync/playlist/get", parametersOf("roomId" to roomId),
    ).jsonObject

    private val transport = NeteaseTransport(config, httpClient, { sessionCookie }, nowMillis)

    private suspend fun requestJson(
        method: HttpMethod,
        path: String,
        inputParameters: Map<String, String>,
    ): JsonElement = transport.request(path, inputParameters)

    private fun freshParameters(
        forceRefresh: Boolean,
        vararg values: Pair<String, Any?>,
    ): Map<String, String> = parametersOf(*values).toMutableMap().apply {
        if (forceRefresh) put("timestamp", nowMillis().toString())
    }

    private fun rememberCookie(response: LoginResponse): LoginResponse = response.also {
        normalizeGatewaySessionCookie(it.cookie)?.let { cookie -> sessionStore.cookie = cookie }
    }

    private fun rememberCookie(response: QrCheckResponse): QrCheckResponse = response.also {
        normalizeGatewaySessionCookie(it.cookie)?.let { cookie -> sessionStore.cookie = cookie }
    }
}

private val YrcTimedLinePattern = Regex("""(?m)^\s*\[\d+,\d+]""")
private val LrcTimedLinePattern = Regex("""(?m)^\s*\[\d{1,2}:\d{2}""")

private fun LyricResponse.hasTimedLyricPayload(): Boolean =
    yrc?.lyric?.let(YrcTimedLinePattern::containsMatchIn) == true ||
        lrc?.lyric?.let(LrcTimedLinePattern::containsMatchIn) == true

private fun parametersOf(vararg values: Pair<String, Any?>): Map<String, String> =
    buildMap {
        values.forEach { (key, value) ->
            if (value != null) put(key, value.toString())
        }
    }

/** The upstream answers 200 at the transport layer for a rejected write, so check the body code. */
private fun requireCommentSuccess(response: JsonObject) {
    check(response["code"]?.jsonPrimitive?.intOrNull == 200) { "comment request was rejected" }
}

private fun Map<String, String>.toJsonObject(): JsonObject = buildJsonObject {
    this@toJsonObject.forEach { (key, value) -> put(key, value) }
}

private fun redactCookie(responseBody: String): String =
    COOKIE_FIELD_REGEX.replace(responseBody) { match ->
        match.groupValues[1] + "<redacted>" + match.groupValues[2]
    }

private val COOKIE_FIELD_REGEX = Regex("(\\\"cookie\\\"\\s*:\\s*\\\")[^\\\"]*(\\\")")

@PublishedApi
internal val gatewayJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
    coerceInputValues = true
}
