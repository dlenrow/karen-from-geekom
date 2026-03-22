# Zero-Trust Inference Appliance on BF-3 SH

## The Problem

Current confidential inference deployments (e.g., on 8xH200 Grace Hopper nodes)
have a **critical architectural flaw**: the x86 host CPU runs the RDMA control
plane with **no authentication, no encryption, no access control**.

```
CURRENT STATE (BROKEN):

  Client ──── RDMA (cleartext) ────► x86 Host CPU ──── PCIe ────► GPU TEE
                                     │                              │
                                     │ RDMA control plane:          │ CC TEE protects
                                     │ • Default-allow              │ model weights &
                                     │ • No authentication          │ compute only
                                     │ • Cleartext prompts          │
                                     │ • No policy enforcement      │
                                     │ • Any peer can DMA to GPU    │
                                     │ • Host is UNTRUSTED          │
                                     │                              │
                                     └── THE GAP ──────────────────┘

  Even with H200 CC TEE protecting decode, the control plane is wide open.
  Prompts are cleartext on the wire. Any compromised host can RDMA into GPU HBM.
  The x86 host — which CC's own threat model says is UNTRUSTED — runs the
  control plane that decides who gets to talk to the GPU.
```

## What This Project Does

Replace the x86 RDMA control plane with a **hardware-enforced zero-trust
control plane running on BF-3 SH**, delivered as a BFB virtual appliance.

**Security stack:** foil-cilium (custom Cilium fork with RDMA/ibverbs awareness)
on K3s, providing CNP-based default-deny, Hubble RDMA observability, SPIFFE
identity, and encrypted transport — all from the control plane on the NIC card.

```
TARGET STATE (SECURE):

  Client ──── mTLS ────► BF-3 SH (Trust Anchor) ────► GPU TEE
                         │                              │
                         │  K3s + foil-cilium:          │ CC TEE protects
                         │  • CNP default-DENY on RDMA  │ model weights &
                         │  • ibverbs policing           │ compute
                         │  • Hubble RDMA flow audit     │
                         │  • SPIFFE identity + DICE     │ Attestation chain:
                         │  • IPsec encrypted RoCE       │ BF-3 attests GPU
                         │  • DOCA DMA firewall (PCIe)   │ GPU attests to BF-3
                         │  • BF-3 IS the host           │
                         └───────────────────────────────┘

  BF-3 SH owns the PCIe root complex. ALL traffic to/from GPU goes through
  the BF-3. The x86 host is ELIMINATED. BF-3 is the hardware trust anchor.

  foil-cilium on BF-3 representor ports sees RoCE v2 (UDP 4791) + ibverbs
  operations. CNPs enforce who can RDMA what, to which memory regions, with
  which verb types. Hubble provides full RDMA flow observability.
```

## Threat Model

### Assets Protected
1. **Prompts** — user queries to LLM (PII, proprietary, regulated)
2. **Model weights** — IP in GPU HBM (protected by CC TEE)
3. **KV cache** — contains prompt context (as sensitive as prompts)
4. **Inference metadata** — routing decisions, batch composition, scheduling
5. **Control plane integrity** — who can submit inference requests

### Threat Actors
1. **Compromised host OS** — the entire x86 host stack is untrusted
2. **Rogue datacenter admin** — physical access, firmware access
3. **Compromised peer node** — lateral movement in inference cluster
4. **Network attacker** — RDMA injection, eavesdropping on fabric
5. **Malicious tenant** — multi-tenant inference, resource exhaustion

### What BF-3 SH Eliminates
| Threat                      | x86 Host (Before)        | BF-3 SH (After)              |
|-----------------------------|--------------------------|-------------------------------|
| Cleartext prompts on wire   | Exposed via RDMA         | IPsec inline encryption       |
| Unauthorized GPU access     | Any RDMA peer can DMA    | DMA firewall, default-deny    |
| No authentication           | Open RDMA connections    | mTLS + SPIFFE + DICE          |
| No authorization            | No policy enforcement    | foil-cilium CNPs (ibverbs)    |
| Host compromise → GPU       | Direct PCIe access       | BF-3 owns root complex        |
| Metadata exposure           | Cleartext routing        | Encrypted control plane       |
| No audit trail              | No logging               | Hardware-backed audit log      |
| Lateral movement            | Flat RDMA fabric         | Per-node identity, isolation  |

