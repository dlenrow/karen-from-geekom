# Project: Zero-Trust Inference Control Plane on BlueField DPU

## What This Is

A zero-trust security appliance that replaces the permissive x86 RDMA control
plane in GPU inference clusters (8xH200 HGX) with a hardened control plane
running on BlueField DPU ARM cores. Delivered as a BFB virtual appliance.

**The problem:** Current confidential inference deployments run the RDMA control
plane on x86 hosts with no auth, no encryption, no policy. Even with GPU TEE
(H200 CC), prompts are cleartext on the wire and any peer can DMA into GPU HBM.

**The solution:** Move the control plane onto the BF-3 DPU (already in the HGX
tray). foil-cilium (custom Cilium fork with RDMA/ibverbs awareness) enforces
default-deny CNPs, Hubble provides RDMA observability, SPIFFE handles identity.

## Key Files

- `grace-cpu-port/ARCHITECTURE.md` — Consolidated architecture and all decisions
- `grace-cpu-port/SECURITY_ARCHITECTURE.md` — Detailed security layer design
- `grace-cpu-port/PORT_PLAN.md` — Build/port instructions (needs update for DPU mode)
- `grace-cpu-port/k3s/` — K3s + foil-cilium configs and CNPs
- `grace-cpu-port/dynamo/` — Dynamo control plane configs
- `grace-cpu-port/bfb/` — BFB virtual appliance builder
- `MEMORY.md` — Decision log with context

## Critical Context

1. **Target hardware is standard B3220 DPU (NOT SH/self-hosted).** HGX H200
   nodes ship with B3220 in NIC tray. DPU mode, not root complex mode.
   x86 host runs inference, BF-3 ARM runs CP + security.

2. **foil-cilium is a custom Cilium fork**, not upstream. Adds RDMA/ibverbs
   awareness via representor port eBPF hooks. Upstream Cilium can't do this.

3. **BF-2 in home lab for dev/debug.** DOCA SDK is compatible across BF-2/BF-3.
   8x A72 cores, 200Gb/s. Same representor architecture.

4. **OPA is superseded by foil-cilium CNPs.** Files in security/policies/ are
   legacy. CNPs in k3s/cilium/ are current.

5. **"grace-cpu-port" is a misnomer.** No Grace CPU involved. This is a
   BlueField DPU project. Name kept for repo continuity.

## Build & Run

```bash
# Master build (native on aarch64 BF-2/BF-3)
./grace-cpu-port/scripts/build-all-arm64.sh native

# Setup BF environment
./grace-cpu-port/scripts/build-all-arm64.sh setup

# Build Docker images
./grace-cpu-port/scripts/build-all-arm64.sh docker

# Deploy to K3s
./grace-cpu-port/scripts/build-all-arm64.sh deploy

# Flash BFB appliance
bfb-install --bfb dynamo-zt-appliance.bfb --rshim /dev/rshim0
```

## Branch

Development branch: `claude/port-grace-cpu-inference-GkvDh`
