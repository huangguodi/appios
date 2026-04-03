import java.io.File
import java.util.Properties

val keyPropertiesFile = File(rootDir, "key.properties")
val keyProperties = Properties().apply {
    if (keyPropertiesFile.exists()) {
        keyPropertiesFile.inputStream().use { load(it) }
    }
}

fun releaseSigningValue(name: String, keyPropertiesName: String): String? {
    return providers.gradleProperty(name).orNull
        ?: providers.environmentVariable(name).orNull
        ?: keyProperties.getProperty(keyPropertiesName)
}

val releaseStoreFilePath = releaseSigningValue("ANDROID_RELEASE_STORE_FILE", "storeFile")?.trim()
val releaseStoreType = releaseSigningValue("ANDROID_RELEASE_STORE_TYPE", "storeType")?.trim()
val releaseStorePassword = releaseSigningValue("ANDROID_RELEASE_STORE_PASSWORD", "storePassword")?.trim()
val releaseKeyAlias = releaseSigningValue("ANDROID_RELEASE_KEY_ALIAS", "keyAlias")?.trim()
val releaseKeyPassword = releaseSigningValue("ANDROID_RELEASE_KEY_PASSWORD", "keyPassword")?.trim()
val hasReleaseSigning =
    !releaseStoreFilePath.isNullOrBlank() &&
    !releaseStorePassword.isNullOrBlank() &&
    !releaseKeyAlias.isNullOrBlank() &&
    !releaseKeyPassword.isNullOrBlank()
val isReleaseBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.accelerator.tg"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
        getByName("main").jniLibs.srcDirs("src/main/jniLibs")
    }

    defaultConfig {
        applicationId = "com.accelerator.tg"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // Filter for architectures supported by Flutter and your native libs
            abiFilters.add("arm64-v8a")
        }
        
        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = file(releaseStoreFilePath!!)
                if (!releaseStoreType.isNullOrBlank()) {
                    storeType = releaseStoreType
                }
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else if (isReleaseBuildRequested) {
                throw GradleException(
                    "Missing Android release signing configuration. Set ANDROID_RELEASE_STORE_FILE, ANDROID_RELEASE_STORE_PASSWORD, ANDROID_RELEASE_KEY_ALIAS, and ANDROID_RELEASE_KEY_PASSWORD.",
                )
            }
            
            // ProGuard/R8 Obfuscation
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            
            // O-LLVM / NDK Obfuscation Flags
            // 注意：标准的 NDK Clang 不支持 -mllvm -sub -mllvm -fla 等 O-LLVM 特有指令。
            // 如果你使用的是标准 NDK，这些标志会被忽略或报错。
            // 只有在使用定制的 O-LLVM 编译器链时才有效。
            // 此处配置假设环境已准备好 O-LLVM，或者作为示例展示如何传递标志。
            externalNativeBuild {
                cmake {
                    // Control Flow Flattening (-fla), Instruction Substitution (-sub), Bogus Control Flow (-bcf)
                    // cppFlags += "-mllvm -fla -mllvm -sub -mllvm -bcf"
                    // Strip symbols
                    arguments += "-DCMAKE_BUILD_TYPE=Release"
                }
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.0")
    implementation(platform("org.jetbrains.kotlin:kotlin-bom:1.8.0"))
    implementation(files("libs/classes.jar"))
}
