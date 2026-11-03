package com.memorynotes.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The session and vault keys, never in plain prefs: one small JSON sealed with an AES key that stays inside the
 * Android Keystore (the Keychain's role on the Mac and iPhone).
 */
// Not EncryptedSharedPreferences: androidx.security-crypto is deprecated, and this is the same thing in a few lines.
class Secrets(context: Context) {
    private val file = File(context.filesDir, "secrets.bin")

    @Synchronized fun get(name: String): String? = read().optStringOrNull(name)

    @Synchronized fun set(name: String, value: String?) {
        val json = read()
        if (value == null) json.remove(name) else json.put(name, value)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val tmp = File(file.path + ".tmp")
        tmp.writeBytes(cipher.iv + cipher.doFinal(json.toString().toByteArray()))
        if (!tmp.renameTo(file)) throw java.io.IOException("Couldn't save the sign-in")
    }

    private fun read(): JSONObject {
        if (!file.exists()) return JSONObject()
        val data = file.readBytes()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data, 0, 12))
        return JSONObject(String(cipher.doFinal(data, 12, data.size - 12)))
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as SecretKey?)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private companion object { const val ALIAS = "noteanywhere-secrets" }
}
