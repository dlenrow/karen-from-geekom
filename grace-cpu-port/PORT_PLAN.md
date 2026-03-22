# Porting Dynamo + NIXL + Connection Manager to BF-3 SH (Self-Hosted)

## Overview

Port the NVIDIA Dynamo disaggregated inference stack from x86_64 to ARM64
(aarch64) running entirely on BlueField-3 SH (B3220SH) in self-hosted mode.

The BF-3 SH operates as the **sole host processor** — its ARM cores are the
root complex owner for a GPU in an adjacent PCIe slot. There is no x86 CPU.
The BF-3 runs everything: control plane, inference workers, CUDA, networking.

**Target Hardware:**
- NVIDIA BlueField-3 SH (B3220SH) — self-hosted / root complex mode
- 16x ARM Cortex-A78 cores (ARMv8.2)
- Dual DDR5-5600 (up to 32GB, ~80 GB/s bandwidth)
- Integrated ConnectX-7 (400Gb/s RDMA)
- PCIe Gen5 x16 to adjacent GPU slot via Cabline CA-II Plus connector
- GPU controlled by BF-3 root complex (not by a separate x86 host)

**Source Repos:**
- Dynamo: https://github.com/ai-dynamo/dynamo (Rust + Python)
- NIXL: https://github.com/ai-dynamo/nixl (C++ with Python/Rust bindings)

## Architecture: BF-3 SH as Complete Inference Node

