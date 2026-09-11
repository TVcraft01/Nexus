# Nexus Cognitive Architecture

## Goal

Nexus is not designed as a stateless chatbot with a personality prompt. The
long-term goal is a small, local-first cognitive system whose behavior grows
from experience with the user and from the capabilities present in its
environment.

## Principles

1. **Small native core.** The phone must be sufficient to run Nexus. A large
   model is optional compute, not a hard dependency.
2. **No continuous weight training required.** Learning first happens in
   durable state: memories, social profiles, habits, and capability knowledge.
3. **Experience before memory.** Raw interactions are observations. A
   consolidation pass decides what should become durable.
4. **Sleep/consolidation.** When idle, Nexus reviews recent experience,
   strengthens repeated or important memories, and prunes weak stale state.
5. **One intelligence, many devices.** Each connected device advertises real
   capabilities. Nexus chooses where work belongs based on availability and
   user context; it must never invent a capability.
6. **Updates teach Nexus.** A software update should publish a structured
   capability/behavior change that can be incorporated into the cognitive
   state, rather than silently changing what the model is assumed to know.
7. **Social adaptation is separate from identity.** Vocabulary and style can
   adapt per person without mutating the global identity of Nexus.
8. **Inspectable learning.** Every durable learning change should eventually
   have provenance: what experience caused it, when it changed, and whether
   it was user-confirmed or inferred.

## Current implementation slice

- `core/cognitive_state.dart`: persistent data model for memories, social
  profiles, capabilities and habits.
- `core/cognitive_learning.dart`: deterministic experience observation and a
  bounded sleep/consolidation pass.
- `core/cognitive_capabilities.dart`: capability advertisement/removal and a
  compact model context generated only from known available capabilities.

This slice intentionally does **not** replace the existing conversation
engine yet. Integration should happen after its seams and persistence format
are reviewed.

## Next slices

### A. Persistence

Add a versioned `cognitive` section to `NexusStore`, with migration tests.
Never make an incompatible schema change without a migration.

### B. Experience capture

Feed successful interactions, corrections, user-confirmed preferences,
important events, and device observations into `CognitiveLearning.observe`.
Do not treat every generated sentence as a fact.

### C. Model context

Build a compact context assembler that selects only relevant memories,
the active person's social profile, current goals, and currently available
capabilities. The context budget must remain bounded for phone inference.

### D. Sleep scheduler

Run consolidation opportunistically while Nexus is idle/charging or through
an explicit background mechanism supported by the platform. The scheduler
must be safe to skip: Nexus remains usable without a sleep cycle.

### E. Distributed environment

Extend the existing mesh device metadata with resource observations and
capability advertisements. Keep execution behind the existing device
executor and permission gates.

### F. Provenance and user control

Add a learning journal so the user can inspect, accept, correct, or forget
learned state. Model-generated guesses must not silently become authoritative
facts.

## What this is not

This architecture does not claim to reproduce a biological human brain. It is
an engineering approximation of selected mechanisms: episodic experience,
long-term memory, consolidation, social adaptation, habit formation and
context-sensitive action selection.
