// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Paths
import java.nio.file.attribute.PosixFilePermissions

class LinuxDesktopTest {
    @Test fun authorityRecordCarriesExactCookieAndDisplayWithoutAnExternalTool() {
        val cookie = ByteArray(16) { (it + 32).toByte() }
        val record = LinuxDesktopLaunch.authority(1234, cookie)
        DataInputStream(ByteArrayInputStream(record)).use { input ->
            fun field(): ByteArray = ByteArray(input.readUnsignedShort()).also { input.readFully(it) }
            assertEquals(65535, input.readUnsignedShort())
            assertArrayEquals(byteArrayOf(), field())
            assertEquals("1234", String(field(), Charsets.US_ASCII))
            assertEquals("MIT-MAGIC-COOKIE-1", String(field(), Charsets.US_ASCII))
            assertArrayEquals(cookie, field())
            assertEquals(-1, input.read())
        }
    }
    @Test fun authorityRejectsUnboundedOrMalformedRecords() {
        for (display in listOf(-1, 65536)) {
            try { LinuxDesktopLaunch.authority(display, ByteArray(16)); fail("Invalid display accepted") }
            catch (_: IllegalArgumentException) { }
        }
        for (size in listOf(0, 15, 17, 1024)) {
            try { LinuxDesktopLaunch.authority(1, ByteArray(size)); fail("Invalid cookie accepted") }
            catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun privateSocketAndXauthorityUseShortIsolatedPaths() {
        val cache = Files.createTempDirectory(Paths.get("/tmp"), "pd-").toFile()
        try {
            val first = LinuxDesktopLaunch.create(cache, 1024, 768)
            val second = LinuxDesktopLaunch.create(cache, 800, 600)
            assertNotEquals(first.directory, second.directory)
            assertTrue(first.socket.absolutePath.toByteArray().size < 104)
            assertEquals("rfb.sock", first.socket.name)
            val path = "/workspace/web-12345678-1234-1234-1234-123456789abc.md"
            val argv = first.revealArguments(path)
            assertEquals("array:string:file://$path", argv[argv.lastIndex - 1])
            assertTrue("org.freedesktop.FileManager1.ShowItems" in argv)
            assertFalse("/bin/sh" in argv)
            for (invalid in listOf(path + "/other", path + "\n", "/tmp/paste.md", path.replace("web-", "../web-"))) {
                assertThrows(IllegalArgumentException::class.java) { first.revealArguments(invalid) }
            }
            assertTrue(Files.isDirectory(first.temporary.toPath(), NOFOLLOW_LINKS))
            assertEquals(PosixFilePermissions.fromString("rwx------"), Files.getPosixFilePermissions(first.directory.toPath()))
            assertEquals(PosixFilePermissions.fromString("rw-------"), Files.getPosixFilePermissions(first.directory.resolve("Xauthority").toPath()))
            assertEquals("/bin/sh /run/perant-desktop/start_desktop.sh ${first.display} 1024 768", first.command)
            assertEquals("/workspace", first.result("desktop-1", 42)["workspace"])
            assertFalse(first.socket.exists())
            first.clean()
            assertFalse(first.directory.exists())
            assertTrue(second.directory.exists())
            second.clean()
        } finally { deleteTreeWithoutFollowingLinks(cache) }
    }
    @Test fun desktopSizeIsValidatedBeforeCreatingAResourceDirectory() {
        val cache = Files.createTempDirectory(Paths.get("/tmp"), "pd-").toFile()
        try {
            for ((width, height) in listOf(639 to 768, 1024 to 479, 1601 to 768, 1024 to 1201)) {
                try { LinuxDesktopLaunch.create(cache, width, height); fail("Invalid dimensions accepted") }
                catch (_: IllegalArgumentException) { }
            }
            assertEquals(0, cache.listFiles()!!.size)
        } finally { deleteTreeWithoutFollowingLinks(cache) }
    }

    @Test fun shellReadinessRequiresTheExactBoundedRegularMarker() {
        val cache = Files.createTempDirectory(Paths.get("/tmp"), "pd-").toFile()
        try {
            val launch = LinuxDesktopLaunch.create(cache, 720, 1080)
            val marker = launch.directory.resolve("desktop.ready")
            assertFalse(launch.shellReady())
            for (value in listOf("", "perant-desktop-v4\n", "perant-desktop-v5\n", "perant-desktop-v6", "perant-desktop-v6\nextra", "x".repeat(65536))) {
                marker.writeText(value, Charsets.US_ASCII)
                assertFalse("Unexpected readiness accepted", launch.shellReady())
            }
            marker.writeText("perant-desktop-v6\n", Charsets.US_ASCII)
            assertTrue(launch.shellReady())
            Files.delete(marker.toPath())
            Files.createDirectory(marker.toPath())
            assertFalse(launch.shellReady())
            Files.delete(marker.toPath())
            val other = launch.directory.resolve("other.ready")
            other.writeText("perant-desktop-v6\n", Charsets.US_ASCII)
            Files.createSymbolicLink(marker.toPath(), other.toPath())
            assertFalse(launch.shellReady())
            launch.clean()
        } finally { deleteTreeWithoutFollowingLinks(cache) }
    }
}
