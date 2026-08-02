plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.devtools.ksp")
}

import java.util.Properties

android {
    namespace = "com.nexus.app"
    compileSdk = 34

    val keystoreProperties = Properties()
    val keystoreFile = rootProject.file("local.properties")
    if (keystoreFile.exists()) {
        keystoreFile.inputStream().use { keystoreProperties.load(it) }
    }

    defaultConfig {
        applicationId = "com.nexus.app"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0-nexus"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }

        // Vosk small model download base URL. Default uses the official Vosk mirrors.
        buildConfigField("String", "MODEL_BASE_URL", "\"https://alphacephei.com/vosk/models/\"")
    }

    signingConfigs {
        create("release") {
            val storeFileProp = keystoreProperties.getProperty("storeFile")
            if (storeFileProp != null) {
                storeFile = file(storeFileProp)
            }
            storePassword = keystoreProperties.getProperty("storePassword")
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("release")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.10"
    }

    // Include shared prompts directly into Android assets.
    // The same file is read by the desktop code from shared/prompts/.
    sourceSets["main"].assets.srcDir(rootProject.file("shared/prompts"))

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    // Expose the project root to unit tests so they can verify shared files.
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.systemProperty("PROJECT_ROOT", rootProject.projectDir.absolutePath)
            }
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.02.00")

    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
    implementation("androidx.activity:activity-compose:1.8.2")
    implementation("androidx.navigation:navigation-compose:2.7.7")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")

    // Jetpack Compose
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    // Room
    val roomVersion = "2.6.1"
    implementation("androidx.room:room-runtime:$roomVersion")
    implementation("androidx.room:room-ktx:$roomVersion")
    ksp("androidx.room:room-compiler:$roomVersion")

    // SQLCipher for encrypted Room database
    implementation("net.zetetic:android-database-sqlcipher:4.5.4")
    implementation("androidx.sqlite:sqlite:2.4.0")

    // Encrypted SharedPreferences / datastore for vault keys
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")

    // Wake-word detection (on-device, free, multilingual Vosk)
    implementation("com.alphacephei:vosk-android:0.3.75")
    implementation("net.java.dev.jna:jna:5.13.0@aar")

    // JSON
    implementation("com.google.code.gson:gson:2.10.1")

    // QR code generation and scanning
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("com.google.zxing:core:3.5.3")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20231013") // real org.json for unit tests
    testImplementation("org.robolectric:robolectric:4.11.1")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
