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
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Conduit"
include(":core")
include(":app")
