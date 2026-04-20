# Nexus Architecture

## Layers

```
┌──────────────────────────────┐
│         Skills Layer         │  ← modular, sandboxed, community-built
├──────────────────────────────┤
│          Core Layer          │  ← memory, skill loader, conversation loop
├──────────────────────────────┤
│          Seed Layer          │  ← installer, hardware detection, first launch
├──────────────────────────────┤
│     Ollama / Local Model     │  ← swappable (Phi-3, Llama, TinyLlama...)
└──────────────────────────────┘
```

## Memory Tiers

| Tier | Persistence | Purpose |
|------|-------------|---------|
| core_memory | Forever | Name, language, identity |
| long_memory | Fades if unused | Learned facts about the user |
| working_memory | Session only | Current conversation |

## Model Selection

| RAM | Model |
|-----|-------|
| < 2GB | tinyllama |
| 2–4GB | phi3:mini |
| 4–8GB | phi3:medium |
| 8GB+ | llama3.2 |

## Planned Phases

- Phase 3 — Device mesh (mDNS peer discovery, idle compute sharing)
- Phase 4 — Remote access (WireGuard tunnel, no cloud relay)
- Phase 5 — Community skill registry (GitHub + auto PR safety gate)
