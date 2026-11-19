package com.memorynotes.android

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.DateFormat
import java.util.Date

/** One store and one sync client for the process, so rotating the screen keeps both. */
object App {
    lateinit var store: Store
    lateinit var cloud: Cloud
    val scope = MainScope()
    var version by mutableIntStateOf(0)  // bumped on every store change; the list recomposes
    private var pending: Pair<String, String>? = null  // the open editor's unsaved text
    private var saveSoon: Job? = null
    private var pushSoon: Job? = null

    fun start(context: Context) {
        if (::store.isInitialized) return
        store = Store(File(context.filesDir, "notes.json")) { version++ }
        cloud = Cloud(store, Secrets(context))
    }

    /** Typing: saved here a moment after it stops, pushed a little later (the Mac waits 2 s too). */
    fun typed(id: String, text: String) {
        pending = id to text
        saveSoon?.cancel()
        saveSoon = scope.launch { delay(500); flush() }
    }

    fun flush() {
        val (id, text) = pending ?: return
        pending = null
        store.edit(id, text)
        pushSoon?.cancel()
        pushSoon = scope.launch { delay(2000); cloud.sync(pull = false) }
    }

    fun delete(id: String) {
        store.delete(id)
        scope.launch { cloud.sync(pull = false) }
    }

    /** Pin, star or colour (Store.setMeta), after any unsaved typing; pushed right away like a delete. */
    fun setMeta(id: String, change: (Note) -> Note) {
        flush()
        store.setMeta(id, change)
        scope.launch { cloud.sync(pull = false) }
    }

    fun duplicate(id: String): String? {
        flush()
        return store.duplicate(id)?.also { scope.launch { cloud.sync(pull = false) } }
    }
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        App.start(applicationContext)
        handle(intent)
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) { Root() }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onStart() {
        super.onStart()
        App.scope.launch { App.cloud.sync(pull = true) }
    }

    override fun onStop() {
        App.flush()
        App.scope.launch { App.cloud.sync(pull = false) }
        super.onStop()
    }

    private fun handle(intent: Intent?) {
        val link = intent?.dataString ?: return
        if (link.startsWith(Cloud.CALLBACK)) App.scope.launch { App.cloud.handleLink(link) }
    }
}

@Composable
private fun Root() {
    val cloud = App.cloud
    Scaffold { padding ->
        Box(Modifier.padding(padding).imePadding().fillMaxSize()) {
            when (cloud.step) {
                Cloud.Step.SignedOut, Cloud.Step.CodeSent -> SignIn()
                Cloud.Step.CheckingVault -> CheckingVault()
                Cloud.Step.CreateVault, Cloud.Step.EnterVault -> VaultScreen()
                Cloud.Step.Ready -> Notes()
            }
        }
    }
}

@Composable
private fun Form(content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("NoteAnywhere", style = MaterialTheme.typography.headlineMedium)
        content()
        App.cloud.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (App.cloud.busy) CircularProgressIndicator()
    }
}

@Composable
private fun SignIn() {
    val cloud = App.cloud
    val scope = rememberCoroutineScope()
    var email by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    Form {
        if (cloud.step == Cloud.Step.SignedOut) {
            Text("Sign in with the account you sync your Mac or iPhone with. We'll email you a code.")
            OutlinedTextField(email, { email = it }, Modifier.fillMaxWidth(), label = { Text("Email") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email))
            Button({ scope.launch { cloud.sendCode(email) } }, enabled = email.contains('@') && !cloud.busy) { Text("Send code") }
        } else {
            Text("Enter the code sent to ${cloud.pendingEmail}, or tap the link in that email on this phone.")
            OutlinedTextField(code, { code = it }, Modifier.fillMaxWidth(), label = { Text("Code") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button({ scope.launch { cloud.verify(code) } }, enabled = code.any { it.isDigit() } && !cloud.busy) { Text("Sign in") }
                TextButton({ code = ""; cloud.cancelCode() }) { Text("Use another email") }
            }
        }
    }
}

@Composable
private fun CheckingVault() {
    val cloud = App.cloud
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { cloud.recheckVault() }
    Form {
        Text("Checking your sync passphrase…")
        if (cloud.error != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button({ scope.launch { cloud.recheckVault() } }) { Text("Try again") }
                TextButton({ cloud.signOut() }) { Text("Sign out") }
            }
        }
    }
}

