package com.nexus.app.ui

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MainActivityQrFlowTest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun qrPairingDialogOpensFromMeshTab() {
        composeTestRule.onNodeWithText("Devices", useUnmergedTree = true).performClick()
        composeTestRule.onNodeWithText("Pair device").performClick()
        composeTestRule.onNodeWithText("Pair a device").assertExists()
    }
}
