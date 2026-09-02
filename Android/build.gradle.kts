// Versions match slogger's, which is the known-good combination on this machine.
// The collector borrows sloggerlib's code and design but does not depend on the
// module: a cross-repository Gradle dependency would tie the two projects to one
// AGP and Kotlin version forever, for a library we consume rather than develop.
plugins {
    id("com.android.application") version "8.6.1" apply false
    id("org.jetbrains.kotlin.android") version "1.9.22" apply false
    kotlin("plugin.serialization") version "1.9.22" apply false
}
