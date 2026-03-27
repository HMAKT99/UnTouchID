plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.touchbridge.wear"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.touchbridge.wear"
        minSdk = 30  // Wear OS 3+
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        compose = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.8"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // Wear OS Compose
    implementation(platform("androidx.compose:compose-bom:2024.01.00"))
    implementation("androidx.wear.compose:compose-material:1.3.0")
    implementation("androidx.wear.compose:compose-foundation:1.3.0")
    implementation("androidx.activity:activity-compose:1.8.2")

    // Wearable Data Layer API
    implementation("com.google.android.gms:play-services-wearable:18.1.0")

    // Lifecycle
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
    implementation("androidx.core:core-ktx:1.12.0")

    // Haptic
    implementation("androidx.wear:wear:1.3.0")
}
