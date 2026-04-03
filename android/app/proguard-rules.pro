# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Keep MainActivity Native Methods (Critical for JNI)
-keepclasseswithmembernames class com.accelerator.tg.MainActivity {
    native <methods>;
}

# Keep gomobile binding/runtime classes and members (critical in release)
# JNI generated stubs refer to stable class/member names under mobile.* and go.*
-keep class mobile.** { *; }
-keep class go.** { *; }
-keep class mobile.Mobile { *; }
-keep class mobile.SocketProtector { *; }
-keep class go.Seq { *; }
-keepattributes Signature,InnerClasses,EnclosingMethod
-dontwarn mobile.**
-dontwarn go.**

# DO NOT keep the entire package, let R8 shrink and obfuscate internal classes
# Only keep what is strictly necessary for Flutter MethodChannels (usually handled automatically by Flutter)
# -keep class com.accelerator.tg.** { *; }

# ==============================================================================
# Third-party Library Rules (Strict Mode)
# Only keeping class names, allowing method/field obfuscation where possible
# ==============================================================================

# 1. flutter_secure_storage
-keepnames class com.it_nomads.fluttersecurestorage.** { *; }

# 2. shared_preferences
-keepnames class io.flutter.plugins.sharedpreferences.** { *; }

# 3. device_info_plus
-keepnames class dev.fluttercommunity.plus.device_info.** { *; }

# 4. android_id
-keepnames class com.example.android_id.** { *; }

# 5. path_provider
-keepnames class io.flutter.plugins.pathprovider.** { *; }

# 6. permission_handler
-keepnames class com.baseflow.permissionhandler.** { *; }

# 7. url_launcher
-keepnames class io.flutter.plugins.urllauncher.** { *; }

# 8. General Coroutines (Used by many plugins, keep only entry points)
-keepnames class kotlinx.coroutines.** { *; }
-keepnames class kotlin.coroutines.** { *; }

# 9. Android X & Support Libraries (Allow obfuscation, just ignore warnings)
-dontwarn androidx.**
-dontwarn android.support.**

# ==============================================================================
# General Rules
# ==============================================================================
-dontwarn io.flutter.**
-dontwarn javax.annotation.**

# Remove debug logs in release build (Strict optimization)
-assumenosideeffects class android.util.Log {
    public static boolean isLoggable(java.lang.String, int);
    public static int v(...);
    public static int i(...);
    public static int w(...);
    public static int d(...);
    public static int e(...);
}

# Keep only necessary attributes
-keepattributes *Annotation*

# Aggressive Optimization
-optimizationpasses 5
-allowaccessmodification
-optimizations !code/simplification/arithmetic,!field/*,!class/merging/*

# Fix missing classes from errorprone
-dontwarn javax.lang.model.element.Modifier
-dontwarn com.google.errorprone.annotations.**
-keepnames class com.google.errorprone.annotations.** { *; }
