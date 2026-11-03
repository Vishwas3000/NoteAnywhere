package com.memorynotes.android

import org.junit.Assert.assertEquals
import org.junit.Test

/** Title and preview rules from Note.swift (title = first non-empty line without Markdown). */
class NoteTest {
    private fun note(text: String) = Note(id = "a", text = text, createdAt = 0.0, updatedAt = 0.0)

    @Test fun titles() {
        assertEquals("New Note", note("").title)
        assertEquals("Groceries", note("\n\n# Groceries\n- milk").title)
        assertEquals("Read the docs", note("- [ ] **Read** the [docs](https://example.com)").title)
        assertEquals("milk eggs", note("Shopping\n\n- milk\n* eggs").preview)
        assertEquals("let x = 1", note("```swift\nlet x = 1\n```").title)
        assertEquals("Real title", note("↖ [Back](note://abc)\nReal title").title)
        assertEquals("2 * 3 is italic-free", note("2 * 3 is italic-free").title)
        assertEquals("a  b", note("| a | b |").title)
    }

    @Test fun lockedNotesShowNoText() {
        val locked = note("mnlock:v1:AAAA").copy(locked = true)
        assertEquals("Locked Note", locked.title)
        assertEquals("", locked.preview)
    }
}
