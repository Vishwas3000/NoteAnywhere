plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.memorynotes.android"
    // Compose BOM 2026.09.00 needs compileSdk 37; behaviour follows targetSdk.
    compileSdk = 37

    defaultConfig {
        // Not com.memorynotes.app: that's the Mac app's bundle id (D66).
        applicationId = "com.memorynotes.android"
        minSdk = 26 // java.util.Base64
        targetSdk = 36
        versionCode = 1
        versionName = rootProject.file("../VERSION").readText().trim() // one version for every app
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures { compose = true }
}

dependencies {
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.material3:material3")
    testImplementation("junit:junit:4.13.2")
    // Android ships org.json; plain JVM unit tests need the real one.
    testImplementation("org.json:json:20250517")
    // The crypto and Keystore on a real Android runtime (connectedDebugAndroidTest).
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("junit:junit:4.13.2")
}
