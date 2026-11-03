package com.memorynotes.android

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * This device's copy: every note and folder (deleted ones too, as tombstones for sync) plus sync values (user,
 * cursors), in one JSON file in app-private storage. Same rules as NoteStore's sync side on the Mac.
 */
class Store(private val file: File?, private val onChange: () -> Unit = {}) {
    private val notes = LinkedHashMap<String, Note>()
    private val folders = LinkedHashMap<String, Folder>()
    private val values = HashMap<String, String>()

    init {
        file?.takeIf { it.exists() }?.let { load(JSONObject(it.readText())) }
    }

    @Synchronized fun liveNotes(): List<Note> = notes.values.filter { it.deletedAt == null }
    @Synchronized fun liveFolders(): List<Folder> = folders.values.filter { it.deletedAt == null }.sortedBy { it.name.lowercase() }
    @Synchronized fun note(id: String): Note? = notes[id]?.takeIf { it.deletedAt == null }
    @Synchronized fun value(key: String): String? = values[key]

    @Synchronized fun setValue(key: String, value: String) {
        values[key] = value
        persist()
    }

    /** Typing: a new note on its first text; an unchanged, locked or deleted note is left alone. */
    @Synchronized fun edit(id: String, text: String, now: Double = now()) {
        val old = notes[id]
        if (old == null) {
            if (text.isEmpty()) return
            notes[id] = Note(id = id, text = text, createdAt = now, updatedAt = now, dirty = true)
        } else {
            if (old.locked || old.deletedAt != null || old.text == text) return
            notes[id] = old.copy(text = text, updatedAt = maxOf(now, old.updatedAt + 1), dirty = true)
        }
        changed()
    }

    @Synchronized fun delete(id: String, now: Double = now()) {
        val old = notes[id] ?: return
        if (old.deletedAt != null || old.locked) return
        notes[id] = old.copy(deletedAt = now, updatedAt = maxOf(now, old.updatedAt + 1), dirty = true)
        changed()
    }

    @Synchronized fun dirtyNotes(limit: Int = 200) = notes.values.filter { it.dirty }.take(limit)
    @Synchronized fun dirtyFolders() = folders.values.filter { it.dirty }

    /** After a push: clean only rows nobody edited meanwhile. */
    @Synchronized fun markPushed(pushedNotes: List<Note> = emptyList(), pushedFolders: List<Folder> = emptyList()) {
        for (n in pushedNotes) notes[n.id]?.takeIf { it.updatedAt == n.updatedAt }?.let { notes[n.id] = it.copy(dirty = false) }
        for (f in pushedFolders) folders[f.id]?.takeIf { it.updatedAt == f.updatedAt }?.let { folders[f.id] = it.copy(dirty = false) }
        persist()
    }

    /** Pulled rows (already opened): the newer edit wins and deletes stick, as on the server (NoteStore.applyRemote). */
    @Synchronized fun applyRemote(remoteNotes: List<Note>, remoteFolders: List<Folder>) {
        for (f in remoteFolders) {
            if (!validID(f.id)) continue
            val old = folders[f.id]
            if (old == null || f.updatedAt > old.updatedAt) {
                folders[f.id] = f.copy(deletedAt = old?.deletedAt ?: f.deletedAt, dirty = false)
            }
        }
        for (n in remoteNotes) {
            if (!validID(n.id) || n.kind !in setOf("app", "url")) continue
            val old = notes[n.id]
            if (old == null || n.updatedAt > old.updatedAt) {
                notes[n.id] = n.copy(createdAt = old?.createdAt ?: n.createdAt, deletedAt = old?.deletedAt ?: n.deletedAt, dirty = false)
            } else if (n.deletedAt != null && old.deletedAt == null) {
                notes[n.id] = old.copy(deletedAt = n.deletedAt)  // deleted elsewhere, even if edited here later
            }
        }
        changed()
    }

    /** Signing in to another account than last time: send it everything, fetch all of its notes (NoteStore.resetSync). */
    @Synchronized fun startAccount(userID: String) {
        if (values["user"] == userID) return
        notes.replaceAll { _, n -> n.copy(dirty = true) }
        folders.replaceAll { _, f -> f.copy(dirty = true) }
        values.keys.removeAll { it.startsWith("cursor.") }
        values["user"] = userID
        persist()
    }

    private fun changed() {
        persist()
        onChange()
    }