## Architecture

### Layer 1: Hardware Root of Trust (BF-3 SH)
```
┌────────────────────────────────────────────────────────────────┐
│                    BF-3 SH Trust Anchor                        │
│                                                                │
│  ┌──────────────────┐  ┌──────────────────┐                    │
│  │  Secure Boot      │  │  DICE Identity   │                    │
│  │  Measured boot    │  │  HW device cert  │                    │
│  │  Signed firmware  │  │  Attestation     │                    │
│  └──────────────────┘  └──────────────────┘                    │
│                                                                │
│  Chain: ROM → BL1 → BL2 → BL31 → UEFI → Linux → DOCA → App   │
│  Each stage measured, each measurement in DICE certificate      │
│  chain. Remote verifier can attest full boot chain.            │
└────────────────────────────────────────────────────────────────┘
```

### Layer 2: Identity & Authentication
```
┌────────────────────────────────────────────────────────────────┐
│                    Identity Layer                               │
│                                                                │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────────────────┐ │
│  │ SPIFFE ID   │  │ mTLS        │  │ GPU TEE Attestation    │ │
│  │             │  │             │  │                        │ │
│  │ spiffe://   │  │ BF-3 DICE   │  │ BF-3 verifies GPU     │ │
│  │ cluster/    │  │ cert as     │  │ attestation report     │ │
│  │ bf3/        │  │ client cert │  │ before allowing DMA    │ │
│  │ node-{id}   │  │             │  │ to GPU HBM             │ │
│  └─────────────┘  └─────────────┘  └────────────────────────┘ │
│                                                                │
│  Every connection authenticated. Every peer verified.          │
│  BF-3 DICE cert → SPIFFE SVID → mTLS to all peers.            │
│  GPU CC attestation verified before any prompt delivery.       │
└────────────────────────────────────────────────────────────────┘
```

### Layer 3: Policy Engine — foil-cilium CNPs (Default-Deny)
```
┌────────────────────────────────────────────────────────────────┐
│        foil-cilium CiliumNetworkPolicies on K3s                │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  CNP: rdma-default-deny                                 │   │
│  │  Applies to: ALL pods in dynamo-inference namespace      │   │
│  │  Default: DENY all RoCE v2 (UDP 4791) ingress/egress    │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  CNP: allow-rdma-kvcache                                │   │
│  │  Explicit allow with ibverbs policing:                   │   │
│  │  • Only WRITE + SEND verbs (block READ, ATOMIC)          │   │
│  │  • Only between attested bf3sh-node endpoints            │   │
│  │  • Requires SPIFFE mutual authentication                 │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  CNP: ibverbs-audit-all                                 │   │
│  │  Hubble flow records for every RDMA verb type            │   │
│  │  Alert on unexpected ATOMIC operations                   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  CNP: rdma-rate-limit                                   │   │
│  │  Per-identity rate limits on WRITE/SEND ops/sec          │   │
│  │  Prevents RDMA-level DoS                                 │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                │
│  Why CNPs instead of OPA:                                      │
│  • Enforced in eBPF datapath — no userspace round-trip         │
│  • Identity-aware (SPIFFE SVIDs via Cilium)                    │
│  • ibverbs verb-level granularity (foil-cilium extension)      │
│  • Hubble integration for free audit trail                     │
│  • K8s-native — declarative, version-controlled, auditable     │   │
└────────────────────────────────────────────────────────────────┘
```

### Layer 4: Encrypted RDMA — foil-cilium + DOCA IPsec
```
┌────────────────────────────────────────────────────────────────┐
│        Encrypted RDMA (foil-cilium IPsec + ConnectX-7 HW)      │
│                                                                │
│  Two options (both enforced by foil-cilium):                   │
│                                                                │
│  Option A: foil-cilium transparent IPsec                       │
│  • Cilium manages IPsec SAs between nodes                      │
│  • ConnectX-7 hardware offloads AES-256-GCM                    │
│  • Applied per-identity (SPIFFE SVID keying)                   │
│  • RoCE v2 packets encrypted before hitting wire               │
│                                                                │
│  Option B: DOCA IPsec inline (standalone)                      │
│  • Direct DOCA API for SA management                           │
│  • Full 400Gb/s line rate AES-256-GCM                          │
│  • IKEv2 with DICE-derived identity keys                       │
│                                                                │
│  Either way:                                                   │
│  Before:  Prompt ──[cleartext RDMA]──► GPU                     │
│  After:   Prompt ──[AES-256-GCM ESP]──► BF-3 ──[PCIe]──► GPU  │
│                                                                │
│  Hubble shows encryption_status per flow — alerts on cleartext │
└────────────────────────────────────────────────────────────────┘
```

