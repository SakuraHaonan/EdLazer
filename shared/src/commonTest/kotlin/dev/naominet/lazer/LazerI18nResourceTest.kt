package dev.naominet.lazer

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertTrue

class LazerI18nResourceTest {
    @Test
    fun loadsEveryBundledJsonCatalog() = runTest {
        loadLazerTranslations()

        try {
            LazerLanguage.entries.forEach { language ->
                LazerI18n.switchLanguage(language)
                assertTrue(language.displayName != "language.${language.code}")
                assertTrue(tr("settings.title") != "settings.title")
                assertTrue(tr("settings.cookie.title") != "settings.cookie.title")
                assertTrue(tr("login.method.cookie") != "login.method.cookie")
                assertTrue(tr("player.play") != "player.play")
            }
        } finally {
            LazerI18n.switchLanguage(LazerLanguage.ENGLISH)
        }
    }
}
