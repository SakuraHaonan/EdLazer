package dev.naominet.lazer.gateway

import kotlinx.serialization.json.*

/**
 * How a route's payload reaches the service.
 *
 * [EAPI] wraps it in the encrypted device envelope, [WEAPI] in the browser envelope, and [API]
 * posts it as a plain form to `music.163.com/api/…` — the unencrypted surface the official desktop
 * client uses for QR sign-in.
 */
internal enum class NeteaseEncoding { EAPI, WEAPI, API }

/**
 * Client identity the upstream request declares. Listen-together rooms remember the creator's
 * client version and the official app refuses a participant it reads as outdated, so those
 * routes present the current mobile release instead of the desktop one.
 */
internal enum class NeteaseClient(val os: String, val appver: String, val versioncode: String?) {
    Desktop("pc", "3.1.17.204416", null),
    Mobile("android", "9.5.95", "9005095"),
}

internal data class NeteaseRequest(
    val path: String,
    val payload: JsonObject,
    val encoding: NeteaseEncoding = NeteaseEncoding.EAPI,
    val client: NeteaseClient = NeteaseClient.Desktop,
)

/** The finite set of wrapper aliases supported in-process. Never accepts an upstream URL. */
internal fun neteaseRequest(alias: String, parameters: Map<String, String>): NeteaseRequest {
    fun value(key: String, fallback: String = "") = parameters[key] ?: fallback
    fun id(key: String = "id"): String = value(key).also {
        require(it.toLongOrNull()?.let { number -> number > 0 } == true) { "$key must be a positive ID." }
    }
    fun roomId(): String = value("roomId").trim().also {
        require(it.length in 1..256 && it.all { char -> char.isLetterOrDigit() || char == '_' || char == '-' }) {
            "roomId must be a non-empty opaque room identifier."
        }
    }
    fun request(
        path: String,
        web: Boolean = false,
        plain: Boolean = false,
        body: JsonObjectBuilder.() -> Unit = {},
    ) = NeteaseRequest(
        path,
        buildJsonObject(body),
        when {
            plain -> NeteaseEncoding.API
            web -> NeteaseEncoding.WEAPI
            else -> NeteaseEncoding.EAPI
        },
        if (alias.startsWith("/listentogether/")) NeteaseClient.Mobile else NeteaseClient.Desktop,
    )
    fun JsonObjectBuilder.page(defaultLimit: Int = 30) {
        put("limit", value("limit", defaultLimit.toString()))
        put("offset", value("offset", "0"))
    }
    return when (alias) {
        "/login/cellphone" -> request("/api/w/login/cellphone", web = true) {
            put("type", "1"); put("https", "true"); put("phone", value("phone"))
            put("countrycode", value("countrycode", "86")); put("remember", "true")
            put("secureCaptcha", value("sca"))
            if (value("captcha").isNotEmpty()) put("captcha", value("captcha"))
            else put("password", parameters["md5_password"] ?: NeteaseCrypto.md5(value("password")))
        }
        "/login" -> request("/api/w/login") {
            put("type", "0"); put("https", "true"); put("username", value("email"))
            put("password", parameters["md5_password"] ?: NeteaseCrypto.md5(value("password")))
            put("rememberLogin", "true")
        }
        /*
         * QR sign-in runs on the plain `/api/` surface, exactly like the official desktop client
         * (`page:loginQrcode`): `/api/login/qrcode/unikey` with `type: 3`, then
         * `/api/login/qrcode/client/login` with `key`, `type` and `secureCaptcha`. Every client
         * that completes the flow uses this surface; the encrypted routes answer 801 forever and
         * never hand the confirmed login back to the poller.
         */
        "/login/qr/key" -> request("/api/login/qrcode/unikey", plain = true) { put("type", 3) }
        "/login/qr/check" -> request("/api/login/qrcode/client/login", plain = true) {
            put("key", value("key")); put("type", 3)
            // Carries the Yidun token when the scan tripped risk control (8821).
            put("secureCaptcha", value("secureCaptcha"))
        }
        "/login/status" -> request("/api/w/nuser/account/get", web = true)
        "/login/refresh" -> request("/api/login/token/refresh")
        "/logout" -> request("/api/logout")
        "/register/anonimous" -> throw UnsupportedOperationException(
            "Anonymous registration requires an unsupported upstream handshake. Use QR or cookie sign-in.",
        )
        "/captcha/sent/v1" -> request("/api/middle/captcha/sent/v1") {
            put("ctcode", value("ctcode", "86")); put("secrete", "music_middleuser_pclogin")
            put("cellphone", value("phone")); put("scene", "0")
        }
        "/search", "/cloudsearch" -> {
            val voice = alias == "/search" && value("type") == "2000"
            request(when {
                voice -> "/api/search/voice/get"
                alias == "/cloudsearch" -> "/api/cloudsearch/pc"
                else -> "/api/search/get"
            }) {
                put(if (voice) "keyword" else "s", value("keywords"))
                if (voice) put("scene", "normal") else put("type", value("type", "1"))
                page()
                if (alias == "/cloudsearch") put("total", true)
            }
        }
        "/search/default" -> request("/api/search/defaultkeyword/get")
        "/search/hot/detail" -> request("/api/hotsearchlist/get", web = true)
        "/search/suggest" -> request(
            if (value("type") == "mobile") "/api/search/suggest/keyword" else "/api/search/suggest/web",
            web = true,
        ) { put("s", value("keywords")) }
        "/song/detail" -> request("/api/v3/song/detail", web = true) {
            put("c", songIdPayload(value("ids")))
        }
        "/song/url/v1" -> request("/api/song/enhance/player/url", web = true) {
            require(value("unblock", "false") == "false") { "External music matching is not supported." }
            val bitrate = when (value("level", "exhigh")) {
                "standard" -> 128000
                "higher" -> 192000
                "exhigh" -> 320000
                else -> throw UnsupportedOperationException("This audio quality requires an unsupported upstream handshake.")
            }
            put("ids", songIds(value("id")).toString()); put("br", bitrate)
        }
        "/check/music" -> request("/api/song/enhance/player/url", web = true) {
            put("ids", "[${id()}]"); put("br", value("br", "999000").toInt())
        }
        "/lyric" -> request("/api/song/lyric") {
            put("id", id()); put("tv", -1); put("lv", -1); put("rv", -1); put("kv", -1); put("_nmclfl", 1)
        }
        "/lyric/new" -> request("/api/song/lyric/v1") {
            put("id", id()); put("cp", false)
            // The version counters are required: without them the service answers with an empty
            // envelope, and -1 asks for the whole payload including word lyric and translation.
            listOf("tv", "lv", "rv", "kv", "yv", "ytv", "yrv").forEach { put(it, -1) }
        }
        "/playlist/detail" -> request("/api/v6/playlist/detail") {
            put("id", id()); put("n", 100000); put("s", value("s", "8"))
        }
        "/user/playlist" -> request("/api/user/playlist", web = true) {
            put("uid", id("uid")); page(); put("includeVideo", true)
        }
        "/top/playlist" -> request("/api/playlist/list", web = true) {
            put("cat", value("cat", "全部")); put("order", value("order", "hot")); page(50); put("total", true)
        }
        "/user/detail" -> request("/api/v1/user/detail/${id("uid")}", web = true)
        "/comment/music" -> request(commentThreadPath(id()), web = true) {
            put("rid", id())
            put("limit", value("limit", "20"))
            put("offset", value("offset", "0"))
            put("beforeTime", value("before", "0"))
        }
        "/comment/like", "/comment/unlike" -> {
            val action = if (alias == "/comment/like") "like" else "unlike"
            request("/api/v1/comment/$action", web = true) {
                put("threadId", songCommentThread(id()))
                put("commentId", id("commentId"))
            }
        }
        "/comment/reply" -> request("/api/resource/comments/reply") {
            put("threadId", songCommentThread(id()))
            put("commentId", id("commentId"))
            put("content", value("content"))
        }
        "/album" -> request("/api/v1/album/${id()}", web = true)
        "/artist/detail" -> request("/api/artist/head/info/get") { put("id", id()) }
        "/artist/top/song" -> request("/api/artist/top/song", web = true) { put("id", id()) }
        "/artist/album" -> request("/api/artist/albums/${id()}", web = true) { page(); put("total", true) }
        "/banner" -> request("/api/v2/banner/get") {
            put("clientType", when (value("type")) { "1" -> "android"; "2" -> "iphone"; "3" -> "ipad"; else -> "pc" })
        }
        "/recommend/songs" -> request("/api/v3/discovery/recommend/songs", web = true) {
            parameters["afresh"]?.let { put("afresh", it) }
        }
        "/recommend/resource" -> request("/api/v1/discovery/recommend/resource", web = true)
        "/personal_fm" -> request("/api/v1/radio/get", web = true)
        "/likelist" -> request("/api/song/like/get") { put("uid", id("uid")) }
        "/song/like" -> request("/api/song/like") {
            put("trackId", id()); put("userid", id("uid")); put("like", value("like") != "false")
        }
        "/listentogether/room/create" -> request("/api/listen/together/room/create") {
            put("refer", "songplay_more")
        }
        "/listentogether/multi/room/create" -> request("/api/listen/together/multi/room/create") {
            put("type", value("type", "0"))
            put("songId", id())
            put("from", "CREATE")
            put("playedTime", value("playedTime", "0"))
            put("groupIds", idArray(value("groupIds")))
            put("inviteUids", idArray(value("inviteUids")))
            put("nextSongIds", idArray(value("nextSongIds")))
            // The upstream issues this device token; an absent one is sent empty, never forged.
            put("checkToken", "")
        }
        "/listentogether/accept" -> request("/api/listen/together/play/invitation/accept") {
            put("refer", "inbox_invite"); put("roomId", roomId()); put("inviterId", id("inviterId"))
        }
        "/listentogether/room/check" -> request("/api/listen/together/room/check") {
            put("roomId", roomId())
        }
        "/listentogether/status" -> request("/api/listen/together/status/get", web = true)
        "/listentogether/end" -> request("/api/listen/together/end/v2") {
            put("roomId", roomId())
        }
        "/listentogether/heartbeat" -> request("/api/listen/together/heartbeat") {
            put("roomId", roomId()); put("songId", value("songId", "0"))
            put("playStatus", value("playStatus")); put("progress", value("progress"))
        }
        "/listentogether/play/command" -> request("/api/listen/together/play/command/report") {
            put("roomId", roomId()); put("commandInfo", value("commandInfo"))
        }
        "/listentogether/sync/list/command" -> request("/api/listen/together/sync/list/command/report") {
            put("roomId", roomId()); put("playlistParam", value("playlistParam"))
        }
        "/listentogether/sync/playlist/get" -> request("/api/listen/together/sync/playlist/get") {
            put("roomId", roomId())
        }
        "/like" -> request("/api/radio/like", web = true) {
            put("alg", "itembased"); put("trackId", id()); put("like", value("like") != "false"); put("time", "3")
        }
        else -> throw IllegalArgumentException("Unsupported built-in Gateway route.")
    }
}

/** Songs own one comment thread namespace; the prefix is built here so no caller can supply one. */
internal const val SONG_COMMENT_THREAD_PREFIX = "R_SO_4_"

private fun songCommentThread(songId: String): String = SONG_COMMENT_THREAD_PREFIX + songId

private fun commentThreadPath(songId: String): String =
    "/api/v1/resource/comments/" + songCommentThread(songId)

internal fun songIds(value: String): JsonArray = JsonArray(value.split(',').map {
    val id = it.trim().toLongOrNull()
    require(id != null && id > 0) { "Song IDs must be positive integers." }
    JsonPrimitive(id)
})

internal fun songIdPayload(value: String): String = JsonArray(songIds(value).map {
    buildJsonObject { put("id", it) }
}).toString()

/** Renders a comma-separated ID list as the JSON array the listen-together routes expect. */
private fun idArray(value: String): String =
    JsonArray(if (value.isBlank()) emptyList() else songIds(value)).toString()
