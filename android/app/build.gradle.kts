plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "org.conduit.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.conduit.android"   // placeholder — rename with the product (open decision 1)
        // API 33, not 28. The identity layer uses java.security.spec.
        // EdECPrivateKeySpec / NamedParameterSpec (Identity.kt), both of which
        // are `since="33"`. They sit on the first-launch path, so on Android
        // 9–12 the app dies with NoClassDefFoundError before it draws anything —
        // and `assembleDebug` does not run lint, so the APK built clean and the
        // declared minSdk was simply a lie. BluetoothHidDevice / dispatchGesture
        // / Wi-Fi Aware are all still available at 33.
        minSdk = 33
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }

    // BouncyCastle ships bcprov/bcutil/bcpkix, and all three carry the same
    // multi-release OSGi metadata, which the APK packager refuses to merge.
    // None of it is used at runtime on Android.
    packaging {
        resources {
            excludes += setOf(
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/*.SF",
                "META-INF/*.DSA",
                "META-INF/*.RSA",
            )
        }
    }
}

dependencies {
    implementation(project(":core"))
    val composeBom = platform("androidx.compose:compose-bom:2024.09.03")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    // Self-signed P-256 certificate generation for the pinned-TLS transport
    // (Android's java.security has no public self-signed X.509 builder).
    implementation("org.bouncycastle:bcpkix-jdk18on:1.78.1")
}
