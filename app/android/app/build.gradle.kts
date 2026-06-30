import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val localProps = Properties()
val localPropsFile = rootProject.file("local.properties")
if (localPropsFile.exists()) {
    localProps.load(localPropsFile.inputStream())
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keyProps = Properties()
if (keystorePropertiesFile.exists()) {
    keyProps.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.app"
    compileSdk = 35
    buildToolsVersion = "35.0.0"
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // MASTER_SECRET is shared across all flavors
        buildConfigField("String", "MASTER_SECRET",
            "\"${localProps["MASTER_SECRET"]}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    flavorDimensions += "env"

    productFlavors {
        create("sg") {
            dimension = "env"
            applicationId = "com.example.app.sg"
            versionNameSuffix = "-sg"
             buildConfigField("String", "SERVER_IP",
                "\"${localProps["SG_SERVER_IP"]}\"")
            buildConfigField("int",    "SERVER_PORT",           "${localProps["SERVER_PORT"]}")
            buildConfigField("long",   "ROTATION_INTERVAL_SEC", "60L")
        }
        create("th") {
            dimension = "env"
            applicationId = "com.zay4r.htetvpn.th"
            versionNameSuffix = "-th"
             buildConfigField("String", "SERVER_IP",
                "\"${localProps["TH_SERVER_IP"]}\"")
            buildConfigField("int",    "SERVER_PORT",           "${localProps["SERVER_PORT"]}")
            buildConfigField("long",   "ROTATION_INTERVAL_SEC", "66L")
        }
    }

    signingConfigs {
        create("release") {
            keyAlias     = keyProps["keyAlias"]     as String
            keyPassword  = keyProps["keyPassword"]  as String
            storeFile    = file(keyProps["storeFile"] as String)
            storePassword = keyProps["storePassword"] as String
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
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
