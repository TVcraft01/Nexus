package com.nexus.app.command

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ZeroLLMCommandEngineTest {

    private fun parse(input: String) = ZeroLLMCommandEngine.parseCommand(input)

    @Test
    fun `empty input returns null`() {
        assertNull(parse(""))
        assertNull(parse("   "))
    }

    @Test
    fun `system toggles`() {
        assertEquals(CommandAction.ToggleWifi(true), parse("turn on wifi"))
        assertEquals(CommandAction.ToggleWifi(false), parse("turn off wifi"))
        assertEquals(CommandAction.ToggleBluetooth(true), parse("turn on bluetooth"))
        assertEquals(CommandAction.ToggleFlashlight(true), parse("turn on flashlight"))
        assertEquals(CommandAction.ToggleDnd(true), parse("turn on do not disturb"))
    }

    @Test
    fun `volume and brightness`() {
        assertEquals(CommandAction.SetVolume(75), parse("set volume to 75"))
        assertEquals(CommandAction.SetBrightness(50), parse("set brightness to 50"))
    }

    @Test
    fun `media commands`() {
        assertEquals(CommandAction.PlayMedia("thriller"), parse("play thriller"))
        assertEquals(CommandAction.PlayMediaApp("thriller", "spotify"), parse("play thriller on spotify"))
        assertEquals(CommandAction.MediaControl("next"), parse("next track"))
        assertEquals(CommandAction.MediaControl("previous"), parse("previous song"))
        assertEquals(CommandAction.PauseMedia(""), parse("pause music"))
    }

    @Test
    fun `timers and alarms`() {
        assertEquals(CommandAction.SetTimer(60), parse("set a timer for 60 seconds"))
        assertEquals(CommandAction.SetAlarm(7, 0), parse("set an alarm for 7 am"))
        assertEquals(CommandAction.CancelAlarmTimer(), parse("cancel my timer"))
        assertEquals(CommandAction.GetNextAlarm(), parse("next alarm"))
    }

    @Test
    fun `camera and notes`() {
        assertEquals(CommandAction.OpenCamera(true), parse("take a selfie"))
        assertEquals(CommandAction.OpenCamera(false), parse("take a picture"))
        assertEquals(CommandAction.RecordVideo(), parse("record a video"))
        assertEquals(CommandAction.TakeNote("buy milk"), parse("take a note buy milk"))
    }

    @Test
    fun `lists reminders and knowledge`() {
        assertEquals(CommandAction.ListAction("milk", "shopping"), parse("add milk to my shopping list"))
        assertEquals(CommandAction.SetReminder("call mom"), parse("remind me to call mom"))
        assertEquals(CommandAction.SearchInfo("gravity", "Define"), parse("define gravity"))
        assertEquals(CommandAction.SearchInfo("Mississippi", "Spell"), parse("how do you spell Mississippi"))
    }

    @Test
    fun `navigation and calendar`() {
        assertEquals(CommandAction.Navigate("Paris"), parse("navigate to Paris"))
        assertEquals(CommandAction.OpenCalendar(), parse("open calendar"))
        assertTrue(parse("what's on my calendar today") is CommandAction.GetTodaySchedule)
    }

    @Test
    fun `calculations and utilities`() {
        assertTrue(parse("calculate 5 plus 3") is CommandAction.Calculate)
        assertTrue(parse("roll dice") is CommandAction.RollDice)
        assertTrue(parse("flip a coin") is CommandAction.FlipCoin)
    }

    @Test
    fun `communications`() {
        assertEquals(CommandAction.CallContact("mom"), parse("call mom"))
        assertEquals(CommandAction.SendText("john", "hello"), parse("text john saying hello"))
        assertEquals(CommandAction.SendEmail("bob@example.com"), parse("email bob@example.com"))
    }

    @Test
    fun `unknown command`() {
        assertNull(parse("do the impossible"))
    }
}
