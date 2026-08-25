package dev.nexus.nexus

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/// Unit tests for the contact-name resolution used by "call <name>":
/// an exact display-name match must always win, then a case-insensitive
/// fallback picks prefix over contains — enough to resolve real contacts
/// like "TVcraft01 〘✘ΔτΚ⑤⑦〙" from a plain "tvcraft01" query.
class ContactMatchTest {
  private val contacts = listOf(
    "TVcraft01 〘✘ΔτΚ⑤⑦〙",
    "Mom",
    "Alicia TVcraft01 work", // contains, but not a prefix
  )

  @Test
  fun `exact match wins even when other candidates also match`() {
    assertEquals("Mom", pickBestContactMatch(contacts + listOf("mom"), "Mom"))
  }

  @Test
  fun `exact match beats prefix and contains candidates`() {
    val candidates = listOf("alicia tvcraft01 work", "TVCRAFT01", "TVcraft01 〘✘ΔτΚ⑤⑦〙")
    assertEquals("TVCRAFT01", pickBestContactMatch(candidates, "TVCRAFT01"))
  }

  @Test
  fun `case-insensitive full match is second priority`() {
    assertEquals("Mom", pickBestContactMatch(contacts, "mom"))
  }

  @Test
  fun `decorated display name resolves via prefix fallback`() {
    assertEquals(
      "TVcraft01 〘✘ΔτΚ⑤⑦〙",
      pickBestContactMatch(contacts, "TVcraft01"),
    )
  }

  @Test
  fun `prefix beats contains`() {
    val candidates = listOf("zzz TVcraft01 fan club", "TVcraft01 〘✘ΔτΚ⑤⑦〙")
    assertEquals("TVcraft01 〘✘ΔτΚ⑤⑦〙", pickBestContactMatch(candidates, "tvcraft01"))
  }

  @Test
  fun `contains is the last resort`() {
    assertEquals(
      "Alicia TVcraft01 work",
      pickBestContactMatch(listOf("Alicia TVcraft01 work"), "tvcraft"),
    )
  }

  @Test
  fun `no candidate matches returns null`() {
    assertNull(pickBestContactMatch(contacts, "bob"))
  }

  @Test
  fun `empty or blank query returns null`() {
    assertNull(pickBestContactMatch(contacts, ""))
    assertNull(pickBestContactMatch(contacts, "   "))
  }

  @Test
  fun `query whitespace is trimmed before matching`() {
    assertEquals("Mom", pickBestContactMatch(contacts, " Mom "))
  }
}
