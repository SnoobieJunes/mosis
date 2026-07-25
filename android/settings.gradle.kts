// Conduit Android project. Open in Android Studio (Ladybug+); the `core` module
// is the pure-Kotlin protocol implementation (also runnable on a bare JVM, which
// is how conformance + the session smoke are verified), and `app` is the Android
// client that plugs Android transport + the platform superpowers into it.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// `:core` asks for a Java 17 toolchain. Gradle stopped auto-downloading JDKs in
// 7.6, so on a machine whose only JDK is Android Studio's bundled JBR 21 — the
// normal state of a Mac that has never installed a standalone JDK — the build
// fails at configuration with "No matching toolchains found". This resolver
// provisions one, so `./gradlew :app:assembleDebug` works from a clean checkout
// without a manual `brew install openjdk@17` first.
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.8.0"
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Conduit"
include(":core")
include(":app")