### Layer 5: DMA Firewall
```
┌────────────────────────────────────────────────────────────────┐
│              DMA Firewall (DOCA Flow + PCIe ACS)               │
│                                                                │
│  BF-3 root complex controls ALL PCIe transactions to GPU:      │
│                                                                │
│  ┌─────────────────────────────────┐                           │
│  │  DOCA Flow Rules:              │                            │
│  │                                │                            │
│  │  DEFAULT: DROP                 │                            │
│  │                                │                            │
│  │  ALLOW: ConnectX-7 → GPU       │  Only authenticated RDMA  │
│  │    IF: IPsec SA valid          │  from verified peers       │
│  │    IF: OPA policy permits      │  through policy engine     │
│  │    IF: peer attested           │                            │
│  │                                │                            │
│  │  ALLOW: ARM cores → GPU        │  Local CUDA from BF-3     │
│  │    (always, local inference)   │                            │
│  │                                │                            │
│  │  DENY: all other DMA          │  No unauthorized PCIe      │
│  │                                │  transactions to GPU       │
│  └─────────────────────────────────┘                           │
│                                                                │
│  Hardware-enforced: even if BF-3 Linux is compromised,         │
│  DOCA Flow rules persist in ConnectX-7 firmware.               │
└────────────────────────────────────────────────────────────────┘
```

### Layer 6: Observability — Hubble RDMA Flow Visibility
```
┌────────────────────────────────────────────────────────────────┐
│              Hubble RDMA Observability (foil-cilium)            │
│                                                                │
│  foil-cilium extends Hubble with RDMA flow records:            │
│                                                                │
│  Per-flow metadata:                                            │
│  • Source/destination SPIFFE identity                           │
│  • RDMA verb type (WRITE, READ, SEND, ATOMIC)                  │
│  • QP number, R_Key (memory region), transfer size             │
│  • CNP verdict (ALLOW / DENY / AUDIT)                          │
│  • Encryption status (IPsec SA active or cleartext)            │
│  • Policy name that matched                                    │
│                                                                │
│  Alerts:                                                       │
│  • ATOMIC verbs detected (never expected in inference)          │
│  • Unauthenticated RDMA flow (no SPIFFE ID)                    │
│  • Cleartext flow (missing encryption)                         │
│  • Policy drop spike (possible attack)                         │
│                                                                │
│  Metrics exported to Prometheus:                                │
│  • rdma_ops_total{verb, src_identity, dst_identity}            │
│  • rdma_bytes_total{verb, direction}                           │
│  • rdma_policy_drops_total{policy_name}                        │
│  • rdma_kvcache_transfer_duration_seconds                      │
│                                                                │
│  This replaces custom audit logging — Hubble IS the audit.     │
└────────────────────────────────────────────────────────────────┘
```

### Layer 7: GPU TEE Integration
```
┌────────────────────────────────────────────────────────────────┐
│              GPU Confidential Computing Integration            │
│                                                                │
│  BF-3 SH ←──── attestation ────→ H200 GPU TEE                 │
│                                                                │
│  1. BF-3 verifies GPU CC attestation report (SPDM)            │
│  2. GPU verifies BF-3 DICE certificate chain                  │
│  3. Mutual attestation establishes encrypted channel           │
│  4. Prompts encrypted by BF-3 → decrypted in GPU TEE          │
│  5. KV cache encrypted in GPU CPR (Compute Protected Region)  │
│  6. Results encrypted by GPU TEE → decrypted by BF-3           │
│                                                                │
│  End-to-end: Client ←[mTLS]→ BF-3 ←[AES-GCM]→ GPU TEE        │
│  Prompt NEVER in cleartext outside of TEE boundary.            │
└────────────────────────────────────────────────────────────────┘
```

## Delivery: BFB Virtual Appliance

The entire stack ships as a **BFB (BlueField Boot Stream)** image — a
self-contained virtual appliance that boots the BF-3 into a fully
configured zero-trust inference node.

