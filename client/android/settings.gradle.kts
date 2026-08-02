pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        // AGP 8.3.x compatible with Gradle 8.11, Java 17, compileSdk 34
        id("com.android.application") version "8.3.2"
        // Compose compiler 1.5.10 requires Kotlin 1.9.23
        id("org.jetbrains.kotlin.android") version "1.9.23"
        // KSP version must match Kotlin version
        id("com.google.devtools.ksp") version "1.9.23-1.0.19"
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "nexus-app"
