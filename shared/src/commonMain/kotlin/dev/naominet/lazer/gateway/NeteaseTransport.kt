package dev.naominet.lazer.gateway

import io.ktor.client.HttpClient
import io.ktor.client.request.forms.FormDataContent
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.*
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

internal class NeteaseTransport(
    private val config: GatewayConfig,
    private val client: HttpClient,
    private val cookie: () -> String?,
    private val nowMillis: () -> Long,
) {
    suspend fun request(alias: String, parameters: Map<String, String>): JsonElement {
        require(alias.startsWith('/') && !alias.startsWith("//") &&
            alias.none { it == '?' || it == '#' || it == '\\' } && ":" !in alias && ".." !in alias) {
            "Supply a supported relative Gateway route."
        }
        require(parameters.keys.none { it in transportOverrides }) {
            "Built-in Gateway transport overrides are not supported."
        }
        if (alias == "/login/qr/create") {
            val key = parameters["key"].orEmpty()
            require(key.isNotBlank()) { "key cannot be blank." }
            val url = URLBuilder("https://music.163.com/login").apply {
                this.parameters.append("codekey", key)
            }.buildString()
            return buildJsonObject {
                put("code", 200)
                putJsonObject("data") { put("qrurl", url); put("qrimg", "") }
            }
        }
        if (alias == "/playlist/track/all") return playlistTracks(parameters)
        val result = execute(neteaseRequest(alias, parameters), alias)
        val body = result.body
        return when (alias) {
            "/login/qr/key" -> buildJsonObject { put("code", 200); put("data", body) }
            "/login/status" -> buildJsonObject { put("data", body) }
            // The QR session rotates while the user scans, so every poll hands back whichever
            // cookies it received — 801/802 included, not just the 803 that ends the login.
            "/login/qr/check" -> JsonObject(body + (result.cookie?.let {
                mapOf("cookie" to JsonPrimitive(it))
            } ?: emptyMap()))
            "/login", "/login/cellphone", "/login/refresh" -> {
                val successful = body["code"]?.jsonPrimitive?.intOrNull == 200
                JsonObject(body + if (successful && result.cookie != null) {
                    mapOf("cookie" to JsonPrimitive(result.cookie))
                } else emptyMap())
            }
            "/check/music" -> {
                val first = (body["data"] as? JsonArray)?.firstOrNull() as? JsonObject
                val available = body["code"]?.jsonPrimitive?.intOrNull == 200 &&
                    first?.get("code")?.jsonPrimitive?.intOrNull == 200
                buildJsonObject {
                    put("code", 200); put("success", available)
                    put("message", if (available) "ok" else "亲爱的,暂无版权")
                }
            }
            else -> body
        }
    }

    private suspend fun playlistTracks(parameters: Map<String, String>): JsonObject {
        val offset = parameters["offset"]?.toIntOrNull() ?: 0
        val limit = parameters["limit"]?.toIntOrNull() ?: 1000
        require(offset >= 0 && limit > 0) { "Invalid playlist page." }
        val detail = execute(neteaseRequest("/playlist/detail", parameters), "/playlist/track/all").body
        if (detail["code"]?.jsonPrimitive?.intOrNull != 200) return detail
        val ids = (detail["playlist"] as? JsonObject)?.get("trackIds") as? JsonArray
            ?: throw GatewayProtocolException("/playlist/track/all", IllegalStateException("Missing track IDs."))
        val page = ids.drop(offset).take(limit)
        if (page.isEmpty()) return buildJsonObject {
            put("code", 200); put("songs", JsonArray(emptyList())); put("privileges", JsonArray(emptyList()))
        }
        val payload = JsonArray(page.map { track ->
            val id = (track as? JsonObject)?.get("id")?.jsonPrimitive?.longOrNull
            require(id != null && id > 0) { "Invalid playlist track ID." }
            buildJsonObject { put("id", id) }
        })
        return execute(NeteaseRequest("/api/v3/song/detail", buildJsonObject {
            put("c", payload.toString())
        }), "/playlist/track/all").body
    }

    private data class Response(val body: JsonObject, val cookie: String?)

    private suspend fun execute(route: NeteaseRequest, alias: String): Response {
        val currentCookie = cookie()
        val cookies = currentCookie.orEmpty().split(';').mapNotNull { segment ->
            val parts = segment.trim().split('=', limit = 2)
            if (parts.size == 2) parts[0] to parts[1] else null
        }.toMap()
        val csrf = cookies["__csrf"].orEmpty()
        val web = route.encoding == NeteaseEncoding.WEAPI
        val plain = route.encoding == NeteaseEncoding.API
        val profile = route.client
        val payload = buildJsonObject {
            route.payload.forEach { (key, value) -> put(key, value) }
            if (plain) return@buildJsonObject
            put("e_r", false)
            if (web) put("csrf_token", csrf)
            else putJsonObject("header") {
                put("os", profile.os); put("appver", profile.appver)
                profile.versioncode?.let { put("versioncode", it) }
                put("__csrf", csrf)
                put("requestId", "${nowMillis()}_${NeteaseCrypto.secureRandom(4).hex()}")
                // Only carry server-issued identity fields, never synthesize anti-cheat tokens.
                listOf("MUSIC_U", "MUSIC_A", "NMTID", "deviceId").forEach { name ->
                    cookies[name]?.let { put(name, it) }
                }
            }
        }
        val form = when {
            plain -> payload.mapValues { (_, value) -> value.jsonPrimitive.content }
            web -> NeteaseCrypto.weapi(payload.toString())
            else -> mapOf("params" to NeteaseCrypto.eapi(route.path, payload.toString()))
        }
        val endpoint = when {
            plain -> "https://music.163.com"
            web -> "https://music.163.com/weapi/"
            else -> "https://interfacepc.music.163.com/eapi/"
        }
        val target = if (plain) route.path else route.path.removePrefix("/api/")
        val response = client.post(endpoint + target) {
            header(HttpHeaders.Accept, "application/json")
            // The plain surface is the desktop client's own: present its user agent there.
            header(HttpHeaders.UserAgent, if (plain) DESKTOP_USER_AGENT else config.userAgent ?: "Lazer")
            header("Referer", "https://music.163.com/")
            header(HttpHeaders.CacheControl, "no-cache")
            requestCookie(profile, currentCookie)?.let { header(HttpHeaders.Cookie, it) }
            setBody(FormDataContent(Parameters.build { form.forEach { (key, value) -> append(key, value) } }))
        }
        // Never retain a potentially credential-bearing upstream error body in an exception.
        if (!response.status.isSuccess()) throw GatewayHttpException(response.status.value, alias, "<redacted>")
        val body = try {
            normalizeFields(gatewayJson.parseToJsonElement(response.bodyAsText())).jsonObject
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            throw GatewayProtocolException(alias, IllegalStateException("Invalid upstream JSON."))
        }
        val normalized = body["code"]?.jsonPrimitive?.intOrNull?.let {
            JsonObject(body + ("code" to JsonPrimitive(it)))
        } ?: body
        val setCookies = response.headers.getAll(HttpHeaders.SetCookie).orEmpty()
        val mergedCookie = if (setCookies.isEmpty()) null else normalizeGatewaySessionCookie(
            (listOfNotNull(currentCookie) + setCookies.map { it.substringBefore(';') }).joinToString("; "),
        )
        return Response(normalized, mergedCookie)
    }
}

private val transportOverrides = setOf(
    "cookie", "domain", "crypto", "proxy", "headers", "realIP", "randomCNIP", "ua", "checkToken", "e_r",
)

/** The desktop client's own user agent, presented on the plain `api` surface it owns. */
private const val DESKTOP_USER_AGENT =
    "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 " +
        "Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117"

/**
 * The mobile app mirrors its own client version into plain cookies next to the encrypted header,
 * and the upstream keeps the room creator's version from either channel. Only the outgoing request
 * carries these; the signed-in session never absorbs them.
 */
private fun requestCookie(profile: NeteaseClient, session: String?): String? {
    if (profile !== NeteaseClient.Mobile) return session
    val identity = buildList {
        add("os=${profile.os}")
        add("appver=${profile.appver}")
        profile.versioncode?.let { add("versioncode=$it") }
    }.joinToString("; ")
    return session?.plus("; $identity") ?: identity
}

private fun normalizeFields(element: JsonElement): JsonElement = when (element) {
    is JsonObject -> JsonObject(element.map { (key, value) ->
        (if (key == "avatarImgId_str") "avatarImgIdStr" else key) to normalizeFields(value)
    }.toMap())
    is JsonArray -> JsonArray(element.map(::normalizeFields))
    else -> element
}
