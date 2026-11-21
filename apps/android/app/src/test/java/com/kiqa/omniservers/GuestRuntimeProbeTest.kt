package com.kiqa.omniservers

import com.kiqa.omniservers.data.GuestRuntimeProbe
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GuestRuntimeProbeTest {
    @Test fun missingRuntimeIsReportedWithoutUsingAndroidArt() {
        val result = GuestRuntimeProbe.probe(File("/definitely-missing"))
        assertFalse(result.available)
        assertTrue(result.message.contains("not packaged"))
    }

    @Test fun appPrivateRuntimeVersionIsReported() {
        val root = createTempDir()
        try {
            val java = File(root, "jvm/bin/java").apply { parentFile!!.mkdirs(); createNewFile(); setExecutable(true) }
            val result = GuestRuntimeProbe.probe(root) { candidate ->
                assertTrue(candidate.absolutePath.endsWith("/jvm/bin/java"))
                listOf("java.version=21.0.5")
            }
            assertTrue(result.available)
            assertTrue(result.message.contains("21.0.5"))
        } finally {
            root.deleteRecursively()
        }
    }
}
