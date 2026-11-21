package com.kiqa.omniservers.data

import android.content.res.AssetManager
import android.util.Log
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.util.zip.GZIPInputStream
import java.util.concurrent.TimeUnit

/** Probes only an app-private guest JVM; Android ART is deliberately not used as a fallback. */
data class GuestRuntimeResult(
    val available: Boolean,
    val message: String,
    val javaVersion: String? = null,
)

object GuestRuntimeProbe {
    private const val tag = "GuestRuntimeProbe"

    fun probe(
        filesDir: File,
        assets: AssetManager? = null,
        nativeLibraryDir: String? = null,
        runner: (File) -> List<String> = { runJava(it, nativeLibraryDir) },
    ): GuestRuntimeResult {
        if (assets != null) {
            try {
                installRuntime(filesDir, assets)
            } catch (e: Exception) {
                Log.e(tag, "Guest runtime extraction failed", e)
                return GuestRuntimeResult(false, "Guest Java 21 could not be installed: ${e.message ?: e::class.simpleName}")
            }
        }
        val candidates = listOf(
            File(filesDir, "jvm/bin/java"),
            File(filesDir, "runtime/bin/java"),
        )
        val java = candidates.firstOrNull { it.isFile && it.canExecute() }
            ?: return GuestRuntimeResult(false, "Guest Java 21 is not packaged in this APK.")
        return try {
            val output = runner(java)
            val version = output.firstOrNull { it.startsWith("java.version=") }?.substringAfter("=")
            if (version == null) {
                GuestRuntimeResult(false, "Guest JVM did not report java.version.", output.joinToString("\n"))
            } else {
                GuestRuntimeResult(true, "Guest JVM started: java.version=$version", version)
            }
        } catch (e: Exception) {
            Log.e(tag, "Guest JVM probe failed", e)
            GuestRuntimeResult(false, "Guest JVM failed to start: ${e.message ?: e::class.simpleName}")
        }
    }

    private fun runJava(java: File, nativeLibraryDir: String?): List<String> {
        val process = ProcessBuilder(java.absolutePath, "-XshowSettings:properties", "-version")
            .redirectErrorStream(true)
            .apply {
                val javaHome = requireNotNull(java.parentFile?.parentFile) { "invalid Java launcher path" }
                environment()["JAVA_HOME"] = javaHome.absolutePath
                nativeLibraryDir?.let { environment()["LD_LIBRARY_PATH"] = "$it:${javaHome.resolve("lib").absolutePath}" }
            }
            .start()
        val output = process.inputStream.bufferedReader().use { it.readLines() }
        if (!process.waitFor(10, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            error("timed out")
        }
        if (process.exitValue() != 0) error("exit ${process.exitValue()}: ${output.joinToString(" ")}")
        return output
    }

    private fun installRuntime(filesDir: File, assets: AssetManager) {
        val marker = File(filesDir, "jvm/release")
        if (marker.isFile) return
        val staging = File(filesDir, ".jvm-install")
        staging.deleteRecursively()
        staging.mkdirs()
        val archive = assets.list("")?.firstOrNull { it == "jre21-aarch64.tar" }
            ?: "jre21-aarch64.tar.gz"
        assets.open(archive).use { input ->
            val tar = if (archive.endsWith(".gz")) GZIPInputStream(BufferedInputStream(input)) else input
            tar.use { extractTar(it, staging) }
        }
        val unpacked = File(staging, "java-21-openjdk")
        require(File(unpacked, "bin/java").isFile) { "runtime archive has no java launcher" }
        marker.parentFile!!.mkdirs()
        unpacked.renameTo(marker.parentFile!!)
        staging.deleteRecursively()
        File(filesDir, "jvm/bin/java").setExecutable(true)
    }

    private fun extractTar(input: java.io.InputStream, destination: File) {
        val header = ByteArray(512)
        while (true) {
            readFully(input, header)
            if (header.all { it.toInt() == 0 }) return
            val name = header.copyOfRange(0, 100).decodeToString().trimEnd('\u0000')
            val size = header.copyOfRange(124, 136).decodeToString().trimEnd('\u0000', ' ').toLong(8)
            val type = header[156].toInt().toChar()
            val target = File(destination, name)
            require(target.canonicalPath.startsWith(destination.canonicalPath + File.separator)) { "unsafe runtime path" }
            if (type == '5') target.mkdirs() else {
                target.parentFile?.mkdirs()
                FileOutputStream(target).use { output -> input.copyExactlyTo(output, size) }
                target.setExecutable(name.substringAfterLast('/').contains("java") || name.contains("/bin/"))
            }
            val padding = (512 - (size % 512)) % 512
            input.skipFully(padding)
        }
    }

    private fun readFully(input: java.io.InputStream, buffer: ByteArray) {
        var offset = 0
        while (offset < buffer.size) {
            val n = input.read(buffer, offset, buffer.size - offset)
            if (n < 0) error("truncated runtime archive")
            offset += n
        }
    }

    private fun java.io.InputStream.copyExactlyTo(output: FileOutputStream, count: Long) {
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var remaining = count
        while (remaining > 0) {
            val n = read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (n < 0) error("truncated runtime file")
            output.write(buffer, 0, n)
            remaining -= n
        }
    }

    private fun java.io.InputStream.skipFully(count: Long) {
        var remaining = count
        while (remaining > 0) {
            val n = skip(remaining)
            if (n <= 0) {
                if (read() < 0) error("truncated runtime padding")
                remaining--
            } else remaining -= n
        }
    }
}
