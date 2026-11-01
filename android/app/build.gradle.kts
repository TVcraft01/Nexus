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
            // The default Flutter release rules, plus the project's own: R8
            // fails the build on ML Kit's references to text-recognizer
            // scripts this app never asks for — see proguard-rules.pro. The
            // rule is unchanged now that ML Kit is called from VisionBridge.kt
            // rather than through a Dart package; the artifact is the same.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
    // On-device vision, called directly from VisionBridge.kt. These are the
    // exact artifacts and versions the google_mlkit_* Dart packages pinned, so
    // the phone's OCR and labeling behaviour does not change; the packages
    // themselves are gone because they required iOS 15.5 and the iOS build now
    // targets 15.0 for an iPhone 6s.
    //
    // `text-recognition` bundles the Latin model only, which is the one this
    // app has always asked for. The other scripts stay out of the APK.
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mlkit:image-labeling:17.0.9")

    // USB serial for ESP32/Arduino boards plugged into the phone (USB-OTG).
    implementation("com.github.mik3y:usb-serial-for-android:3.7.0")

    // JVM unit tests (e.g. the contact-name matching logic in MainActivity).
    testImplementation("junit:junit:4.13.2")
}
