# Nexus Development Guide

## Prerequisites

- Python 3.10+
- Rust 1.75+ (optional, for core performance)
- Ollama (optional, for local LLM)

## Setup

```bash
# Clone & enter
git clone https://github.com/TVcraft01/Nexus
cd Nexus

# Install Python server
cd server
pip install -e ".[full]"
cd ..

# (Optional) Build Rust core
cd core
cargo build --release
cd ..

# Run
nexus
```

## Architecture Overview

```
User Input → Security Guard → Command Engine → Action Execution
                ↓                    ↓                ↓
            Threat Scan      Regex/LLM/Learned    System/Device
                ↓                    ↓                ↓
            Block/Allow      Intent Parser       Mesh Relay
```

## Adding a New Module

1. Create module under `server/nexus_server/<module>/__init__.py`
2. Register in `orchestrator/__init__.py`
3. Add API endpoints in `api/__init__.py`
4. Add tests in `tests/`

## Phase Roadmap

- Phase 1 ✅ Core NLP & Local Storage
- Phase 2 🚧 Device Discovery & Distributed Execution
- Phase 3 🚧 Computer Vision Integration
- Phase 4 🚧 Routine Learning & Proactive Alerts
