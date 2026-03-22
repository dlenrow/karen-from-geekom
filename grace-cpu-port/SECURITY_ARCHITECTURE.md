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

```
TARGET STATE (SECURE):

  Client ──── mTLS ────► BF-3 SH (Trust Anchor) ────► GPU TEE
                         │                              │
                         │ Zero-trust control plane:    │ CC TEE protects
                         │ • Default-DENY               │ model weights &
                         │ • SPIFFE identity + DICE     │ compute
                         │ • Encrypted RDMA (IPsec)     │
                         │ • Policy engine (OPA)        │ Attestation chain:
                         │ • DMA firewall               │ BF-3 attests GPU
                         │ • Hardware root of trust     │ GPU attests to BF-3
                         │ • Audit logging              │
                         │ • BF-3 IS the host           │
                         └──────────────────────────────┘

  BF-3 SH owns the PCIe root complex. ALL traffic to/from GPU goes through
  the BF-3. The x86 host is ELIMINATED. BF-3 is the hardware trust anchor.
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
| No authorization            | No policy enforcement    | OPA policy engine             |
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

### Layer 3: Policy Engine (Default-Deny)
```
┌────────────────────────────────────────────────────────────────┐
│                    Policy Engine                                │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  OPA (Open Policy Agent) on BF-3 ARM cores              │   │
│  │                                                         │   │
│  │  Default: DENY ALL                                      │   │
│  │                                                         │   │
│  │  Explicit allows:                                       │   │
│  │  • inference.submit: requires valid SPIFFE ID +         │   │
│  │    tenant claim + rate limit                            │   │
│  │  • kvcache.transfer: requires peer attestation +        │   │
│  │    same-cluster membership                              │   │
│  │  • model.load: requires admin SPIFFE ID +               │   │
│  │    signed model manifest                                │   │
│  │  • rdma.connect: requires mTLS + policy match           │   │
│  │  • gpu.dma: requires attestation + policy               │   │
│  │                                                         │   │
│  │  Every RDMA operation goes through policy evaluation.   │   │
│  └─────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘
```

### Layer 4: Encrypted RDMA (Wire-Speed)
```
┌────────────────────────────────────────────────────────────────┐
│              DOCA IPsec Inline Encryption                       │
│                                                                │
│  ConnectX-7 hardware crypto engine:                            │
│  • AES-256-GCM at 400Gb/s line rate                            │
│  • IPsec ESP in transport mode                                 │
│  • SA (Security Association) per peer node                     │
│  • Zero CPU overhead (hardware offload)                        │
│  • Covers ALL RDMA traffic: prompts, KV cache, metadata       │
│                                                                │
│  Before:  Prompt ──[cleartext RDMA]──► GPU                     │
│  After:   Prompt ──[AES-256-GCM ESP]──► BF-3 ──[PCIe]──► GPU  │
│                                                                │
│  Key management: IKEv2 with DICE-derived identity keys         │
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

### Layer 6: GPU TEE Integration
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
├── Ubuntu 24.04 aarch64 (minimal)
├── DOCA SDK + runtime
├── CUDA toolkit aarch64
├── NVIDIA driver aarch64
├── Dynamo (full stack, security-hardened)
├── NIXL (UCX + GDAKI + IPsec)
├── SPIRE agent + DICE attestor
├── OPA policy engine + default-deny policies
├── IPsec SA manager (DOCA crypto)
├── DMA firewall rules (DOCA Flow)
├── GPU CC attestation verifier
├── Audit logger
└── BF-3 firmware config (self-hosted mode)
```

Flash: `bfb-install --bfb dynamo-zt-appliance.bfb --rshim /dev/rshim0`

Boot sequence:
1. Secure boot → measured boot → DICE cert chain
2. DOCA Flow default-deny rules loaded in NIC firmware
3. IPsec SAs negotiated with peer BF-3 nodes (IKEv2 + DICE keys)
4. SPIRE agent registers, gets SVID from SPIRE server
5. GPU CC attestation verified (SPDM session)
6. OPA policy engine loaded with default-deny + explicit allows
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

### After (BF-3 SH Zero-Trust Appliance)
```
Prompt journey:
  User → mTLS → BF-3 → OPA policy check → SPIFFE ID verified →
  IPsec encrypt → ConnectX-7 → DOCA Flow firewall → GPU TEE →
  decrypt in CPR → inference → encrypt result → BF-3 → mTLS → User

  Every hop authenticated. Every byte encrypted. Every action authorized.
  Default-deny. Hardware root of trust. No x86 in the path.
```