@Composable
private fun VaultScreen() {
    val cloud = App.cloud
    val scope = rememberCoroutineScope()
    val creating = cloud.step == Cloud.Step.CreateVault
    var passphrase by remember { mutableStateOf("") }
    var again by remember { mutableStateOf("") }
    Form {
        Text(
            if (creating) "Choose a sync passphrase. Your notes are encrypted with it before they leave this phone; " +
                "your other devices ask for it once. It can't be recovered if you forget it."
            else "Enter the sync passphrase you set on your Mac or iPhone."
        )
        Text("Signed in as ${cloud.email}", style = MaterialTheme.typography.bodySmall)
        OutlinedTextField(passphrase, { passphrase = it }, Modifier.fillMaxWidth(), label = { Text("Sync passphrase") },
            singleLine = true, visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        if (creating) {
            OutlinedTextField(again, { again = it }, Modifier.fillMaxWidth(), label = { Text("Again") },
                singleLine = true, visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                { scope.launch { if (creating) cloud.createVault(passphrase) else cloud.enterVault(passphrase) } },
                enabled = passphrase.isNotEmpty() && (!creating || passphrase == again) && !cloud.busy,
            ) { Text(if (creating) "Set passphrase" else "Unlock") }
            TextButton({ cloud.signOut() }) { Text("Sign out") }
        }
    }
}

@Composable
private fun Notes() {
    var open by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { App.cloud.sync(pull = true) }
    val id = open
    if (id == null) NotesList(onOpen = { open = it }) else {
        BackHandler { open = null }
        Editor(id, onClose = { open = null }, onOpen = { open = it })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NotesList(onOpen: (String) -> Unit) {
    val cloud = App.cloud
    val scope = rememberCoroutineScope()
    var query by rememberSaveable { mutableStateOf("") }
    var folder by rememberSaveable { mutableStateOf<String?>(null) }
    var starred by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    val folders = App.version.let { App.store.liveFolders() }  // reading version re-reads the store when it changes
    val folderNames = folders.associate { it.id to it.name }
    val notes = App.store.liveNotes()
        .filter { folder == null || it.folderId == folder }
        .filter { !starred || it.starred }
        .filter { query.isBlank() || (it.title + "\n" + if (it.locked) "" else it.text).contains(query.trim(), ignoreCase = true) }
        .sortedByDescending { it.updatedAt }
    val (pinned, rest) = notes.partition { it.pinned }

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Notes") }, actions = {
                TextButton({ menu = true }) { Text("⋮", style = MaterialTheme.typography.titleLarge) }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text("Sign out ${cloud.email ?: ""}") }, { menu = false; cloud.signOut() })
                }
            })
        },
        floatingActionButton = {
            FloatingActionButton({ onOpen(Store.newID()) }) { Text("+", style = MaterialTheme.typography.headlineSmall) }
        },
    ) { padding ->
        Column(Modifier.padding(padding)) {
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                placeholder = { Text("Search") }, singleLine = true)
            LazyRow(Modifier.padding(vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                item { Spacer(Modifier.width(8.dp)) }
                item { FilterChip(folder == null && !starred, { folder = null; starred = false }, { Text("All Notes") }) }
                item { FilterChip(starred, { folder = null; starred = true }, { Text("⭐ Starred") }) }
                items(folders, key = { it.id }) { f -> FilterChip(folder == f.id, { folder = f.id; starred = false }, { Text(f.name) }) }
            }
            cloud.error?.let { Text(it, Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error) }
            PullToRefreshBox(cloud.busy, { scope.launch { cloud.sync(pull = true) } }, Modifier.fillMaxSize()) {
                LazyColumn(Modifier.fillMaxSize()) {
                    if (notes.isEmpty()) item {
                        Text(if (query.isNotBlank()) "No matches." else if (starred) "No starred notes." else "No notes yet.",
                            Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (pinned.isNotEmpty()) {
                        item { Section("Pinned") }
                        items(pinned, key = { it.id }) { note -> NoteRow(note, folderNames[note.folderId], onOpen) }
                        if (rest.isNotEmpty()) item { Section("Notes") }
                    }
                    items(rest, key = { it.id }) { note -> NoteRow(note, folderNames[note.folderId], onOpen) }
                }
            }
        }
    }
}

@Composable
private fun Section(title: String) {
    Text(title, Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp), style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun NoteRow(note: Note, folder: String?, onOpen: (String) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    // Long press: the note's menu (pin, star, colour, duplicate, share), anchored to the row.
    Box(Modifier.fillMaxWidth().combinedClickable(onLongClick = { menu = true }) { onOpen(note.id) }) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            val color = noteColors[note.color]
            Box(Modifier.size(10.dp).background(if (color != null) Color(color) else Color.Transparent, CircleShape))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text((if (note.pinned) "📌 " else "") + (if (note.starred) "⭐ " else "") + (if (note.locked) "🔒 " else "") +
                    note.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val details = listOfNotNull(DateFormat.getDateInstance(DateFormat.SHORT).format(Date(note.updatedAt.toLong())),
                    folder, note.preview.ifEmpty { null }).joinToString("  ·  ")
                Text(details, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        NoteMenu(note.id, menu, { menu = false }, onOpen)
    }
    HorizontalDivider()
}

/** Pin, star, colour, duplicate and share; a locked note gets only the first three (its text never leaves it). */
@Composable
private fun NoteMenu(id: String, expanded: Boolean, onDismiss: () -> Unit, onOpen: (String) -> Unit) {
    val note = App.version.let { App.store.note(id) } ?: return  // a new note has no menu until its first text is saved
    val context = LocalContext.current
    var colors by remember { mutableStateOf(false) }
    val close = { colors = false; onDismiss() }
    DropdownMenu(expanded, close) {
        if (colors) {
            DropdownMenuItem({ Text("No Colour") }, { close(); App.setMeta(id) { it.copy(color = null) } })
            for ((name, argb) in noteColors) {
                DropdownMenuItem({ Text(name.replaceFirstChar { it.uppercase() }) }, { close(); App.setMeta(id) { it.copy(color = name) } },
                    leadingIcon = { Box(Modifier.size(12.dp).background(Color(argb), CircleShape)) })
            }
        } else {
            DropdownMenuItem({ Text(if (note.pinned) "Unpin" else "Pin") }, { close(); App.setMeta(id) { it.copy(pinned = !it.pinned) } })
            DropdownMenuItem({ Text(if (note.starred) "Unstar" else "Star") }, { close(); App.setMeta(id) { it.copy(starred = !it.starred) } })
            DropdownMenuItem({ Text("Colour…") }, { colors = true })
            if (!note.locked) {
                DropdownMenuItem({ Text("Duplicate") }, { close(); App.duplicate(id)?.let(onOpen) })
                DropdownMenuItem({ Text("Share") }, {
                    close()
                    App.flush()  // share what's typed, not what was last saved
                    App.store.note(id)?.takeIf { !it.locked }?.let { n ->
                        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, n.text)
                        context.startActivity(Intent.createChooser(send, null))
                    }
                })
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Editor(id: String, onClose: () -> Unit, onOpen: (String) -> Unit) {
    val note = remember(id) { App.store.note(id) }
    var text by remember(id) { mutableStateOf(note?.text ?: "") }
    var confirmDelete by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    DisposableEffect(id) { onDispose { App.flush() } }

    Scaffold(topBar = {
        TopAppBar(
            title = {},
            navigationIcon = { TextButton(onClose) { Text("‹ Notes") } },
            actions = {
                if (note != null && !note.locked) TextButton({ confirmDelete = true }) { Text("Delete") }
                Box {
                    TextButton({ App.flush(); menu = true }) { Text("⋮", style = MaterialTheme.typography.titleLarge) }
                    NoteMenu(id, menu, { menu = false }, onOpen)
                }
            },
        )
    }) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            if (note?.locked == true) {
                Text("This note is locked. Open it on your Mac or iPhone to read it.", Modifier.padding(16.dp))
            } else {
                // Raw Markdown, exactly as stored: what isn't typed over goes back unchanged.
                BasicTextField(
                    text, { text = it; App.typed(id, it) },
                    Modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState()),
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    decorationBox = { inner ->
                        if (text.isEmpty()) Text("Write in Markdown…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        inner()
                    },
                )
            }
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete this note?") },
            text = { Text("It's deleted on your other devices too.") },
            confirmButton = { TextButton({ confirmDelete = false; App.delete(id); onClose() }) { Text("Delete") } },
            dismissButton = { TextButton({ confirmDelete = false }) { Text("Cancel") } },
        )
    }
}
