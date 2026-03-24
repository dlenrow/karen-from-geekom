# Architecture: Zero-Trust Inference Control Plane on BlueField DPU

## Project Summary

Replace the permissive, unauthenticated x86 RDMA control plane in GPU inference
clusters with a **security-first, policy-based, default-deny control plane
running on BlueField DPU ARM cores**, delivered as a BFB virtual appliance.

**One-liner:** Move the inference control plane from the untrusted x86 host
onto the NIC card (BlueField), where it enforces zero-trust on all RDMA
traffic before it reaches the GPUs.

## Key Decisions (Chronological)

### Decision 1: Target is BlueField DPU mode, NOT SH (self-hosted)

**Context:** Initially designed for BF-3 SH (B3220SH) where ARM cores own GPU
via PCIe root complex. Discovered that standard 8xH200 HGX nodes ship with
B3220 DPUs (endpoint mode), not SH.

**Decision:** Target standard **B3220 in DPU mode**. ARM cores run control
plane + security. x86 host runs inference workers + CUDA. BF-3 is the network
security gateway, not the GPU host.

**Rationale:**
- B3220 DPU already ships in HGX H200 trays (1:1 GPU-to-NIC ratio)
- No hardware swap needed — use what's already installed
- DPU mode gives ARM cores full control of NIC (ECPF ownership)
- Representor ports give visibility into all traffic flowing through NIC
- x86 host becomes untrusted compute-only; BF-3 enforces policy

**Implications:**
- No CUDA on ARM cores (GPU not on BF-3 PCIe root complex)
- No GDAKI backend (requires SH mode)
- Inference workers on x86 host, control plane on BF-3 ARM
- BF-3 is bump-in-the-wire security enforcer

### Decision 2: foil-cilium replaces custom security stack

**Context:** Originally designed custom OPA Rego policies, standalone DOCA
IPsec, custom audit logger, custom RDMA access control.

**Decision:** Use **foil-cilium** (custom Cilium fork with RDMA/ibverbs
awareness) on **K3s** as the primary security and observability layer.

**What foil-cilium replaces:**
| Custom Component | Replaced By |
|---|---|
| OPA Rego default-deny | CiliumNetworkPolicy on RoCE v2 (UDP 4791) |
| Custom ibverbs ACL | CNP `allowedVerbs` / `deniedVerbs` |
| Custom audit logger | Hubble RDMA flow records |
| Standalone DOCA IPsec | Cilium transparent encryption (ConnectX HW offload) |
| Custom RDMA rate limiting | CNP `rdma.rateLimit` per verb per identity |

