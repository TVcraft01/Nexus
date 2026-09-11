# Nexus Security Architecture

Security is a first-class cognitive concern. Nexus must protect its identity,
memories, paired devices, capabilities, files, and update path before it
optimizes convenience.

## Security principles

1. **Default deny.** Unknown devices, unknown actions, malformed messages, and
   unverifiable updates are rejected.
2. **Least privilege.** A capability is not automatically a permission. A
   device may advertise a capability, but execution still passes through the
   receiving device's authorization gate.
3. **User intent wins.** Nexus may automate previously approved low-risk
   behavior, but high-impact actions remain explicitly gated.
4. **Cryptographic identity.** Pairing establishes device identity; discovery
   alone never grants trust.
5. **Protect secrets at rest.** Pairing secrets and other sensitive state must
   eventually move out of the plaintext JSON store into platform secure
   storage. This is a required hardening task, not optional polish.
6. **Authenticated updates.** A version number or HTTPS download is not enough
   to trust executable code. Releases need cryptographic integrity/signature
   verification before installation.
7. **Rollback.** Failed or suspicious updates must leave a known-good version
   available.
8. **Small attack surface.** The phone core should not expose unnecessary
   listeners, permissions, services, or debugging interfaces.
9. **Continuous security awareness.** Nexus may consume trusted security
   advisories and dependency/runtime update information, summarize relevant
   changes, and propose or stage mitigations. Security intelligence is data,
   not executable instructions.
10. **No autonomous offensive behavior.** Nexus's security system is for
    detecting, preventing, containing, updating, and recovering from attacks;
    it must not turn itself into an unrestricted offensive agent.

## Current security baseline

Nexus already has useful foundations: paired traffic uses AES-GCM and HKDF,
and malformed/expired cable provisioning is rejected. The current crypto
implementation explicitly notes that the session design is not forward-secret.
That limitation must remain visible until X25519-style ephemeral key exchange
and authenticated identity binding are implemented.

The mesh already re-gates remote agent actions on the receiving device. Keep
that rule even as the cognitive layer becomes more autonomous.

## Security learning loop

```text
trusted advisories + dependency changes + local security events
                           |
                           v
                   Security observer
                           |
                 normalize + classify
                           |
                           v
                    risk assessment
                           |
              +------------+------------+
              |                         |
        safe to automate          needs approval
              |                         |
              v                         v
       staged mitigation          notify user
              |                         |
              +------------+------------+
                           v
                    verification
                           |
                    learn the result
                           |
                           v
                    sleep/consolidate
```

Security advisories must never be passed directly to a model as executable
instructions. Nexus extracts structured facts such as affected component,
severity, fixed version, source, publication time, and verification status.

## Required hardening backlog

### P0 — protect the trust root

- Replace plaintext stored pairing secrets with platform secure storage.
- Introduce per-device long-term signing/authentication keys.
- Add authenticated key exchange with forward secrecy.
- Bind sessions to authenticated device identities, not only shared pairing
  material.
- Add replay protection with monotonic/nonces and bounded clock handling.
- Audit every remote action against the receiver's local authorization policy.

### P0 — protect the update path

- Sign release manifests and artifacts.
- Verify signatures and hashes before applying an update.
- Reject unsigned or unexpectedly signed releases.
- Keep the previous known-good version for rollback.
- Separate update discovery from update execution.
- Treat security fixes as priority updates but retain a safe failure path when
  the network is unavailable.

The current updater checks GitHub releases and downloads platform artifacts;
this is useful update plumbing but is **not yet sufficient to claim a
cryptographically authenticated update chain**.

### P1 — active defense

- Add a local security event journal.
- Detect repeated failed pairing attempts.
- Detect malformed-frame floods and suspicious connection behavior.
- Rate-limit expensive operations.
- Track unexpected capability changes on paired devices.
- Quarantine a device whose identity/key changes unexpectedly.
- Surface security state to the user without exposing secrets.

### P1 — dependency and vulnerability awareness

- Periodically check trusted advisory sources and dependency metadata.
- Match advisories against Nexus's installed versions and enabled features.
- Prefer official/security-maintainer sources.
- Cache signed advisory snapshots so a transient network failure cannot erase
  the last known security state.
- Never let an advisory directly execute code or modify permissions.

### P2 — adaptive defense

The cognitive system may learn which benign patterns are normal for this
specific environment: usual devices, usual network locations, usual update
cadence, and usual resource usage. Deviations become signals for additional
verification, not automatic proof of an attack.

## Important honesty rule

Nexus should never say "fully protected" or "immune to hacking". No software
can honestly make that guarantee. The correct goal is continuous hardening:
reduce attack surface, detect anomalies, verify trust, patch known issues,
contain failures, recover safely, and keep improving.