```
BFB Image Contents:
├── Ubuntu 24.04 aarch64 (minimal, hardened)
├── K3s (lightweight K8s for 16 ARM cores)
├── foil-cilium (RDMA-aware CNI — custom, not upstream)
│   ├── CNPs: default-deny RDMA + ibverbs policing
│   ├── Hubble: RDMA flow observability + audit
│   ├── SPIFFE mutual authentication
│   └── IPsec transparent encryption
├── DOCA SDK + runtime
├── CUDA toolkit aarch64
├── NVIDIA driver aarch64
├── Dynamo (full stack, security-hardened)
├── NIXL (UCX + GDAKI)
├── SPIRE agent + BF-3 DICE attestor
├── DOCA Flow DMA firewall rules (PCIe level)
├── GPU CC attestation verifier
└── BF-3 firmware config (self-hosted mode)

Removed (replaced by foil-cilium):
  ✗ OPA policy engine → CNPs with ibverbs rules
  ✗ Custom audit logger → Hubble RDMA flow export
  ✗ Standalone IPsec config → Cilium transparent encryption
  ✗ Custom RDMA access control → CNP default-deny
```

Flash: `bfb-install --bfb dynamo-zt-appliance.bfb --rshim /dev/rshim0`

Boot sequence:
1. Secure boot → measured boot → DICE cert chain
2. DOCA Flow default-deny rules loaded in NIC firmware (PCIe DMA level)
3. K3s starts → foil-cilium CNI initializes
4. CNP default-deny applied (no RDMA until explicitly allowed)
5. foil-cilium IPsec SAs negotiated with peer BF-3 nodes
6. SPIRE agent registers, gets SVID → Cilium picks up SPIFFE identity
7. Dynamo services start (control plane + inference workers)
8. Node joins inference cluster via authenticated discovery

## Comparison: Before and After

### Before (x86 Host RDMA Control Plane)
```
Prompt journey:
  User → HTTP → x86 host → RDMA (CLEARTEXT) → NIC → GPU HBM
                                                  ↑
                                        No auth, no encryption,
                                        any peer can inject RDMA,
                                        host compromise = game over
```

### After (BF-3 SH Zero-Trust Appliance with foil-cilium)
```
Prompt journey:
  User → mTLS → BF-3 K3s pod → CNP policy check → SPIFFE verified →
  foil-cilium IPsec encrypt → ConnectX-7 → Hubble records flow →
  DOCA Flow DMA firewall → GPU TEE → decrypt in CPR → inference →
  encrypt result → BF-3 → Hubble records response → mTLS → User

  Every hop authenticated. Every byte encrypted. Every action authorized.
  Every RDMA verb audited in Hubble. Default-deny CNPs.
  Hardware root of trust. No x86 in the path.
```

## Stack Summary

```
┌─────────────────────────────────────────────────────────┐
│  BF-3 SH Zero-Trust Inference Appliance                 │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │  K3s (lightweight K8s)                          │    │
│  │  ├── foil-cilium (RDMA-aware CNI)               │    │
│  │  │   ├── CNPs: default-deny + ibverbs policing  │    │
│  │  │   ├── Hubble: RDMA flow audit + metrics      │    │
│  │  │   ├── SPIFFE: mutual auth (DICE-backed)      │    │
│  │  │   └── IPsec: encrypted RoCE v2               │    │
│  │  │                                              │    │
│  │  ├── Dynamo pods (control + inference)           │    │
│  │  │   ├── Router, Frontend, KVBM (cores 0-3)    │    │
│  │  │   └── SGLang worker (cores 4-13, GPU)        │    │
│  │  │                                              │    │
│  │  └── NIXL (UCX + GDAKI, KV cache RDMA)          │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │  DOCA (below K8s)                               │    │
│  │  ├── DMA firewall (PCIe transaction filtering)  │    │
│  │  └── GPU CC attestation verifier                │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │  Hardware                                       │    │
│  │  ├── BF-3 DICE secure boot chain               │    │
│  │  ├── ConnectX-7 (400Gb/s, crypto offload)       │    │
│  │  └── GPU on PCIe root complex (CC TEE)          │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘

Note: foil-cilium is a custom fork, not upstream Cilium.
RDMA/ibverbs awareness does not exist in upstream Cilium.
```
