package com.memorynotes.android

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * Wire compatibility with the Mac and iPhone. The vectors below were made by CryptoKit + CommonCrypto exactly as
 * NoteLock.key, CloudSync.createVault and SyncVault do it (demo text only). `writesVectorsForSwift` leaves Kotlin's
 * own sealing in build/kotlin-vectors.json for the Swift side to open.
 */
class VaultTest {
    private val passphrase = "demo passphrase ünïcødé 🔑"
    private val salt = "AwoRGB8mLTQ7QklQV15lbA=="
    private val derivedHex = "0ed1442570f9b52350dc01b182d99f67e45720a7114a82f227b3ea41b575bff1"
    private val wrapped = "hKp2sCFdZfqcawNkXdShq2txkQUDg8sZbeXDLxUWGUefDtnrsUp5FPVWcgYenE6Wh5DiAsrzkPYPzkNT"
    private val vaultKeyHex = "fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0"
    private val text = "# Demo note\nLine two with émoji 🎉 and **bold**\n\n- [ ] a task @2026-11-03"
    private val sealedText = "mne2e:v1:j01xpPcRwHLfav25B8c33J1a/s391tN+Z1tcB8L+vxuBCZecGv32gbibLYhhLX1YklEzaFZv/hTu55I9Mx8XI8dj6bJ2OZoHeHmqSJZ8XnN/pznTzZdRXBW9sBr3u9jXWE+5+zmwN6Q="
    private val sealedEmpty = "mne2e:v1:7g70P4QPKY6BAff5x/yUkwhTmtNgLzO2NLJ43g=="
    private val sealedImage = "IyRUB5NGUlYVP3BFrikT+h9KaRsSdDAMVtW966zotXfXOiIKwmOcOhLW3aFKLrPfine/ovZ/RZ8mg8xT3iVlf/uRJuuUu9s39EIMSRDnC0FieQgjJYJLVlpn7G0aQRYfR4K0VO6npd+eDgvqqC3OqnVshl9zQHOzQ4t36zfrR/mfkYMzkJimiVf3Mxqinz6dADup7SlCwwUs7iT9cv41HEr2y8P7QvskImCJ7wl39mb1sWgh47XczCINKXR9Yb5rZT3DcKtJn6Qv87b0buv40PnYKlXNeDiw2af8YpWWBvQfI8i2abJL3GeG1o317LxjbRVNOhZHQHLQQf3jUbf84qtruCTGUwTUCS8w9AI5G8+HKsqFdsNKor9oReb6uf9Vp73YQ1vVMx8ec1L3Q/WeGuczP980/TfELpsVnlqoWpeRdnVtAti1DA=="
    private val image = ByteArray(300) { (it % 251).toByte() }
    private val vaultKey = hexBytes(vaultKeyHex)

    @Test fun pbkdf2MatchesCommonCrypto() {
        assertEquals(derivedHex, hex(Vault.deriveKey(passphrase, Vault.decode(salt)!!)))
    }

    @Test fun pbkdf2MatchesTheJdk() {
        val jdk = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(PBEKeySpec("ascii only".toCharArray(), byteArrayOf(1, 2, 3), 310_000, 256)).encoded
        assertArrayEquals(jdk, Vault.deriveKey("ascii only", byteArrayOf(1, 2, 3)))
    }

    @Test fun unwrapsTheMacsVaultKey() {
        assertEquals(vaultKeyHex, hex(Vault.unwrap(passphrase, salt, wrapped)!!))
        assertNull(Vault.unwrap("wrong passphrase", salt, wrapped))
    }

    @Test fun opensMacFields() {
        assertEquals(text, Vault.open(sealedText, vaultKey))
        assertEquals("", Vault.open(sealedEmpty, vaultKey))
    }

    @Test fun opensMacImages() {
        assertArrayEquals(image, Vault.openBytes(Vault.decode(sealedImage)!!, vaultKey))
    }

    @Test(expected = Vault.Failure::class) fun refusesUnsealedText() {
        Vault.open("plain text", vaultKey)
    }

    @Test fun sealRoundTrips() {
        val sealed = Vault.seal(text, vaultKey)
        assertTrue(sealed.startsWith("mne2e:v1:"))
        assertEquals(text, Vault.open(sealed, vaultKey))
        assertEquals(12 + text.toByteArray().size + 16, Vault.decode(sealed.removePrefix("mne2e:v1:"))!!.size)
    }

    /** Kotlin's own output; the Swift checker opens it (see docs/DECISIONS.md, the Android entry). */
    @Test fun writesVectorsForSwift() {
        val (key, newSalt, newWrapped) = Vault.create(passphrase)
        val json = JSONObject()
            .put("passphrase", passphrase).put("salt", newSalt).put("wrapped", newWrapped)
            .put("derivedHex", hex(Vault.deriveKey(passphrase, Vault.decode(newSalt)!!)))
            .put("vaultKeyHex", hex(key)).put("text", text)
            .put("sealedText", Vault.seal(text, key)).put("sealedEmpty", Vault.seal("", key))
            .put("sealedImage", Vault.b64(Vault.sealBytes(image, key)))
        File("build/kotlin-vectors.json").writeText(json.toString(2))
        assertArrayEquals(key, Vault.unwrap(passphrase, newSalt, newWrapped))
    }

    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun hexBytes(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
