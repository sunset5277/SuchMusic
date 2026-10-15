import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 读取签名配置（android/key.properties）
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.such.music.such_music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.such.music.such_music"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 正式包只保留 ARM 架构（x86_64 仅模拟器需要，debug 包不受影响）
        ndk {
            abiFilters.addAll(listOf("armeabi-v7a", "arm64-v8a"))
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            // 代码收缩 + 资源收缩，减小包体
            isMinifyEnabled = false // TODO: 对照实验，验证后恢复
            isShrinkResources = false // TODO: 对照实验，验证后恢复
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
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

// 小米手环通讯所需的小米官方 SDK（xms-wearable-lib）。
// 该 AAR 带专有许可，**不随仓库分发**；仅当 android/app/libs/ 下存在
// xms-wearable-lib*.aar 时才引入依赖。未放置 AAR 时此依赖不生效，
// 构建照常通过，手环功能在运行期自动降级为 Noop。
dependencies {
    val xmsAars = file("libs").listFiles { f ->
        f.isFile && f.name.startsWith("xms-wearable-lib") && f.name.endsWith(".aar")
    } ?: emptyArray()
    if (xmsAars.isNotEmpty()) {
        implementation(files(xmsAars.toList()))
    }
}

