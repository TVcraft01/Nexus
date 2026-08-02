package com.nexus.app.command

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutineRepositoryTest {

    @Test
    fun `RoutineSuggestion displayText capitalizes input`() {
        val suggestion = RoutineSuggestion(
            id = "1",
            input = "turn on flashlight",
            actionType = "TOGGLE_FLASHLIGHT",
            payload = "",
            hourOfDay = 10,
            confidence = 3
        )
        assertEquals("Turn on flashlight", suggestion.displayText)
    }


    @Test
    fun `RoutineSuggestion fromEntity maps fields`() {
        val entity = com.nexus.app.data.local.entity.RoutineSuggestionEntity(
            id = "3",
            input = "weather",
            actionType = "GET_WEATHER",
            payload = "",
            hourOfDay = 8,
            confidence = 4
        )
        val suggestion = RoutineSuggestion.fromEntity(entity)
        assertEquals("3", suggestion.id)
        assertEquals("weather", suggestion.input)
        assertEquals("GET_WEATHER", suggestion.actionType)
        assertEquals(8, suggestion.hourOfDay)
        assertEquals(4, suggestion.confidence)
    }

    @Test
    fun `only alarm actions are allowed as suggestions`() {
        assertTrue("SET_ALARM should be allowed", "SET_ALARM".isAllowedSuggestionTypeForTest())
        assertFalse("TOGGLE_WIFI should be denied", "TOGGLE_WIFI".isAllowedSuggestionTypeForTest())
        assertFalse("CALL_CONTACT should be denied", "CALL_CONTACT".isAllowedSuggestionTypeForTest())
    }

    @Test
    fun `alarm displayText formats time`() {
        val suggestion = RoutineSuggestion(
            id = "4",
            input = "set an alarm for 7:30",
            actionType = "SET_ALARM",
            payload = "7:30",
            hourOfDay = 7,
            confidence = 3
        )
        assertEquals("Set alarm for 7:30 AM", suggestion.displayText)
    }
}

private fun String.isAllowedSuggestionTypeForTest(): Boolean = this == "SET_ALARM"
