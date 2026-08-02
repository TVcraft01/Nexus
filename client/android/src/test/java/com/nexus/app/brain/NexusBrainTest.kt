package com.nexus.app.brain

import com.nexus.app.command.CommandAction
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class NexusBrainTest {

    @Test
    fun `parseResponse strips markdown fences and returns JSON`() {
        val content = "```json\n{\"type\": \"chat\", \"content\": \"Hello\"}\n```"
        val parsed = NexusBrain::class.java.getDeclaredMethod("parseResponse", String::class.java)
            .apply { isAccessible = true }
            .invoke(null, content) as JSONObject
        assertEquals("chat", parsed.getString("type"))
        assertEquals("Hello", parsed.getString("content"))
    }

    @Test
    fun `parseResponse returns null for invalid JSON`() {
        val parsed = NexusBrain::class.java.getDeclaredMethod("parseResponse", String::class.java)
            .apply { isAccessible = true }
            .invoke(null, "not json") as JSONObject?
        assertNull(parsed)
    }

    @Test
    fun `buildAction creates SET_VOLUME action`() {
        val args = JSONObject().apply { put("percent", 75) }
        val action = NexusBrain::class.java.getDeclaredMethod("buildAction", String::class.java, JSONObject::class.java)
            .apply { isAccessible = true }
            .invoke(null, "SET_VOLUME", args) as CommandAction?
        assertNotNull(action)
        assertEquals("SET_VOLUME", action?.name)
    }

    @Test
    fun `default system prompt matches shared prompt file`() {
        val projectRoot = System.getProperty("PROJECT_ROOT")
            ?: throw AssertionError("PROJECT_ROOT system property not set by Gradle")
        val shared = File(projectRoot, "shared/prompts/nexus_brain_system_prompt.md").readText()
        assertEquals(shared, NexusBrain.DEFAULT_SYSTEM_PROMPT)
    }
}
