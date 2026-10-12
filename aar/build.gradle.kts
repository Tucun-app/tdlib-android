// Packages the TDLib Android output of the official build (plus the source patches listed in tdlib.env) into an AAR.
// src/main/java (Client.java, TdApi.java) and src/main/jniLibs (<abi>/libtdjni.so) are copied from the
// official tdlib.zip by the workflow before this build runs; they are not committed to this repository.
plugins {
    id("com.android.library") version "9.2.1"
}

val tdlibEnv: Map<String, String> = rootDir.resolve("../tdlib.env").readLines()
    .map { it.trim() }
    .filter { it.isNotEmpty() && !it.startsWith("#") && it.contains('=') }
    .associate { it.substringBefore('=') to it.substringAfter('=') }

android {
    namespace = "org.drinkless.tdlib"
    compileSdk = 36
    defaultConfig {
        minSdk = 21
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        testInstrumentationRunnerArguments["expectedVersion"] = tdlibEnv.getValue("TDLIB_VERSION")
        // The commit TDLib reports as "commit_hash": the patched commit when tdlib.env applies source patches.
        testInstrumentationRunnerArguments["expectedCommit"] =
            tdlibEnv["TDLIB_PATCHED_COMMIT"]?.takeIf { it.isNotEmpty() } ?: tdlibEnv.getValue("TDLIB_COMMIT")
    }
    compileOptions {
        // Same bytecode level as the com.github.tdlibx:td AAR it replaces (class file major 52).
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    buildTypes {
        release { isMinifyEnabled = false }
    }
    packaging {
        // Ship the official stripped libraries byte-for-byte.
        jniLibs { keepDebugSymbols += "**/libtdjni.so" }
    }
}

dependencies {
    // TdApi.java uses androidx.annotation (@Nullable, @IntDef); consumers bring their own copy.
    compileOnly("androidx.annotation:annotation:1.9.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("junit:junit:4.13.2")
}
