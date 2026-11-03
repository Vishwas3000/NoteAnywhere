package com.memorynotes.android

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** VaultTest's Mac vectors again, on Android's own crypto providers, plus the Keystore-sealed secrets. */
class DeviceTest {
    private val passphrase = "demo passphrase ünïcødé 🔑"
    private val salt = "AwoRGB8mLTQ7QklQV15lbA=="
    private val wrapped = "hKp2sCFdZfqcawNkXdShq2txkQUDg8sZbeXDLxUWGUefDtnrsUp5FPVWcgYenE6Wh5DiAsrzkPYPzkNT"
    private val vaultKeyHex = "fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0"
    private val sealedText = "mne2e:v1:j01xpPcRwHLfav25B8c33J1a/s391tN+Z1tcB8L+vxuBCZecGv32gbibLYhhLX1YklEzaFZv/hTu55I9Mx8XI8dj6bJ2OZoHeHmqSJZ8XnN/pznTzZdRXBW9sBr3u9jXWE+5+zmwN6Q="
    private val text = "# Demo note\nLine two with émoji 🎉 and **bold**\n\n- [ ] a task @2026-11-03"

    @Test fun opensTheMacsVaultAndText() {
        val key = Vault.unwrap(passphrase, salt, wrapped)!!
        assertEquals(vaultKeyHex, key.joinToString("") { "%02x".format(it) })
        assertEquals(text, Vault.open(sealedText, key))
        assertEquals(text, Vault.open(Vault.seal(text, key), key))
    }

    @Test fun secretsSurviveANewInstance() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        Secrets(context).set("device-test", "demo value")
        assertEquals("demo value", Secrets(context).get("device-test"))
        Secrets(context).set("device-test", null)
        assertNull(Secrets(context).get("device-test"))
    }
}
