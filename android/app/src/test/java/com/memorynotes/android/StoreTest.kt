package com.memorynotes.android

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class StoreTest {
    private val id = "3f1c2a9e-0000-4000-8000-000000000001"
    private val key = ByteArray(32) { it.toByte() }
    private fun remote(updated: Double, text: String = "remote", deleted: Double? = null, locked: Boolean = false) =
        Note(id = id, text = text, createdAt = 1.0, updatedAt = updated, deletedAt = deleted, locked = locked,
            target = "github.com/demo", label = "Demo", pinned = true, folderId = "f0", color = "blue")

    @Test fun newerWinsOlderIsIgnored() {
        val store = Store(null)
        store.applyRemote(listOf(remote(100.0)), emptyList())
        store.applyRemote(listOf(remote(50.0, "stale")), emptyList())
        assertEquals("remote", store.note(id)!!.text)
        store.edit(id, "mine", now = 200.0)
        assertTrue(store.note(id)!!.dirty)
        store.applyRemote(listOf(remote(150.0, "older edit elsewhere")), emptyList())
        assertEquals("mine", store.note(id)!!.text)
        store.applyRemote(listOf(remote(300.0, "newer edit elsewhere")), emptyList())
        assertEquals("newer edit elsewhere", store.note(id)!!.text)
        assertFalse(store.note(id)!!.dirty)
    }

    @Test fun deletesStick() {
        val store = Store(null)
        store.applyRemote(listOf(remote(100.0)), emptyList())
        store.edit(id, "edited here", now = 500.0)
        store.applyRemote(listOf(remote(200.0, deleted = 200.0)), emptyList())
        assertNull(store.note(id))
        store.applyRemote(listOf(remote(900.0, "revived?")), emptyList())
        assertNull(store.note(id))
    }

    @Test fun editKeepsEveryOtherFieldAndSkipsNoChange() {
        val store = Store(null)
        store.applyRemote(listOf(remote(100.0)), emptyList())
        store.edit(id, "remote", now = 200.0)
        assertFalse(store.note(id)!!.dirty)  // opening and leaving a note changes nothing
        store.edit(id, "typed", now = 200.0)
        assertEquals(remote(200.0, "typed").copy(dirty = true), store.note(id))
    }

    @Test fun lockedNotesAreNeverEditedOrDeleted() {
        val store = Store(null)
        val envelope = "mnlock:v1:AAAA"
        store.applyRemote(listOf(remote(100.0, envelope, locked = true)), emptyList())
        store.edit(id, "overwrite", now = 200.0)
        store.delete(id, now = 200.0)
        assertEquals(envelope, store.note(id)!!.text)
        assertEquals("Locked Note", store.note(id)!!.title)
        assertTrue(store.dirtyNotes().isEmpty())
    }

    @Test fun markPushedKeepsLaterEditsDirty() {
        val store = Store(null)
        store.edit(id, "one", now = 100.0)
        val pushed = store.dirtyNotes()
        store.edit(id, "two", now = 200.0)
        store.markPushed(pushedNotes = pushed)
        assertTrue(store.note(id)!!.dirty)
        store.markPushed(pushedNotes = store.dirtyNotes())
        assertFalse(store.note(id)!!.dirty)
    }

    @Test fun anotherAccountGetsEverything() {
        val store = Store(null)
        store.startAccount("user-a")
        store.applyRemote(listOf(remote(100.0)), emptyList())
        store.setValue("cursor.notes", "42")
        store.startAccount("user-a")
        assertEquals("42", store.value("cursor.notes"))
        store.startAccount("user-b")
        assertNull(store.value("cursor.notes"))
        assertTrue(store.note(id)!!.dirty)
    }

    @Test fun badRowsAreSkipped() {
        val store = Store(null)
        store.applyRemote(listOf(remote(1.0).copy(id = "not an id"), remote(1.0).copy(kind = "other")), emptyList())
        assertTrue(store.liveNotes().isEmpty())
    }

    @Test fun fileRoundTrips() {
        val file = File.createTempFile("notes", ".json").apply { delete() }
        val store = Store(file)
        store.applyRemote(listOf(remote(100.0, "a\nb ünï 🎉")), listOf(Folder("f0", "Work", 5.0)))
        store.setValue("cursor.notes", "7")
        val again = Store(file)
        assertEquals(store.note(id), again.note(id))
        assertEquals(listOf(Folder("f0", "Work", 5.0)), again.liveFolders())
        assertEquals("7", again.value("cursor.notes"))
        file.delete()
    }

    @Test fun rowsCarryEveryColumnSealed() {
        val note = remote(1761700000123.456).copy(folderId = null, color = null)
        val row = note.row(key)
        assertEquals(setOf("id", "kind", "target", "label", "body_md", "created_at", "updated_at", "deleted_at",
            "pinned", "folder_id", "color", "locked"), row.keys().asSequence().toSet())
        assertTrue(row.isNull("deleted_at") && row.isNull("folder_id") && row.isNull("color"))
        for (field in listOf("target", "label", "body_md")) assertTrue(row.getString(field).startsWith("mne2e:v1:"))
        assertFalse(row.toString().contains("github.com/demo"))
        // Through the JSON text and back, as a pull would see it.
        assertEquals(note, JSONObject(row.toString()).openedNote(key))
        val folder = Folder("f0", "Work", 5.0)
        assertEquals(folder, JSONObject(folder.row(key).toString()).openedFolder(key))
    }

    @Test fun pulledIdsAreLowercased() {
        val row = remote(1.0).copy(id = id.uppercase()).row(key)
        assertEquals(id, row.openedNote(key).id)
    }
}
