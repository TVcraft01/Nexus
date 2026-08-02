# Nexus — The Universal, Local AI Orchestrator

**Version:** 0.3.0  
**Status:** Phase 1 — Core NLP Engine & Local Data Storage

Nexus is a privacy-first, self-contained AI system that acts as the bridge between you and your digital/physical environment. No cloud required. Your data stays yours.

## Core Principles

- **Absolute Privacy (Local-Only):** All data stays on your devices. Zero cloud dependency.
- **Adaptive Footprint:** Runs on everything from a smart lightbulb to a gaming PC.
- **Universal Control:** Connect and orchestrate any device with CPU/RAM/Storage.

## Architecture

```
nexus/
├── core/          # Rust engine (crypto, mesh, discovery, executor, security)
├── server/        # Python orchestration layer (AI, brain, API, devices)
├── models/        # Shared model configs & prompts
├── client/        # Client apps (desktop GUI, CLI, Android)
├── scripts/       # Build & install
└── docs/          # Documentation
```

## Quick Start

### Desktop Server

```bash
cd server
pip install -e .
nexus
```

### With GUI

```bash
pip install -e ".[full]"
nexus
```

### Headless mode

```bash
nexus --headless --port 9090
```

## Why Nexus?

- **No cloud required** — on-device voice, LLM, and vision.
- **Learns from you** — routine detection, proactive reminders.
- **Universal mesh** — encrypted peer-to-peer device networking.
- **Extensible** — Python + Rust architecture, modular design.
- **Open source** — MIT license.

## What It Does

- Natural language commands (regex + LLM)
- Device orchestration across the mesh
- Routine learning & proactive alerts
- Computer vision for physical item location
- Network security monitoring
- Encrypted peer-to-peer communication

## Development Status

| Phase | Status |
|-------|--------|
| Phase 1: Core NLP & Storage | ✅ In Progress |
| Phase 2: Device Discovery & Dist. Execution | 🚧 Planned |
| Phase 3: Computer Vision Integration | 🚧 Planned |
| Phase 4: Routine Learning & Proactive Alerts | 🚧 Planned |

## License

MIT — See [LICENSE](LICENSE)
