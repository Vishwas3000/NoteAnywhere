plugins {
    id("com.android.application") version "9.4.1" apply false
    // Also puts the Kotlin Gradle plugin on the classpath; AGP 9's built-in Kotlin compiles with it.
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.21" apply false
}
