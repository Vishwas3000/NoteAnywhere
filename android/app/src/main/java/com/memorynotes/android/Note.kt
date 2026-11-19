package com.memorynotes.android

import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** A note as the server stores it (Note.swift's CloudNote); times are milliseconds since 1970. */
data class Note(
    val id: String,
    val kind: String = "url",  // a note with no app or page, like the iPhone's (NotesModel.add)
    val target: String = "",
    val label: String = "",
    val text: String = "",
    val createdAt: Double,
    val updatedAt: Double,
    val deletedAt: Double? = null,
    val pinned: Boolean = false,
    val starred: Boolean = false,  // a favourite: shown under the Starred filter, not moved like pinned
    val folderId: String? = null,
    val color: String? = null,
    val locked: Boolean = false,  // text is a "mnlock:v1:" envelope: shown as locked, never opened or edited here
    val dirty: Boolean = false,  // edited here, not pushed yet
) {
    /** The first line without Markdown, as Note.swift's `title`. */
    val title: String get() = if (locked) "Locked Note" else plainLines(1).firstOrNull() ?: "New Note"
    val preview: String get() = if (locked) "" else plainLines(5).drop(1).joinToString(" ")

    private fun plainLines(limit: Int): List<String> {
        var inFence = false
        val found = mutableListOf<String>()
        for (line in text.split("\n")) {
            if (line.isEmpty()) continue
            if (found.size == limit) break
            if (line.startsWith("```")) { inFence = !inFence; continue }
            if (!inFence && line.startsWith("↖ [") && line.contains("](note://")) continue  // a page's way back
            val plain = if (inFence) line.trim() else plain(line)
            if (plain.isNotEmpty()) found += plain
        }
        return found
    }

    companion object {
        private val markers = Regex("""^\s*(#{1,6}\s+|>\s*(?:\[!bookmark\]\s*)?|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+)*""")
        private val rule = Regex("""^\s*(-{3,}|\*{3,}|_{3,}|\|?[\s:|-]+\|[\s:|-]*)\s*$""")
        private val link = Regex("""!?\[([^\]]*)\]\([^)]*\)""")
        private val emphasis = Regex("""\*\*|__|~~|`""")
        private val italic = Regex("""\*(\S|\S[^*]*\S)\*""")
        private val pipe = Regex("""\s*\|\s*""")
        private val date = Regex("""(?:@|📅\s?)(\d{4}-\d{2}-\d{2})(?![\w-])""")
        private val dayFormat = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)

        /** One line of Markdown as plain text, as Note.plain in Note.swift. */
        fun plain(line: String): String {
            if (line.none { it in "#>-*+_~`[|@" } && !line.contains("📅") && line.trimStart().firstOrNull()?.isDigit() != true) {
                return line.trim()
            }
            return line.replace(markers, "").replace(rule, "")
                .replace(link) { it.groupValues[1] }
                .replace(emphasis, "")
                .replace(italic) { it.groupValues[1] }
                .replace(pipe, "  ")
                // shortcut: the device's medium date, not the Mac's date-format setting.
                .replace(date) { m -> runCatching { LocalDate.parse(m.groupValues[1]).format(dayFormat) }.getOrDefault(m.value) }
                .trim()
        }
    }
}

data class Folder(val id: String, val name: String, val updatedAt: Double, val deletedAt: Double? = null, val dirty: Boolean = false)

/** Colour labels, Chrome's tab-group set (NoteColor in Note.swift). */
val noteColors = mapOf(
    "grey" to 0xFF5F6368, "blue" to 0xFF1A73E8, "red" to 0xFFD93025, "yellow" to 0xFFF9AB00, "green" to 0xFF1E8E3E,
    "pink" to 0xFFD01884, "purple" to 0xFF9334E6, "cyan" to 0xFF007B83, "orange" to 0xFFFA903E,
)
