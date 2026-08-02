package com.nexus.app.hardware

enum class ExecutionMode(
    val displayName: String,
    val description: String
) {
    THIN_NODE(
        displayName = "Thin-Node Mode",
        description = "Low-memory device. Zero-LLM deterministic command relay."
    ),
    STANDARD_EDGE(
        displayName = "Standard Edge Mode",
        description = "Local lightweight SLM execution hooks enabled."
    )
}
