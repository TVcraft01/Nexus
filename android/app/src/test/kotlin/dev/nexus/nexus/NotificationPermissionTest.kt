package dev.nexus.nexus

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// The ask must fire exactly on Android 13+ with POST_NOTIFICATIONS still off.
/// One API level off in either direction and the foreground service's ongoing
/// notification either stays silently hidden (below 13 the permission does not
/// exist, so asking would be meaningless) or the user is nagged for something
/// they already allowed.
class NotificationPermissionTest {
  @Test
  fun `asks on Android 13 and up while the permission is off`() {
    assertTrue(needsNotificationPermission(33, alreadyGranted = false))
    assertTrue(needsNotificationPermission(34, alreadyGranted = false))
    assertTrue(needsNotificationPermission(36, alreadyGranted = false))
  }

  @Test
  fun `never asks before Android 13`() {
    assertFalse(needsNotificationPermission(32, alreadyGranted = false))
    assertFalse(needsNotificationPermission(24, alreadyGranted = false))
  }

  @Test
  fun `never asks once it is granted`() {
    assertFalse(needsNotificationPermission(33, alreadyGranted = true))
    assertFalse(needsNotificationPermission(36, alreadyGranted = true))
  }
}
