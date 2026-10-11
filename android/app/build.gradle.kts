plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.engikode.enginote"
    compileSdk = 34

    defaultConfig {
        // The app's identity. Android keeps an app's saved notes through an update only while this
        // and the signing key stay the same, so NEVER change either. (The same goes for the page
        // address in MainActivity.kt.)
        applicationId = "com.engikode.enginote"
        minSdk = 26
        targetSdk = 34
        versionCode = (System.getenv("BUILD_NUMBER") ?: "1").toInt()
        versionName = "1.0"
    }

    // The workflow signs with a key kept in GitHub's secrets (.github/workflows/android.yml): an
    // update installs over the old app only if it is signed by the same key.
    signingConfigs {
        create("release") {
            System.getenv("KEYSTORE_FILE")?.let { path ->
                storeFile = file(path)
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS")
                keyPassword = System.getenv("KEYSTORE_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

dependencies {
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.webkit:webkit:1.12.1")
}
