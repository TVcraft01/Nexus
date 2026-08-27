package dev.nexus.nexus

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Test-side mirror of the production matcher: exact, case-insensitive full,
/// prefix, contains — null when nothing matches. Lives here because nothing
/// in production calls it (callContact uses rankedContactMatches directly).
private fun pickBestContactMatch(candidates: List<String>, query: String): String? =
    rankedContactMatches(candidates, query, limit = 1).firstOrNull()

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

  // --- rankedContactMatches: the list behind the "who did you mean?" flow.

  @Test
  fun `ranked list orders exact before prefix and contains`() {
    val ranked = rankedContactMatches(
      listOf("Alicia TVcraft01 work", "TVcraft01 〘✘ΔτΚ⑤⑦〙", "tvcraft01"),
      "TVcraft01",
    )
    // Exact tier is empty; case-insensitive full match first, then prefix,
    // then contains.
    assertEquals(listOf("tvcraft01", "TVcraft01 〘✘ΔτΚ⑤⑦〙", "Alicia TVcraft01 work"), ranked)
  }

  @Test
  fun `ranked list deduplicates candidates shared across tiers`() {
    // "Mom" matches on multiple tiers for the query "mom" but must appear
    // exactly once. (Distinct display names like "Mom" vs "mom" are separate
    // contacts and stay separate offers.)
    val ranked = rankedContactMatches(listOf("Mom"), "mom", limit = 5)
    assertEquals(listOf("Mom"), ranked)
  }

  @Test
  fun `ranked list respects the limit`() {
    val ranked = rankedContactMatches(
      listOf("TVcraft01 a", "TVcraft01 b", "TVcraft01 c", "TVcraft01 d"),
      "tvcraft01",
      limit = 3,
    )
    assertEquals(3, ranked.size)
  }

  @Test
  fun `empty query yields an empty ranked list`() {
    assertTrue(rankedContactMatches(contacts, "").isEmpty())
    assertTrue(rankedContactMatches(contacts, "   ").isEmpty())
  }

  @Test
  fun `accent-free query matches accented contact name`() {
    val ranked = rankedContactMatches(listOf("Café Maman", "Papi"), "cafe maman", limit = 3)
    assertEquals(listOf("Café Maman"), ranked)
    assertEquals("Café Maman", pickBestContactMatch(listOf("Café Maman", "Papi"), "CAFE MAMAN"))
  }
}
