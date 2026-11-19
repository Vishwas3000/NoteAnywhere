package com.memorynotes.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** The app's version, from the repo's VERSION file (build.gradle.kts). */
fun appVersion(context: Context): String =
    context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "?"

/**
 * Sends a problem or a suggestion to the developer without leaving the app: noteanywhere.app/api/feedback emails it
 * (the website's worker, in the private site repo; D72). A failed send keeps the text and offers the email app instead.
 */
@Composable
fun FeedbackDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val about = "NoteAnywhere ${appVersion(context)}, Android ${Build.VERSION.RELEASE}"
    var problem by rememberSaveable { mutableStateOf(true) }
    var message by rememberSaveable { mutableStateOf("") }
    var email by rememberSaveable { mutableStateOf("") }
    var sending by rememberSaveable { mutableStateOf(false) }
    var sent by rememberSaveable { mutableStateOf(false) }
    var error by rememberSaveable { mutableStateOf<String?>(null) }

    if (sent) {
        AlertDialog(onDismiss, confirmButton = { TextButton(onDismiss) { Text("Done") } },
            title = { Text("Feedback sent") }, text = { Text("Thank you.") })
        return
    }
    AlertDialog(
        onDismissRequest = { if (!sending) onDismiss() },
        title = { Text("Send feedback") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(problem, { problem = true }, { Text("Problem") })
                    FilterChip(!problem, { problem = false }, { Text("Suggestion") })
                }
                OutlinedTextField(message, { message = it.take(5000) }, Modifier.fillMaxWidth().heightIn(min = 120.dp),
                    label = { Text(if (problem) "What went wrong?" else "What would make it better?") })
                OutlinedTextField(email, { email = it }, Modifier.fillMaxWidth(), singleLine = true,
                    label = { Text("Your email, for a reply (optional)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email))
                Text("Sent with $about.", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                error?.let {
                    Text(it, color = MaterialTheme.colorScheme.error)
                    TextButton({
                        context.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:timeupvishwa@gmail.com"))
                            .putExtra(Intent.EXTRA_SUBJECT, "NoteAnywhere " + if (problem) "problem" else "suggestion")
                            .putExtra(Intent.EXTRA_TEXT, "$message\n\n--\n$about"))
                    }) { Text("Email instead") }
                }
            }
        },
        confirmButton = {
            TextButton({
                sending = true
                error = null
                scope.launch {
                    error = sendFeedback(if (problem) "problem" else "idea", message, email.trim(), about)
                    sending = false
                    sent = error == null
                }
            }, enabled = message.isNotBlank() && !sending) { Text(if (sending) "Sending…" else "Send") }
        },
        dismissButton = { TextButton(onDismiss, enabled = !sending) { Text("Cancel") } },
    )
}

/** Posts the feedback; null when it was sent, else what went wrong in words. */
suspend fun sendFeedback(kind: String, message: String, email: String, about: String): String? =
    withContext(Dispatchers.IO) {
        try {
            val c = URL("https://noteanywhere.app/api/feedback").openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.connectTimeout = 15_000
            c.readTimeout = 20_000
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            val body = JSONObject().put("kind", kind).put("message", message).put("email", email).put("app", about)
            c.outputStream.use { it.write(body.toString().toByteArray()) }
            val code = c.responseCode
            if (code == 200) return@withContext null
            val reason = runCatching { JSONObject(c.errorStream.bufferedReader().readText()).optString("error") }.getOrNull()
            reason?.ifEmpty { null } ?: "The feedback server answered $code. Try again, or email instead."
        } catch (e: Exception) {
            "Couldn't reach noteanywhere.app: ${e.message}"
        }
    }