    private fun persist() {
        file ?: return
        val json = JSONObject()
            .put("notes", JSONArray(notes.values.map { it.toLocal() }))
            .put("folders", JSONArray(folders.values.map { it.toLocal() }))
            .put("values", JSONObject(values as Map<*, *>))
        // Write then rename, so a crash mid-write can't leave half a file.
        val tmp = File(file.path + ".tmp")
        tmp.writeText(json.toString())
        if (!tmp.renameTo(file)) throw java.io.IOException("Couldn't save notes")
    }

    private fun load(json: JSONObject) {
        json.optJSONArray("notes")?.let { a -> for (i in 0 until a.length()) a.getJSONObject(i).localNote().let { notes[it.id] = it } }
        json.optJSONArray("folders")?.let { a -> for (i in 0 until a.length()) a.getJSONObject(i).localFolder().let { folders[it.id] = it } }
        json.optJSONObject("values")?.let { v -> v.keys().forEach { values[it] = v.getString(it) } }
    }

    companion object {
        fun now() = System.currentTimeMillis().toDouble()
        fun newID() = UUID.randomUUID().toString()  // lowercase, as Postgres returns uuids
        fun validID(id: String) = id.isNotEmpty() && id.all { it in "0123456789abcdefABCDEF-" }
    }
}

// Local file format: the server's columns plus `dirty`, text in the clear (app-private storage, like the Mac's SQLite).

private fun Note.toLocal() = JSONObject().put("id", id).put("kind", kind).put("target", target).put("label", label)
    .put("text", text).put("created_at", createdAt).put("updated_at", updatedAt).put("deleted_at", deletedAt ?: JSONObject.NULL)
    .put("pinned", pinned).put("folder_id", folderId ?: JSONObject.NULL).put("color", color ?: JSONObject.NULL)
    .put("locked", locked).put("dirty", dirty)

private fun JSONObject.localNote() = Note(
    id = getString("id"), kind = getString("kind"), target = getString("target"), label = getString("label"),
    text = getString("text"), createdAt = getDouble("created_at"), updatedAt = getDouble("updated_at"),
    deletedAt = optDoubleOrNull("deleted_at"), pinned = optBoolean("pinned"), folderId = optStringOrNull("folder_id"),
    color = optStringOrNull("color"), locked = optBoolean("locked"), dirty = optBoolean("dirty"),
)

private fun Folder.toLocal() = JSONObject().put("id", id).put("name", name).put("updated_at", updatedAt)
    .put("deleted_at", deletedAt ?: JSONObject.NULL).put("dirty", dirty)

private fun JSONObject.localFolder() = Folder(
    id = getString("id"), name = getString("name"), updatedAt = getDouble("updated_at"),
    deletedAt = optDoubleOrNull("deleted_at"), dirty = optBoolean("dirty"),
)

fun JSONObject.optDoubleOrNull(key: String): Double? = if (isNull(key)) null else getDouble(key)
fun JSONObject.optStringOrNull(key: String): String? = if (isNull(key)) null else getString(key)

// The wire format: every column on every row (PostgREST takes a batch's columns from its first object, so nulls
// are explicit); text, place, title and folder names sealed with the vault key (SyncCloud.swift's row(sealing:)).

fun Note.row(key: ByteArray): JSONObject = JSONObject()
    .put("id", id).put("kind", kind).put("target", Vault.seal(target, key)).put("label", Vault.seal(label, key))
    .put("body_md", Vault.seal(text, key)).put("created_at", createdAt).put("updated_at", updatedAt)
    .put("deleted_at", deletedAt ?: JSONObject.NULL).put("pinned", pinned).put("folder_id", folderId ?: JSONObject.NULL)
    .put("color", color ?: JSONObject.NULL).put("locked", locked)

fun JSONObject.openedNote(key: ByteArray) = Note(
    id = getString("id").lowercase(), kind = getString("kind"), target = Vault.open(getString("target"), key),
    label = Vault.open(getString("label"), key), text = Vault.open(getString("body_md"), key),
    createdAt = getDouble("created_at"), updatedAt = getDouble("updated_at"), deletedAt = optDoubleOrNull("deleted_at"),
    pinned = optBoolean("pinned"), folderId = optStringOrNull("folder_id")?.lowercase(), color = optStringOrNull("color"),
    locked = optBoolean("locked"),
)

fun Folder.row(key: ByteArray): JSONObject = JSONObject()
    .put("id", id).put("name", Vault.seal(name, key)).put("updated_at", updatedAt).put("deleted_at", deletedAt ?: JSONObject.NULL)

fun JSONObject.openedFolder(key: ByteArray) = Folder(
    id = getString("id").lowercase(), name = Vault.open(getString("name"), key), updatedAt = getDouble("updated_at"),
    deletedAt = optDoubleOrNull("deleted_at"),
)
