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

application {
    // Default entrypoint: the test suite (fixtures have their own class).
    mainClass.set("golf.TestMainKt")
}

tasks.register<JavaExec>("generateFixtures") {
    group = "golf"
    description = "Regenerate Kotlin cross-language fixtures into ../testdata."
    mainClass.set("golf.GenerateFixturesKt")
    classpath = sourceSets["main"].runtimeClasspath
    args = (project.findProperty("out") as? String)?.let { listOf(it) } ?: listOf("../testdata")
}

// The bundled TestMain suite exits non-zero on failure and prints per-suite
// results, so it runs fine as a "test" without JUnit on the classpath.
tasks.test {
    dependsOn(tasks.named("run"))
}
