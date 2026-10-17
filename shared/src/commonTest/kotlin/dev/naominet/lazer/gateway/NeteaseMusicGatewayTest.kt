package dev.naominet.lazer.gateway

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.forms.FormDataContent
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NeteaseMusicGatewayTest {

    @Test
    fun `flattened Set-Cookie values are compacted and deduplicated`() {
        val rawCookie = buildString {
            append("MUSIC_U=old-session; Path=/; Max-Age=100; HttpOnly; ")
            append("MUSIC_A_T=access-token; Path=/; SameSite=None; Secure; ")
            append("MUSIC_U=current-session; Expires=Wed, 21 Oct 2030 07:28:00 GMT")
        }

        assertEquals(
            "MUSIC_U=current-session; MUSIC_A_T=access-token",
            normalizeGatewaySessionCookie(rawCookie),
        )
    }

    @Test
    fun `reading a saved session migrates a verbose cookie in place`() {
        val session = InMemoryGatewaySessionStore(
            "MUSIC_U=current-session; Path=/; Path=/; Max-Age=100; HttpOnly",
        )
        val client = HttpClient(MockEngine { error("No request expected") })
        val gateway = gateway(client, session)

        assertEquals("MUSIC_U=current-session", gateway.sessionCookie)
        assertEquals("MUSIC_U=current-session", session.cookie)
    }

    @Test
    fun `password login posts the encrypted form and stores the returned cookie`() = runTest {
        val session = InMemoryGatewaySessionStore()
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/weapi/w/login/cellphone", request.url.encodedPath)
            val form = (request.body as FormDataContent).formData
            assertEquals(setOf("params", "encSecKey"), form.names())
            assertFalse(form.entries().any { (_, value) -> value.any { "13800138000" in it } })
            assertFalse(form.entries().any { (_, value) -> value.any { "secret-password" in it } })

            respond(
                content = """{"code":200,"profile":{"userId":7,"nickname":"Lazer"}}""",
                headers = mergeJsonAndCookieHeaders(
                    "MUSIC_U=new-session; Path=/; HttpOnly",
                ),
            )
        })
        val gateway = gateway(client, session)

        val response = gateway.loginWithPhonePassword(
            phone = "13800138000",
            password = "secret-password",
            countryCode = "86",
        )

        assertEquals(200, response.code)
        assertEquals("Lazer", response.profile?.nickname)
        assertEquals("MUSIC_U=new-session", session.cookie)
    }

    @Test
    fun `qr create returns the documented scan URL without a network request`() = runTest {
        val client = HttpClient(MockEngine { error("QR create is synthesized locally") })
        val gateway = gateway(client)

        val response = gateway.createQrCode("qr-key", includeImage = false)

        assertEquals(200, response.code)
        assertEquals("https://music.163.com/login?codekey=qr-key", response.data?.qrurl)
    }

    @Test
    fun `authorized QR result stores its session cookie`() = runTest {
        val session = InMemoryGatewaySessionStore()
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            // The official desktop client polls the plain api surface, not the eapi envelope.
            assertEquals("/api/login/qrcode/client/login", request.url.encodedPath)
            val form = (request.body as FormDataContent).formData
            assertEquals(setOf("key", "type", "secureCaptcha"), form.names())
            assertEquals("qr-key", form["key"])
            assertEquals("3", form["type"])

            respond(
                content = """{"code":803,"message":"授权登录成功"}""",
                headers = mergeJsonAndCookieHeaders("MUSIC_U=qr-session; Path=/"),
            )
        })
        val gateway = gateway(client, session)

        val response = gateway.checkQrCode("qr-key")

        assertTrue(response.isAuthorized)
        assertEquals("MUSIC_U=qr-session", gateway.sessionCookie)
    }

    @Test
    fun `scan key is minted on the plain api surface`() = runTest {
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/api/login/qrcode/unikey", request.url.encodedPath)
            val form = (request.body as FormDataContent).formData
            assertEquals(setOf("type"), form.names())
            assertEquals("3", form["type"])

            respond(content = """{"code":200,"unikey":"qr-key"}""", headers = jsonHeaders())
        })
        val gateway = gateway(client)

        assertEquals("qr-key", gateway.createQrKey().data?.unikey)
    }

    @Test
    fun `login status wraps the account and profile response`() = runTest {
        val session = InMemoryGatewaySessionStore("MUSIC_U=qr-session")
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/weapi/w/nuser/account/get", request.url.encodedPath)
            assertEquals("MUSIC_U=qr-session", request.headers[HttpHeaders.Cookie])

            respond(
                content = """{"code":200,"account":{"id":7},"profile":{"userId":7,"nickname":"Lazer"}}""",
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client, session)

        val response = gateway.loginStatus()

        assertEquals(7, response.data?.account?.id)
        assertEquals("Lazer", response.data?.profile?.nickname)
    }

    @Test
    fun `cookie login verifies and persists the supplied browser cookie`() = runTest {
        val session = InMemoryGatewaySessionStore("MUSIC_U=previous-session")
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/weapi/w/nuser/account/get", request.url.encodedPath)
            assertEquals("MUSIC_U=browser-session", request.headers[HttpHeaders.Cookie])
            respond(
                content = """{"code":200,"account":{"id":7},"profile":{"userId":7,"nickname":"Lazer"}}""",
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client, session)

        val response = gateway.loginWithCookie("  MUSIC_U=browser-session  ")

        assertEquals(7, response.data?.profile?.userId)
        assertEquals("MUSIC_U=browser-session", session.cookie)
    }

    @Test
    fun `invalid cookie login restores the previous session`() = runTest {
        val session = InMemoryGatewaySessionStore("MUSIC_U=previous-session")
        val client = HttpClient(MockEngine {
            respond(content = """{"code":301,"account":null,"profile":null}""", headers = jsonHeaders())
        })
        val gateway = gateway(client, session)

        val response = gateway.loginWithCookie("MUSIC_U=expired-session")

        assertNull(response.data?.profile)
        assertEquals("MUSIC_U=previous-session", session.cookie)
    }

    @Test
    fun `user detail posts the profile route and decodes the profile`() = runTest {
        val session = InMemoryGatewaySessionStore("MUSIC_U=active-session")
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/weapi/v1/user/detail/7", request.url.encodedPath)
            assertEquals("MUSIC_U=active-session", request.headers[HttpHeaders.Cookie])
            respond(
                content = """{"code":200,"profile":{"userId":7,"nickname":"Lazer"}}""",
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client, session)

        val response = gateway.userDetail(7)

        assertEquals("Lazer", response.profile?.nickname)
    }

    @Test
    fun `song URLs decode nullable URLs from the player route`() = runTest {
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/weapi/song/enhance/player/url", request.url.encodedPath)
            val form = (request.body as FormDataContent).formData
            assertEquals(setOf("params", "encSecKey"), form.names())

            respond(
                content = """
                    {
                      "code": 200,
                      "data": [
                        {"id":1,"url":"https://cdn.example/1.mp3","br":320000,"size":42,"type":"mp3"},
                        {"id":2,"url":null,"code":404}
                      ]
                    }
                """.trimIndent(),
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client)

        val response = gateway.songUrls(ids = listOf(1, 2), quality = AudioQuality.EXHIGH)

        assertEquals("https://cdn.example/1.mp3", response.data[0].url)
        assertEquals(null, response.data[1].url)
    }

    @Test
    fun `artist detail decodes the nested artist`() = runTest {
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/eapi/artist/head/info/get", request.url.encodedPath)
            respond(
                content = """
                    {
                      "code": 200,
                      "message": "ok",
                      "data": {
                        "videoCount": 8,
                        "blacklist": false,
                        "artist": {
                          "id": 6452,
                          "name": "Jay Chou",
                          "alias": ["周董"],
                          "cover": "https://cdn.example/cover.jpg",
                          "albumSize": 44,
                          "musicSize": 568,
                          "mvSize": 9
                        }
                      }
                    }
                """.trimIndent(),
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client)

        val response = gateway.artistDetail(6452)
        val detail = assertNotNull(response.data)

        assertEquals(8, detail.videoCount)
        assertFalse(detail.blacklist ?: true)
        assertEquals("Jay Chou", detail.artist?.name)
        assertEquals("https://cdn.example/cover.jpg", detail.artist?.cover)
        assertEquals(568, detail.artist?.musicSize)
    }

    @Test
    fun `HTTP errors expose status without leaking cookies`() = runTest {
        val client = HttpClient(MockEngine {
            respond(
                content = """{"code":502,"cookie":"MUSIC_U=should-not-leak","msg":"bad gateway"}""",
                status = HttpStatusCode.BadGateway,
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client)

        val exception = assertFailsWith<GatewayHttpException> {
            gateway.lyrics(33894312)
        }

        assertEquals(502, exception.statusCode)
        assertEquals("/lyric", exception.endpoint)
        assertFalse(exception.responseBody.contains("MUSIC_U=should-not-leak"))
        assertTrue(exception.responseBody.contains("<redacted>"))
    }

    @Test
    fun `logout sends the session and clears it after a successful response`() = runTest {
        val session = InMemoryGatewaySessionStore("MUSIC_U=active-session")
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/eapi/logout", request.url.encodedPath)
            assertEquals("MUSIC_U=active-session", request.headers[HttpHeaders.Cookie])
            respond(content = "{\"code\":200}", headers = jsonHeaders())
        })
        val gateway = gateway(client, session)

        gateway.logout()

        assertNull(gateway.sessionCookie)
    }

    @Test
    fun `non JSON gateway responses identify the requested endpoint`() = runTest {
        val client = HttpClient(MockEngine {
            respond(content = "not JSON", headers = jsonHeaders())
        })
        val gateway = gateway(client)

        val exception = assertFailsWith<GatewayProtocolException> {
            gateway.lyrics(33894312)
        }

        assertEquals("/lyric", exception.endpoint)
    }

    @Test
    fun `preferred lyrics retries regular route when new route has no timed content`() = runTest {
        val requestedPaths = mutableListOf<String>()
        val client = HttpClient(MockEngine { request ->
            requestedPaths += request.url.encodedPath
            when (request.url.encodedPath) {
                "/eapi/song/lyric/v1" -> respond(
                    content = """{"code":200,"yrc":{"lyric":"{\"t\":0}"}}""",
                    headers = jsonHeaders(),
                )
                "/eapi/song/lyric" -> respond(
                    content = """{"code":200,"lrc":{"lyric":"[00:01.00]普通歌词"}}""",
                    headers = jsonHeaders(),
                )
                else -> error("Unexpected route: ${request.url.encodedPath}")
            }
        })

        val response = gateway(client).preferredLyrics(42)

        assertEquals("[00:01.00]普通歌词", response.lrc?.lyric)
        assertEquals(listOf("/eapi/song/lyric/v1", "/eapi/song/lyric"), requestedPaths)
    }

    @Test
    fun `preferred lyrics keeps documented word lyric without a second request`() = runTest {
        var requestCount = 0
        val client = HttpClient(MockEngine { request ->
            requestCount++
            assertEquals("/eapi/song/lyric/v1", request.url.encodedPath)
            respond(
                content = """{"code":200,"yrc":{"lyric":"[1000,500](1000,500,0)一句"}}""",
                headers = jsonHeaders(),
            )
        })

        val response = gateway(client).preferredLyrics(42)

        assertEquals(1, requestCount)
        assertEquals("[1000,500](1000,500,0)一句", response.yrc?.lyric)
    }

    @Test
    fun `word lyric route asks the service for the whole payload`() {
        val request = neteaseRequest("/lyric/new", mapOf("id" to "42"))

        // Without the version counters the service answers with an empty envelope, and -1 asks
        // for everything rather than a delta of what the caller already cached.
        assertEquals(setOf("id", "cp", "tv", "lv", "rv", "kv", "yv", "ytv", "yrv"), request.payload.keys)
        assertEquals("-1", request.payload["lv"]?.jsonPrimitive?.content)
        assertEquals("-1", request.payload["yv"]?.jsonPrimitive?.content)
    }

    @Test
    fun `raw routes reject absolute URLs`() = runTest {
        val gateway = gateway(HttpClient(MockEngine { error("request should not be reached") }))

        val exception = assertFailsWith<IllegalArgumentException> {
            gateway.getRaw("https://unexpected.example/search")
        }

        assertNotNull(exception.message)
    }

    @Test
    fun `playlist tracks page through detail then song detail`() = runTest {
        val requestedPaths = mutableListOf<String>()
        val client = HttpClient(MockEngine { request ->
            requestedPaths += request.url.encodedPath
            when (request.url.encodedPath) {
                "/eapi/v6/playlist/detail" -> respond(
                    content = """{"code":200,"playlist":{"id":9,"trackIds":[{"id":1},{"id":2},{"id":3}]}}""",
                    headers = jsonHeaders(),
                )
                "/eapi/v3/song/detail" -> respond(
                    content = """{"code":200,"songs":[{"id":2,"name":"第二首"},{"id":3,"name":"第三首"}]}""",
                    headers = jsonHeaders(),
                )
                else -> error("Unexpected route: ${request.url.encodedPath}")
            }
        })

        val response = gateway(client).playlistTracks(id = 9, limit = 2, offset = 1)

        assertEquals(listOf("/eapi/v6/playlist/detail", "/eapi/v3/song/detail"), requestedPaths)
        assertEquals(listOf(2L, 3L), response.songs.map { it.id })
    }

    @Test
    fun `daily recommendations decode their picUrl cover field`() = runTest {
        val client = HttpClient(MockEngine { request ->
            assertEquals("/weapi/v1/discovery/recommend/resource", request.url.encodedPath)
            respond(
                content = """
                    {
                      "code": 200,
                      "recommend": [{
                        "id": 42,
                        "name": "今日推荐",
                        "picUrl": "https://p1.music.126.net/recommend.jpg",
                        "trackCount": 20
                      }]
                    }
                """.trimIndent(),
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client)

        val playlist = gateway.dailyRecommendedPlaylists().recommend.single()

        assertEquals("https://p1.music.126.net/recommend.jpg", playlist.picUrl)
        assertNull(playlist.coverImgUrl)
    }

    @Test
    fun `blank coverImgUrl does not hide picUrl when resolving covers`() = runTest {
        val client = HttpClient(MockEngine {
            respond(
                content = """
                    {
                      "code": 200,
                      "recommend": [{
                        "id": 7,
                        "name": "空白封面字段",
                        "coverImgUrl": "",
                        "picUrl": "https://p1.music.126.net/real.jpg",
                        "trackCount": 12
                      }]
                    }
                """.trimIndent(),
                headers = jsonHeaders(),
            )
        })
        val playlist = gateway(client).dailyRecommendedPlaylists().recommend.single()
        val cover = sequenceOf(playlist.coverImgUrl, playlist.picUrl)
            .mapNotNull { it?.trim()?.takeIf(String::isNotBlank) }
            .firstOrNull()

        assertEquals("https://p1.music.126.net/real.jpg", cover)
    }

    private fun gateway(
        client: HttpClient,
        sessionStore: GatewaySessionStore = InMemoryGatewaySessionStore(),
    ): NeteaseMusicGateway = NeteaseMusicGateway(
        config = GatewayConfig(userAgent = "Lazer test client"),
        sessionStore = sessionStore,
        httpClient = client,
        closeHttpClient = false,
        nowMillis = { 123456789L },
    )

    private fun jsonHeaders() = headersOf(
        HttpHeaders.ContentType,
        ContentType.Application.Json.toString(),
    )

    private fun mergeJsonAndCookieHeaders(cookie: String) = headersOf(
        HttpHeaders.ContentType to listOf(ContentType.Application.Json.toString()),
        HttpHeaders.SetCookie to listOf(cookie),
    )
}
