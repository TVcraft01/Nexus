# Nexus Server - Python Orchestration Layer
#
# This is the high-level Python server that orchestrates the Nexus ecosystem.
# It wraps the Rust `nexus-core` for performance-critical operations while
# providing the flexibility of Python for:
# - LLM/AI integration (Ollama, Transformers, Vosk)
# - GUI components (CustomTkinter)
# - Device driver abstractions
# - User-facing APIs

__version__ = "0.3.0"
__protocol_version__ = 1