**What remains (below Cilium, can't be replaced):**
| Component | Why |
|---|---|
| DOCA Flow DMA firewall | PCIe transaction filtering — hardware level |
| GPU CC attestation | SPDM verification — hardware protocol |
| BF-3 DICE boot chain | Hardware root of trust |
| SPIRE agent | Provides SPIFFE SVIDs consumed by foil-cilium |

**Why foil-cilium works on BF-3:**
- RoCE v2 = UDP port 4791 — Cilium sees this on representor ports
- BF-3 DPU mode: ARM cores own the NIC, eBPF/XDP hooks on representor
  ports see all traffic before it hits the RDMA fast path
- ibverbs policing is a foil-cilium extension (NOT upstream Cilium)
- K3s is lightweight enough for 8-16 ARM cores

### Decision 3: BF-2 as development target

**Context:** BF-2 available in home lab. BF-3 in production HGX.

**Decision:** Develop and debug on **BF-2 in DPU mode**. Deploy on BF-3.

**Why it works:**
- DOCA SDK guarantees source + binary compatibility across BF-2/BF-3
- Same representor port architecture, same ECPF ownership model
- Same eBPF/XDP hooks, same DPU mode networking
- BF-2 has 8x A72 cores (vs BF-3 16x A78) — tighter but sufficient for CP
- BF-2 has hardware IPsec offload (ConnectX-6 Dx)
- Only BF-3-specific features missing: DPA, GDAKI — not in security path

**BF-2 dev topology:**
```
BF-2 (home lab, DPU mode)              GPU box (any x86+GPU)
┌──────────────────────┐               ┌──────────────────┐
│ K3s + foil-cilium    │               │ SGLang/vLLM      │
│ CNP default-deny     │◄── RDMA ────►│ (inference)      │
│ Hubble RDMA audit    │  (encrypted)  │ NIXL agent       │
│ Dynamo CP (router,   │               │ x86 host         │
│   frontend, KVBM)    │               │                  │
│ SPIRE agent          │               │                  │
└──────────────────────┘               └──────────────────┘
  8x A72, 200Gb/s                       GPU + x86 CPU
  Control plane only                    Compute only
```

### Decision 4: No Grace CPU — BF-3 only

**Context:** Initially planned for BF-3 SuperNIC with Grace CPU (Neoverse V2).

**Decision:** Grace CPU is not the target. BlueField-3 DPU ARM cores (A78)
are the target. The project name "grace-cpu-port" is a misnomer from early
planning — this is a BlueField DPU project.

## Production Architecture

```
8x H200 HGX Node (Production)
┌──────────────────────────────────────────────────────────────┐
│  x86 Host (UNTRUSTED — compute only)                        │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐               │
│  │ H200-0 │ │ H200-1 │ │  ...   │ │ H200-7 │  8x GPU      │
│  │ decode │ │prefill │ │        │ │ decode │  CC TEE       │
│  └───┬────┘ └───┬────┘ └───┬────┘ └───┬────┘               │
│      │          │          │          │    PCIe Gen5        │
│  ┌───┴────┐ ┌───┴────┐ ┌───┴────┐ ┌───┴────┐               │
│  │ BF3-0  │ │ BF3-1  │ │  ...   │ │ BF3-7  │  8x BF-3 DPU │
│  │ DPU    │ │ DPU    │ │        │ │ DPU    │  (B3220)      │
│  └───┬────┘ └───┬────┘ └───┬────┘ └───┬────┘               │
│      │          │          │          │    400Gb RDMA       │
└──────┼──────────┼──────────┼──────────┼─────────────────────┘
       │          │          │          │
       └──────────┴──────────┴──────────┘
                  RDMA Fabric

On EACH BF-3 DPU (ARM cores, DPU mode):
┌──────────────────────────────────────┐
│  K3s + foil-cilium                   │
│  ├── CNPs: default-deny RDMA         │
│  ├── ibverbs policing (WRITE/SEND)   │
│  ├── Hubble: RDMA flow audit         │
│  ├── SPIFFE mTLS (DICE-backed)       │
│  ├── IPsec encrypted RoCE v2         │
│  ├── Dynamo router + frontend        │
│  ├── KVBM (KV block manager)         │
│  └── NIXL control (metadata only)    │
│                                      │
│  DOCA (below K8s):                   │
│  ├── DMA firewall (PCIe filtering)   │
│  └── Representor port hooks          │
│                                      │
│  Hardware:                           │
│  ├── DICE secure boot                │
│  ├── ConnectX-7 (crypto offload)     │
│  └── Hardware root of trust          │
└──────────────────────────────────────┘
```

**Data flow (zero-trust enforced):**
```
Client request:
  Client → mTLS → BF-3 DPU → CNP check → SPIFFE verify →
  IPsec encrypt → fabric → peer BF-3 → CNP check →
  Hubble audit → DOCA Flow firewall → x86 host → GPU TEE

Every hop: authenticated, encrypted, authorized, audited.
```

## Transport Security: Two Layers

### Decision 5: mTLS for API path, IPsec for RDMA bulk

**Context:** IPsec encrypts the pipe (node-to-node). mTLS encrypts the
conversation (per-connection, per-identity). LLM inference turns need
identity-bound, per-request auth — not just encrypted packets.

**Decision:** Use **mTLS** for the inference API path (user ↔ frontend ↔ GPU
TEE). Use **IPsec** for inter-node RDMA (KV cache bulk transfer).

```
Client ──[mTLS/TLS 1.3]──► BF-3 Frontend (port 8000)
  │ Per-turn: client SVID verified, L7 policy, Hubble audit
  │ Prompt encrypted to service identity, not just to node
  │ Client cert carries tenant claims, individually revocable
  │
BF-3 ──[CNP-isolated, cleartext]──► BF-3 (RDMA KV cache)
  │ foil-cilium CNPs enforce who can RDMA to whom (ibverbs level)
  │ No dataplane encryption — 800G optical fabric, no sniffing risk
  │ Zero CPU overhead, zero added latency
```

**Why mTLS for API:**
- Per-connection identity (SPIFFE SVID), per-turn auth
- L7 visibility — Cilium/Envoy can inspect HTTP method/path/headers
- Per-tenant rate limiting keyed on client cert
- Individual revocation without tearing down all traffic
- Hubble records who asked what (metadata, not content)

**Why NO encryption on RDMA dataplane:**
- CNPs isolate RDMA users at ibverbs level — access control is the real need
- BF-3 DPU is the drop-in trust boundary — it IS the enforcement point
- 800G optical fabric — nobody is sniffing it
- IPsec/WireGuard burns ARM cores and adds latency for zero security gain
- Encryption is not a substitute for access control, and access control
  is not a substitute for encryption. Here only access control matters.

## Security Layers

| Layer | Technology | Enforcement Point |
|---|---|---|
| 1. Hardware Root of Trust | BF-3 DICE, secure boot | ROM / firmware |
| 2. Identity | SPIFFE/SPIRE + DICE certs | foil-cilium mTLS |
| 3. Network Policy | foil-cilium CNPs (default-deny) | eBPF on representor ports |
| 4. RDMA Policy | foil-cilium ibverbs policing | eBPF datapath |
| 5. API Encryption | mTLS / TLS 1.3 (per-turn, to TEE) | Cilium L7 proxy |
| 6. RDMA Dataplane | CNP isolation (no encryption) | eBPF datapath |
| 7. DMA Firewall | DOCA Flow rules | NIC firmware |
| 8. GPU Protection | CC TEE (H200 CPR) | GPU hardware |
| 9. Observability | Hubble (L7 + RDMA flows) + Prometheus | eBPF datapath |

## Software Stack

| Component | Version/Notes | Runs On |
|---|---|---|
| K3s | Lightweight K8s | BF-3 ARM cores |
| foil-cilium | Custom Cilium fork (RDMA-aware) | BF-3 ARM cores |
| Hubble | Cilium observability | BF-3 ARM cores |
| SPIRE | SPIFFE identity provider | BF-3 ARM cores |
| Dynamo | Router, Frontend, KVBM (control plane) | BF-3 ARM cores |
| NIXL | UCX backend (data plane) | Both (metadata on BF-3) |
| SGLang/vLLM | Inference engine | x86 host + GPU |
| DOCA SDK | DMA firewall, IPsec, representors | BF-3 firmware + ARM |

## Delivery: BFB Virtual Appliance

Ships as a **BFB (BlueField Boot Stream)** image. Flash and boot.

```
bfb-install --bfb dynamo-zt-appliance.bfb --rshim /dev/rshim0
```

BFB contains: Ubuntu 24.04 aarch64, K3s, foil-cilium, Dynamo CP, NIXL,
SPIRE, DOCA, CNP policies, Hubble config, DMA firewall rules.

Boot sequence: secure boot → DICE chain → DOCA Flow default-deny →
K3s → foil-cilium CNPs → IPsec SAs → SPIRE → Dynamo → ready.

## File Map

```
grace-cpu-port/
├── ARCHITECTURE.md              ← This file
├── SECURITY_ARCHITECTURE.md     ← Detailed security layer design
├── PORT_PLAN.md                 ← Build/port instructions (needs update for DPU mode)
│
├── k3s/                         ← K3s + foil-cilium deployment
│   ├── k3s-bf3sh-config.yaml   ← K3s server config for BF DPU
│   ├── cilium/
│   │   ├── values-bf3sh.yaml    ← foil-cilium Helm values
│   │   ├── cnp-rdma-default-deny.yaml  ← Default-deny + RDMA allow rules
│   │   └── cnp-ibverbs-audit.yaml      ← ibverbs audit + rate limiting
│   └── hubble/
│       └── hubble-rdma-config.yaml     ← RDMA flow export + metrics
│
├── dynamo/                      ← Dynamo control plane
│   ├── dynamo-bf3-config.yaml   ← Full stack config (security + inference)
│   ├── build-dynamo-arm64.sh    ← Build script for aarch64
│   └── Dockerfile.arm64         ← Container image
│
├── nixl/                        ← NIXL data transfer library
│   ├── nixl-bf3-config.yaml     ← UCX + GDAKI config
│   ├── build-nixl-arm64.sh      ← Build script
│   └── Dockerfile.arm64         ← Container image
│
├── k8s/                         ← K8s manifests (legacy, pre-K3s)
│   ├── namespace.yaml
│   ├── bf3-control-plane.yaml   ← DaemonSet for BF-3 nodes
│   └── gpu-workers.yaml         ← Multi-node disaggregated
│
├── security/                    ← Security layer configs
│   ├── dma-firewall/            ← DOCA Flow rules (PCIe level)
│   ├── identity/                ← SPIRE agent config
│   ├── gpu-attestation/         ← GPU CC verification
│   ├── ipsec/                   ← DOCA IPsec (fallback)
│   ├── policies/                ← OPA Rego (superseded by CNPs)
│   └── audit/                   ← Custom audit (superseded by Hubble)
│
├── bfb/                         ← BFB virtual appliance builder
│   └── build-bfb.sh            ← Creates flashable BFB image
│
├── scripts/                     ← Setup and build orchestration
│   ├── build-all-arm64.sh       ← Master build script
│   ├── setup-bf3-sh-gpu.sh      ← BF-3 SH GPU setup (for SH variant)
│   └── verify-bf3-env.sh        ← Environment verification
│
└── connection-manager/          ← Dynamo connection manager config
    ├── connection-manager-bf3.yaml
    └── setup-etcd-arm64.sh
```

## Open Items

1. **Rearchitect for DPU mode** — Current configs assume SH (root complex).
   Need to update for standard B3220 DPU mode where x86 host runs inference
   and BF-3 runs only control plane + security.

2. **foil-cilium build for ARM64** — Need to build and validate foil-cilium
   on BF-2 A72 cores. Verify eBPF/XDP works on representor ports.

3. **BF-2 dev environment** — Set up K3s + foil-cilium on BF-2 in home lab.
   Mock inference backend for control plane testing.

4. **BFB image build pipeline** — Integrate K3s + foil-cilium into BFB
   builder. Test flash/boot cycle.

5. **GPU CC attestation via DPU** — Verify BF-3 DPU can verify H200 CC
   attestation reports over PCIe (not just SH mode).

6. **Performance baseline** — Measure overhead of foil-cilium CNP enforcement
   on RDMA throughput (latency and bandwidth impact).
