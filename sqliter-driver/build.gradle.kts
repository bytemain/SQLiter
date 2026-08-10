import org.gradle.api.publish.maven.MavenPublication
import org.gradle.api.tasks.bundling.AbstractArchiveTask
import org.jetbrains.kotlin.konan.target.HostManager

plugins {
    kotlin("multiplatform")
    id("com.vanniktech.maven.publish") version "0.27.0"
}

val GROUP: String by project
val VERSION_NAME: String by project

group = GROUP
version = VERSION_NAME

val publicationSourceSha = providers.gradleProperty("publicationSourceSha")
    .orElse(providers.environmentVariable("PUBLICATION_SOURCE_SHA"))
    .map { value ->
        require(value.matches(Regex("[0-9a-f]{40}"))) {
            "publicationSourceSha must be the exact 40-character lowercase commit SHA"
        }
        value
    }

publishing {
    repositories {
        maven {
            name = "raftArtifacts"
            url = uri(
                providers.gradleProperty("raftArtifactsUrl")
                    .orElse(providers.environmentVariable("RAFT_ARTIFACTS_URL"))
                    .orElse("https://maven.artifacts.botiverse.dev")
            )
            credentials {
                username = providers.gradleProperty("raftArtifactsUsername")
                    .orElse(providers.environmentVariable("RAFT_ARTIFACTS_USERNAME"))
                    .orElse("raft-ci")
                    .get()
                password = providers.gradleProperty("raftArtifactsToken")
                    .orElse(providers.environmentVariable("RAFT_ARTIFACTS_PUBLISH_TOKEN"))
                    .orNull
                    .orEmpty()
            }
        }
        maven {
            name = "publicationStaging"
            url = layout.buildDirectory.dir("publication-staging").get().asFile.toURI()
        }
    }

    publications.withType<MavenPublication>().configureEach {
        pom {
            properties.put("dev.raft.sourceSha", publicationSourceSha)
            scm {
                tag.set(publicationSourceSha)
            }
        }
    }
}

tasks.withType<AbstractArchiveTask>().configureEach {
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
}

fun configInterop(target: org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget) {
    val main by target.compilations.getting
    val sqlite3 by main.cinterops.creating {
        includeDirs("$projectDir/src/include")
//      extraOpts = listOf("-mode", "sourcecode")
    }

    target.compilations.forEach { kotlinNativeCompilation ->
        kotlinNativeCompilation.kotlinOptions.freeCompilerArgs += when {
            HostManager.hostIsLinux -> listOf(
                "-linker-options",
                "-lsqlite3 -L/usr/lib/x86_64-linux-gnu -L/usr/lib"
            )

            HostManager.hostIsMingw -> listOf("-linker-options", "-lsqlite3 -Lc:\\msys64\\mingw64\\lib")
            else -> listOf("-linker-options", "-lsqlite3")
        }
    }
}

kotlin {
    jvmToolchain(11)
}

kotlin {
    val knTargets = listOf(
        ohosArm64(),
    )

    knTargets
        .forEach { target ->
            configInterop(target)
        }

    sourceSets {
        all {
            languageSettings.apply {
                optIn("kotlin.experimental.ExperimentalNativeApi")
                optIn("kotlinx.cinterop.ExperimentalForeignApi")
                optIn("kotlinx.cinterop.BetaInteropApi")
            }
        }
        val commonMain by getting {
            dependencies {
            }
        }
        val commonTest by getting {
            dependencies {
                implementation(kotlin("test"))
            }
        }

        val nativeCommonMain = sourceSets.maybeCreate("nativeCommonMain").apply {
            dependsOn(commonMain)
        }
        val nativeCommonTest = sourceSets.maybeCreate("nativeCommonTest").apply {
            dependsOn(commonTest)
        }

        val linuxMain = sourceSets.maybeCreate("linuxMain").apply {
            dependsOn(nativeCommonMain)
        }
        val ohosArm64Main = sourceSets.maybeCreate("ohosArm64Main").apply {
            dependsOn(linuxMain)
        }

        knTargets.forEach { target ->
            when {
                target.name.startsWith("ohos") -> {
                    target.compilations.getByName("test").defaultSourceSet.dependsOn(nativeCommonTest)
                }
            }
        }
    }
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinNativeCompile> {
    kotlinOptions.freeCompilerArgs += "-Xexpect-actual-classes"
}

listOf(
    "ohosArm64Test",
    "linkDebugTestOhosArm64",
).forEach { tasks.findByName(it)?.enabled = false }
