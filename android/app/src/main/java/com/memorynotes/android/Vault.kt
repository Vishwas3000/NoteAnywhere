package com.memorynotes.android

import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The sync encryption, byte for byte as the Mac and iPhone do it (SyncCloud.swift's SyncVault, NoteLock.key):
 * AES-256-GCM "combined" = 12-byte nonce | ciphertext | 16-byte tag; fields are "mne2e:v1:" + base64(combined),
 * image bytes are the bare combined form; the vault key is wrapped under PBKDF2-SHA256(passphrase, salt).
 */
object Vault {
    const val PREFIX = "mne2e:v1:"
    const val LOCK_PREFIX = "mnlock:v1:"  // a locked note's text; never opened here
    private const val ITERATIONS = 310_000
    private val random = SecureRandom()

    class Failure(message: String) : Exception(message)

    /** PBKDF2-HMAC-SHA256 over the passphrase's UTF-8 bytes, one 32-byte block. */
    // Hand-rolled so the password bytes are UTF-8 on every provider (Android's SecretKeyFactory may differ).
    fun deriveKey(passphrase: String, salt: ByteArray): ByteArray {
        require(passphrase.isNotEmpty()) { "Empty passphrase" }  // SecretKeySpec refuses an empty key
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(passphrase.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        mac.update(salt)
        mac.update(byteArrayOf(0, 0, 0, 1))
        val u = mac.doFinal()
        val out = u.copyOf()
        repeat(ITERATIONS - 1) {
            mac.update(u)
            mac.doFinal(u, 0)
            for (i in out.indices) out[i] = (out[i].toInt() xor u[i].toInt()).toByte()
        }
        return out
    }

    fun randomBytes(count: Int) = ByteArray(count).also { random.nextBytes(it) }

    fun sealBytes(plain: ByteArray, key: ByteArray): ByteArray {
        val nonce = randomBytes(12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return nonce + cipher.doFinal(plain)  // doFinal is ciphertext | tag
    }

    /** Null when the key is wrong or the box is damaged. */
    fun openBytes(combined: ByteArray, key: ByteArray): ByteArray? {
        if (combined.size < 12 + 16) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, combined, 0, 12))
            cipher.doFinal(combined, 12, combined.size - 12)
        } catch (e: java.security.GeneralSecurityException) {
            null
        }
    }

    fun seal(text: String, key: ByteArray): String =
        PREFIX + Base64.getEncoder().encodeToString(sealBytes(text.toByteArray(Charsets.UTF_8), key))

    fun open(text: String, key: ByteArray): String {
        val data = if (text.startsWith(PREFIX)) decode(text.substring(PREFIX.length)) else null
        val plain = data?.let { openBytes(it, key) } ?: throw Failure("A synced note can't be read with this passphrase.")
        return String(plain, Charsets.UTF_8)
    }

    /** First device: a new random vault key and what the server keeps of it (salt, wrapped), both base64. */
    fun create(passphrase: String): Triple<ByteArray, String, String> {
        val key = randomBytes(32)
        val salt = randomBytes(16)
        val wrapped = sealBytes(key, deriveKey(passphrase, salt))
        return Triple(key, b64(salt), b64(wrapped))
    }

    /** Null when the passphrase is wrong. */
    fun unwrap(passphrase: String, salt: String, wrapped: String): ByteArray? {
        val s = decode(salt) ?: return null
        val w = decode(wrapped) ?: return null
        return openBytes(w, deriveKey(passphrase, s))?.takeIf { it.size == 32 }
    }

    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    fun decode(text: String): ByteArray? = try { Base64.getDecoder().decode(text) } catch (e: IllegalArgumentException) { null }
}