```
┌─────────────────────────────────────────────────────────────┐
│              BF-3 SH Inference Node (No x86)                │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │       BlueField-3 SH (B3220SH) — Root Complex       │   │
│  │                                                      │   │
│  │  ┌──────────────────────────────────────────────┐    │   │
│  │  │         16x ARM A78 Cores (aarch64)          │    │   │
│  │  │                                              │    │   │
│  │  │  ┌──────────┐  ┌──────────┐  ┌───────────┐  │    │   │
│  │  │  │ Dynamo   │  │ Inference│  │ NIXL      │  │    │   │
│  │  │  │ Router   │  │ Worker   │  │ Agent     │  │    │   │
│  │  │  │ Planner  │  │ (prefill │  │ (UCX +    │  │    │   │
│  │  │  │ Frontend │  │  /decode)│  │  GDAKI)   │  │    │   │
│  │  │  │ KVBM     │  │ SGLang/  │  │           │  │    │   │
│  │  │  │          │  │ vLLM     │  │           │  │    │   │
│  │  │  └──────────┘  └────┬─────┘  └─────┬─────┘  │    │   │
│  │  │                     │ CUDA          │ RDMA   │    │   │
│  │  └─────────────────────┼───────────────┼────────┘    │   │
│  │                        │               │             │   │
│  │  ┌─────────────────────┴───────┐  ┌────┴──────────┐  │   │
│  │  │  DDR5-5600 (up to 32GB)     │  │  ConnectX-7   │  │   │
│  │  │  KV cache spillover tier    │  │  400Gb/s      │  │   │
│  │  │  NIXL host memory region    │  │  RDMA/RoCE    │  │   │
│  │  └─────────────────────────────┘  └───────────────┘  │   │
│  │                                                      │   │
│  │         PCIe Gen5 x16 (Root Complex)                 │   │
│  │         via Cabline CA-II Plus connector              │   │
│  └──────────────────────┬───────────────────────────────┘   │
│                         │                                   │
│                         │ PCIe Gen5 x16                     │
│                         │                                   │
│  ┌──────────────────────┴───────────────────────────────┐   │
│  │                     GPU                              │   │
│  │          (Adjacent PCIe Slot)                        │   │
│  │                                                      │   │
│  │  ┌────────────────────────────────────────────────┐  │   │
│  │  │  HBM (GPU Memory)                              │  │   │
│  │  │  - KV cache primary tier                       │  │   │
│  │  │  - Model weights                               │  │   │
│  │  │  - Inference compute                           │  │   │
│  │  └────────────────────────────────────────────────┘  │   │
│  │                                                      │   │
│  │  CUDA kernels launched from BF-3 ARM cores           │   │
│  │  GPUDirect RDMA: ConnectX-7 ←→ GPU HBM (P2P)        │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  Network Fabric (to other BF-3 SH nodes):                   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  ConnectX-7 ──── 400Gb/s RDMA ────── Other Nodes    │   │
│  │  GPUDirect RDMA for cross-node KV cache transfer     │   │
│  │  NIXL handles: GPU↔GPU, GPU↔DDR, DDR↔DDR transfers  │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Why BF-3 SH as the Host

- **No x86 needed** — BF-3 ARM cores run everything: CUDA runtime, inference
  engines, control plane, networking stack
- **PCIe root complex** owns the GPU directly — CUDA launches from ARM cores
  just like any host CPU would
- **GPUDirect RDMA** — ConnectX-7 and GPU share the BF-3's PCIe fabric,
  enabling zero-copy GPU↔network transfers for KV cache
- **Lowest latency** — control plane and network stack on same chip, no
  PCIe hops to a separate host CPU for routing decisions
- **Density** — pack more inference nodes without x86 motherboards

## Constraints: 16 ARM A78 Cores

The BF-3 has 16 cores, not 72+ like a Grace Superchip. This means:
- CPU-bound inference pre/post-processing competes with control plane
- Tokenizer, sampling, and beam search run on limited ARM cores
- KV cache management (KVBM) and routing share the same cores
- Must be selective about which models to serve (smaller models, or
  offload compute-heavy operations to GPU)

**Mitigation:**
- Pin control plane to 2-4 cores, inference workers get the rest
- Use GPU for all heavy compute (tokenization on GPU if possible)
- Lean engine configs (SGLang preferred — lower CPU overhead than vLLM)
- Disable unnecessary features (planner autoscaling if single-node)

## Components Being Ported

### 1. NIXL (NVIDIA Inference Xfer Library)
**What it does:** High-throughput, low-latency data transfer for KV cache
movement between disaggregated prefill/decode workers across nodes.

**On BF-3 SH, NIXL handles:**
- **Intra-node:** GPU HBM ↔ DDR5 (KV cache offload to host memory)
- **Inter-node:** GPU↔GPU via GPUDirect RDMA over ConnectX-7
- **Storage tier:** DDR5 ↔ NVMe (if attached via PCIe)

**Port considerations:**
- NIXL has aarch64 support since v0.3.1 (`./build.sh --arch aarch64`)
- **UCX backend** — primary transport, supports ARM64 + mlx5 + RDMA
- **GDAKI backend** — GPU-initiated RDMA via DOCA — viable because GPU is
  on BF-3's PCIe root complex (same P2P fabric as ConnectX-7)
- CUDA toolkit aarch64 required (GPU accessible from ARM cores)
- GDRCopy for GPU memory registration on ARM64
- PCIe P2P (GPUDirect) between ConnectX-7 and GPU must be enabled
  in BF-3 firmware (PCIe ACS disabled, P2P routing via root complex)

### 2. Dynamo (Full Stack — Not Just Control Plane)
**What it does:** Complete inference serving — routing, scheduling, AND
inference execution. On BF-3 SH, everything runs on the ARM cores.

**Components to port:**
- **Router** — KV-aware request routing (Rust binary)
- **Planner** — SLA-driven autoscaler (Rust binary, optional for single-node)
- **Frontend** — HTTP API endpoint (Rust + Python)
- **KVBM** — KV Block Manager (Python 3.12, manages GPU HBM + DDR5 tiers)
- **Workers** — Prefill and decode inference (SGLang/vLLM on CUDA aarch64)

**Port considerations:**
- Rust compiles natively on aarch64 (no cross-compilation needed if building on BF-3)
- Python 3.12 required for KVBM — need Ubuntu 24.04 on BF-3
- CUDA aarch64 toolkit must be installed for GPU access
- SGLang/vLLM must be built for aarch64 + CUDA (no pre-built wheels)
- 16 cores are tight — careful CPU affinity and process pinning needed

### 3. Connection Manager (Discovery/Request/Event Planes)
**What it does:** Inter-node communication for multi-node disaggregated
inference across multiple BF-3 SH nodes.

**Architecture (Dynamo v0.9.0+):**
- **Discovery Plane** — Service registration/discovery (etcd or K8s)
- **Request Plane** — TCP transport for inter-service RPC
- **Event Plane** — ZMQ + MessagePack for pub/sub events

**On BF-3 SH:**
- Connection manager runs on same ARM cores as everything else
- ConnectX-7 provides the physical transport for all planes
- For multi-node: each BF-3 SH node runs a full Dynamo stack, connection
  manager coordinates disaggregated prefill/decode across nodes
- For single-node: connection manager is intra-process, minimal overhead

## Build Strategy

### Phase 1: BF-3 SH System Setup
- Flash BF-3 firmware for self-hosted (root complex) mode
- Install Ubuntu 24.04 aarch64 on BF-3 ARM cores
- Configure PCIe bifurcation for GPU slot via Cabline connector
- Install CUDA toolkit aarch64, verify GPU visibility (`nvidia-smi`)
- Enable GPUDirect RDMA (P2P between ConnectX-7 and GPU)
- Disable PCIe ACS for P2P routing through root complex

### Phase 2: Native ARM64 Build on BF-3
Build directly on the BF-3 (native aarch64):
- Build UCX 1.20.x with mlx5 + RDMA + CUDA support
- Build NIXL with UCX + GDAKI backends
- Build Dynamo (full stack including worker support)
- Build SGLang or vLLM for aarch64 + CUDA

### Phase 3: Inference Engine Validation
- Load a model onto the GPU from BF-3 ARM cores
- Run single-node inference (prefill + decode on same GPU)
- Validate KV cache offload: GPU HBM → DDR5 via NIXL
- Benchmark: measure CPU overhead on 16 ARM cores

### Phase 4: Multi-Node Disaggregated Inference
- Connect multiple BF-3 SH nodes via 400Gb RDMA fabric
- Disaggregate prefill and decode across nodes
- NIXL transfers KV cache GPU→GPU via GPUDirect RDMA
- Connection manager coordinates routing across nodes

## CPU Budget (16 cores)

| Component           | Cores | Notes                              |
|---------------------|-------|------------------------------------|
| Dynamo Router       | 1     | Event-driven, low CPU              |
| Dynamo Frontend     | 1     | HTTP serving                       |
| KVBM                | 1     | KV cache bookkeeping               |
| Connection Manager  | 1     | ZMQ/TCP event loops                |
| NIXL Agent          | 2     | RDMA completions, memory mgmt      |
| Inference Worker    | 8     | SGLang/vLLM CPU threads            |
| OS / System         | 2     | Kernel, interrupts, RDMA IRQs      |
| **Total**           | **16**|                                    |

## PCIe Topology Requirements

```
BF-3 SH Internal PCIe Switch (Gen5)
├── Upstream: ARM A78 complex (root complex)
├── Port 0: ConnectX-7 NIC (integrated, always present)
└── Port 1: Cabline CA-II Plus → GPU (adjacent slot)
    └── GPU must be on same PCIe switch for GPUDirect RDMA P2P
```

**Firmware settings needed:**
- Self-hosted mode enabled (B3220SH or firmware config)
- PCIe bifurcation: DPU ARM as Root Port for Cabline connector
- ACS (Access Control Services) disabled for P2P
- IOMMU passthrough or disabled for GPUDirect
