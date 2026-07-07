// The protocol core is a plain Kotlin/JVM library: zero Android dependencies, so
// it compiles with a bare kotlinc (that's how conformance + the session smoke
// run in CI) and the Android app depends on it as a normal module. Keeping it
// Android-free is what lets the same code be conformance-tested on the JVM.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    jvmToolchain(17)
}

// No external dependencies — canonical JSON, framing, Ed25519 (JDK), and the
// session layer are all hand-rolled / stdlib, matching the Go core's discipline.
