

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
        applicationId = "com.example.app"
         minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "MASTER_SECRET", 
            "\"${localProps["MASTER_SECRET"]}\"")
        buildConfigField("String", "SERVER_IP", 
            "\"${localProps["SERVER_IP"]}\"")
        buildConfigField("int", "SERVER_PORT", 
            "${localProps["SERVER_PORT"]}")
    }
    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        create("release") {
            keyAlias = keyProps["keyAlias"] as String
            keyPassword = keyProps["keyPassword"] as String
            storeFile = file(keyProps["storeFile"] as String)
            storePassword = keyProps["storePassword"] as String
        }
    }

    buildTypes {
        release {
           
            signingConfig = signingConfigs.getByName("debug")
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
