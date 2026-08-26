// Standard Gradle build for IDE/CI use. The library has zero third-party
// dependencies; only the Kotlin/JVM plugin is required. The `kotlinc`-based
// scripts under scripts/ do the same job without Gradle.
plugins {
    kotlin("jvm") version "2.1.0"
    application
}

group = "golf"
version = "0.1.0"

kotlin {
    jvmToolchain(17)
}

// A target that lives in the main source set, so `gradle run` works out of the
// box: it regenerates this language's cross-language fixtures into ../testdata.
application {
    mainClass.set("golf.GenerateFixturesKt")
}

val generateFixtures by tasks.existing(JavaExec::class) {
    args = (project.findProperty("out") as? String)?.let { listOf(it) } ?: listOf("../testdata")
}

// The self-contained test suite's entrypoint lives in src/test/kotlin, so it
// must run on the *test* source-set classpath; a plain `JavaExec` over the
// main classpath would throw ClassNotFoundException.
tasks.register<JavaExec>("runTestSuite") {
    group = "verification"
    description = "Run the self-contained golf test suite (no JUnit required)."
    mainClass.set("golf.TestMainKt")
    classpath = sourceSets["test"].runtimeClasspath
    args = listOf("../testdata")
}
