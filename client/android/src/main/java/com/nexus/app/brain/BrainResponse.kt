package com.nexus.app.brain

import com.nexus.app.command.CommandAction
import com.nexus.app.command.CommandResult

data class BrainResponse(
    val text: String,
    val action: CommandAction? = null,
    val actionResult: CommandResult? = null,
    val requiresConfirmation: Boolean = false
)
