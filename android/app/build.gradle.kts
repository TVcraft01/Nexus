plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: one shared keystore committed to the repo so every build
// (local and CI) produces APKs signed with the same key. This is what makes
// the in-app auto-update work — Android refuses to install over an app
// signed with a different key, and debug keys differ per machine.
android {
    namespace = "dev.nexus.nexus"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.nexus.nexus"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = file("nexus-release.jks")
            storePassword = "nexusrelease2026"
            keyAlias = "nexus"
            keyPassword = "nexusrelease2026"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // USB serial for ESP32/Arduino boards plugged into the phone (USB-OTG).
    implementation("com.github.mik3y:usb-serial-for-android:3.7.0")
}
