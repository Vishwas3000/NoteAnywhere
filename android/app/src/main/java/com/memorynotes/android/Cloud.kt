package com.memorynotes.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * Sync through the same Supabase project as the Mac and iPhone (SyncCloud.swift): sign in with the emailed code,
 * open the vault with the sync passphrase, push dirty rows, pull everything after each table's seq cursor.
 */
class Cloud(private val store: Store, private val secrets: Secrets) {
    enum class Step { SignedOut, CodeSent, CheckingVault, CreateVault, EnterVault, Ready }

    var step by mutableStateOf(Step.SignedOut); private set
    var pendingEmail by mutableStateOf<String?>(null); private set
    var email by mutableStateOf<String?>(null); private set
    var busy by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null)

    private var session: Session? = secrets.get("session")?.let { Session(JSONObject(it)) }
    private var vaultKey: ByteArray? = null
    private val syncing = Mutex()
    private val refreshing = Mutex()

    class Failure(message: String, val status: Int = 0) : Exception(message)

    init {
        session?.let { s ->
            email = s.email
            vaultKey = secrets.get("vault-${s.userID}")?.let { Vault.decode(it) }
            step = if (vaultKey != null) Step.Ready else Step.CheckingVault
        }
    }

    // Sign in

    suspend fun sendCode(address: String) = perform {
        val email = address.trim().lowercase()
        auth("otp", JSONObject().put("email", email).put("create_user", true), "redirect_to=" + enc(CALLBACK))
        pendingEmail = email
        step = Step.CodeSent
    }

    suspend fun verify(code: String) = perform {
        val email = pendingEmail ?: return@perform
        signedIn(auth("verify", JSONObject().put("type", "email").put("email", email).put("token", code.filter { it.isDigit() })))
    }

    fun cancelCode() {
        pendingEmail = null
        step = Step.SignedOut
    }

    /** The sign-in link's redirect: memorynotes://auth-callback#access_token=…&refresh_token=…&expires_at=… */
    suspend fun handleLink(link: String) = perform {
        if (!link.startsWith(CALLBACK)) return@perform
        val fields = link.substringAfter('?', "").substringBefore('#').split('&') + link.substringAfter('#', "").split('&')
        val map = fields.filter { '=' in it }.associate { it.substringBefore('=') to URLDecoder.decode(it.substringAfter('='), "UTF-8") }
        map["error_description"]?.let { throw Failure(it) }
        val access = map["access_token"]
        val refresh = map["refresh_token"]
        if (access == null || refresh == null) throw Failure("That sign-in link didn't work. Send a new one.")
        val user = JSONObject(send("GET", "auth/v1/user", token = access))
        signedIn(JSONObject().put("access_token", access).put("refresh_token", refresh).put("user", user)
            .put("expires_at", map["expires_at"]?.toDoubleOrNull()).put("expires_in", map["expires_in"]?.toDoubleOrNull()))
    }

    private suspend fun signedIn(reply: JSONObject) {
        val s = Session(reply)
        store.startAccount(s.userID)
        secrets.set("session", s.json().toString())
        session = s
        email = s.email
        pendingEmail = null
        vaultKey = secrets.get("vault-${s.userID}")?.let { Vault.decode(it) }
        if (vaultKey != null) step = Step.Ready else checkVault()
    }

    /** Stops syncing and forgets the account on this device; notes stay here. */
    fun signOut() {
        session?.let { secrets.set("vault-${it.userID}", null) }
        secrets.set("session", null)
        session = null
        vaultKey = null
        email = null
        step = Step.SignedOut
    }

    // The vault (end-to-end encryption)

    private suspend fun checkVault() {
        step = Step.CheckingVault
        step = if (JSONArray(rest("GET", "vaults?select=salt,wrapped")).length() == 0) Step.CreateVault else Step.EnterVault
    }

    suspend fun recheckVault() = perform { checkVault() }

    suspend fun createVault(passphrase: String) = perform {
        val (key, salt, wrapped) = Vault.create(passphrase)
        // A plain insert: if another device just made the vault, this fails rather than replacing its key.
        try {
            rest("POST", "vaults", JSONArray().put(JSONObject().put("salt", salt).put("wrapped", wrapped)), upsert = false)
        } catch (e: Failure) {
            if (e.status != 409) throw e
            step = Step.EnterVault
            throw Failure("Another device already set a sync passphrase. Enter that one.")
        }
        unlocked(key)
    }

    suspend fun enterVault(passphrase: String) = perform {
        val row = JSONArray(rest("GET", "vaults?select=salt,wrapped")).optJSONObject(0) ?: throw Failure("No vault yet.")
        val key = Vault.unwrap(passphrase, row.getString("salt"), row.getString("wrapped"))
            ?: throw Failure("That passphrase doesn't open your synced notes.")
        unlocked(key)
    }

    // The notes screen syncs as soon as it shows.
    private fun unlocked(key: ByteArray) {
        val s = session ?: return
        secrets.set("vault-${s.userID}", Vault.b64(key))
        vaultKey = key
        step = Step.Ready
    }

    // Sync

    /** Push this device's edits, then (unless only pushing) pull everyone else's. One run at a time. */
    suspend fun sync(pull: Boolean) {
        if (step != Step.Ready) return
        syncing.withLock {
            perform(showBusy = pull) {
                push()
                if (pull) pull()
            }
        }
    }

    private suspend fun push() {
        val key = vaultKey ?: return
        val folders = store.dirtyFolders()  // first: notes point at them
        if (folders.isNotEmpty()) {
            rest("POST", "folders?on_conflict=id", JSONArray(folders.map { it.row(key) }))
            store.markPushed(pushedFolders = folders)
        }
        while (true) {
            val notes = store.dirtyNotes()
            if (notes.isEmpty()) return
            rest("POST", "notes?on_conflict=id", JSONArray(notes.map { it.row(key) }))
            store.markPushed(pushedNotes = notes)
            if (notes.size < 200) return
        }
    }

    // shortcut: snapshots (the calendar's history) and images aren't pulled or pushed; the Mac still makes its own.
    private suspend fun pull() {
        val key = vaultKey ?: return
        while (true) {
            val folders = page("folders", "id,name,updated_at,deleted_at")
            val notes = page("notes", "id,kind,target,label,body_md,created_at,updated_at,deleted_at,pinned,starred,folder_id,color,locked")
            store.applyRemote(notes.map { it.openedNote(key) }, folders.map { it.openedFolder(key) })
            folders.lastOrNull()?.let { store.setValue("cursor.folders", it.getLong("seq").toString()) }
            notes.lastOrNull()?.let { store.setValue("cursor.notes", it.getLong("seq").toString()) }
            if (notes.size < 500 && folders.size < 500) return
        }
    }

    private suspend fun page(table: String, columns: String): List<JSONObject> {
        val cursor = store.value("cursor.$table") ?: "0"
        val rows = JSONArray(rest("GET", "$table?select=$columns,seq&seq=gt.$cursor&order=seq.asc&limit=500"))
        return (0 until rows.length()).map { rows.getJSONObject(it) }
    }

    private suspend fun perform(showBusy: Boolean = true, work: suspend () -> Unit) {
        if (showBusy) busy = true
        try {
            withContext(Dispatchers.IO) { work() }
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: e.toString()
        } finally {
            if (showBusy) busy = false
        }
    }

    // HTTP

    private suspend fun auth(path: String, body: JSONObject, query: String = ""): JSONObject =
        JSONObject(send("POST", "auth/v1/$path" + (if (query.isEmpty()) "" else "?$query"), body.toString()).ifEmpty { "{}" })

    private suspend fun rest(method: String, path: String, body: JSONArray? = null, upsert: Boolean = true): String {
        val prefer = if (body == null) null else if (upsert) "resolution=merge-duplicates,return=minimal" else "return=minimal"
        return send(method, "rest/v1/$path", body?.toString(), accessToken(), prefer)
    }

    private fun send(method: String, path: String, body: String? = null, token: String? = null, prefer: String? = null): String {
        val c = URL("$PROJECT_URL/$path").openConnection() as HttpURLConnection
        try {
            c.requestMethod = method
            c.connectTimeout = 30_000
            c.readTimeout = 30_000
            c.setRequestProperty("apikey", PUBLISHABLE_KEY)
            c.setRequestProperty("Content-Type", "application/json")
            token?.let { c.setRequestProperty("Authorization", "Bearer $it") }
            prefer?.let { c.setRequestProperty("Prefer", it) }
            if (body != null) {
                c.doOutput = true
                c.outputStream.use { it.write(body.toByteArray()) }
            }
            val status = c.responseCode
            val text = (if (status in 200..299) c.inputStream else c.errorStream)?.use { String(it.readBytes()) } ?: ""
            if (status !in 200..299) {
                val json = runCatching { JSONObject(text) }.getOrNull()
                val message = listOf("msg", "message", "error_description", "error").firstNotNullOfOrNull { json?.optString(it)?.ifEmpty { null } }
                if ((status == 401 || status == 403) && message?.contains("JWT") == true) {
                    secrets.set("session", null)
                    session = null
                    step = Step.SignedOut
                }
                throw Failure(message ?: "The sync server answered $status.", status)
            }
            return text
        } finally {
            c.disconnect()
        }
    }

    /** A valid access token, refreshed a minute before it expires. */
    private suspend fun accessToken(): String = refreshing.withLock {
        var s = session ?: throw Failure("Sign in to sync.")
        if (s.expiresAt - 60 < System.currentTimeMillis() / 1000.0) {
            s = Session(auth("token", JSONObject().put("refresh_token", s.refreshToken), "grant_type=refresh_token"))
            secrets.set("session", s.json().toString())
            session = s
        }
        s.accessToken
    }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    companion object {
        const val PROJECT_URL = "https://strhaqnvxtpmlvcwkkne.supabase.co"
        /** Publishable (anon) key: meant to ship in apps; row level security keeps each account's notes to itself. */
        const val PUBLISHABLE_KEY = "sb_publishable_9GowTlVr_z6p3W1d2W-28g_M0Ke1Mzv"
        const val CALLBACK = "memorynotes://auth-callback"
    }
}

private class Session(val accessToken: String, val refreshToken: String, val expiresAt: Double, val userID: String, val email: String) {
    /** An auth reply ({access_token, refresh_token, expires_at|expires_in, user}) or our own saved form. */
    constructor(r: JSONObject) : this(
        r.optString("access_token").ifEmpty { null } ?: fail(),
        r.optString("refresh_token").ifEmpty { null } ?: fail(),
        if (r.has("expires_at") && !r.isNull("expires_at")) r.getDouble("expires_at")
        else System.currentTimeMillis() / 1000.0 + r.optDouble("expires_in", 3600.0).let { if (it.isNaN()) 3600.0 else it },
        r.optJSONObject("user")?.optString("id")?.ifEmpty { null } ?: fail(),
        r.optJSONObject("user")?.optString("email") ?: "",
    )

    fun json(): JSONObject = JSONObject().put("access_token", accessToken).put("refresh_token", refreshToken)
        .put("expires_at", expiresAt).put("user", JSONObject().put("id", userID).put("email", email))
}

private fun fail(): Nothing = throw Cloud.Failure("That code didn't work. Check it, or send a new one.")
