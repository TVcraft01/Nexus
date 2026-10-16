package dev.nexus.nexus

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// The alias mapping the app icon switch is built on: Dart sends "light" or
/// "dark", and PackageManager is handed the fully qualified name of the
/// matching alias. Both halves are silent failure modes if they drift — a
/// wrong name is a NameNotFoundException in the field, and a mode with no
/// alias would leave the app with no launcher entry at all — so the mapping,
/// and the fact that exactly one alias stays behind, are pinned here without a
/// device.
class IconAliasTest {
  private val pkg = "dev.nexus.nexus"

  @Test
  fun `each mode maps to its own manifest alias`() {
    assertEquals("dev.nexus.nexus.IconLight", iconAliasComponent(pkg, "light"))
    assertEquals("dev.nexus.nexus.IconDark", iconAliasComponent(pkg, "dark"))
  }

  @Test
  fun `switching a mode off leaves every other alias, and only those`() {
    assertEquals(listOf("dark"), otherIconAliases("light"))
    assertEquals(listOf("light"), otherIconAliases("dark"))
  }

  @Test
  fun `an unknown mode maps to nothing rather than to a guess`() {
    assertNull(iconAliasComponent(pkg, "sepia"))
    assertNull(iconAliasComponent(pkg, ""))
    assertNull(iconAliasComponent(pkg, "Light"))
  }

  @Test
  fun `the aliases are distinct and each is a real manifest name`() {
    val modes = LAUNCHER_ICON_ALIASES.map { it.first }
    val aliases = LAUNCHER_ICON_ALIASES.map { it.second }
    assertEquals(modes.size, modes.toSet().size)
    assertEquals(aliases.size, aliases.toSet().size)
    assertTrue(modes.contains("light"))
    assertTrue(modes.contains("dark"))
    aliases.forEach { alias ->
      assertTrue("alias should be a manifest-relative name: $alias", alias.startsWith("."))
    }
  }
}
