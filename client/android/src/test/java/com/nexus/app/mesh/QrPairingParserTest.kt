package com.nexus.app.mesh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QrPairingParserTest {

    @Test
    fun `parse returns data for valid JSON`() {
        val json = """{"nodeId":"abc-123","nodeName":"Test Node","pin":"987654"}"""
        val result = QrPairingParser.parse(json)
        assertEquals("abc-123", result?.nodeId)
        assertEquals("Test Node", result?.nodeName)
        assertEquals("987654", result?.pin)
    }

    @Test
    fun `parse returns data when nodeName is missing`() {
        val json = """{"nodeId":"abc-123","pin":"987654"}"""
        val result = QrPairingParser.parse(json)
        assertEquals("abc-123", result?.nodeId)
        assertEquals("abc-123", result?.nodeName)
        assertEquals("987654", result?.pin)
    }

    @Test
    fun `parse returns null for malformed JSON`() {
        assertNull(QrPairingParser.parse("not-json"))
    }

    @Test
    fun `parse returns null when nodeId is missing`() {
        val json = """{"nodeName":"Test","pin":"987654"}"""
        assertNull(QrPairingParser.parse(json))
    }

    @Test
    fun `parse returns null when pin is missing`() {
        val json = """{"nodeId":"abc-123","nodeName":"Test"}"""
        assertNull(QrPairingParser.parse(json))
    }

    @Test
    fun `parse returns null for blank nodeId`() {
        val json = """{"nodeId":"   ","nodeName":"Test","pin":"987654"}"""
        assertNull(QrPairingParser.parse(json))
    }

    @Test
    fun `parse returns null for blank pin`() {
        val json = """{"nodeId":"abc-123","nodeName":"Test","pin":"   "}"""
        assertNull(QrPairingParser.parse(json))
    }
}
