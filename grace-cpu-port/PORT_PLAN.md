# Porting Dynamo + NIXL + Connection Manager to BF-3 Grace CPU

## Overview

Port the NVIDIA Dynamo disaggregated inference control plane from x86_64 to
ARM64 (aarch64) targeting the NVIDIA BlueField-3 SuperNIC with Grace CPU.

**Target Hardware:**
- NVIDIA BlueField-3 SuperNIC (ConnectX-7 based, 400Gb/s)
- NVIDIA Grace CPU (ARM Neoverse V2, up to 72 cores per chip)
- LPDDR5X memory, NVLink-C2C interconnect

**Source Repos:**
- Dynamo: https://github.com/ai-dynamo/dynamo (Rust + Python)
- NIXL: https://github.com/ai-dynamo/nixl (C++ with Python/Rust bindings)

## Components Being Ported

### 1. NIXL (NVIDIA Inference Xfer Library)
**What it does:** High-throughput, low-latency point-to-point data transfer for
KV cache movement between disaggregated prefill and decode workers.

**Port considerations:**
- Core library is C++17 — compiles on ARM64 with minimal changes
- UCX backend already supports ARM64 + ConnectX offload
- GDS (GPUDirect Storage) backend needs ARM64 CUDA toolkit
- BF-3's ConnectX-7 provides native RDMA for zero-copy transfers
- ETCD metadata exchange works unchanged on ARM64
- Must build UCX 1.20.x from source for aarch64 with mlx5 support

### 2. Dynamo Control Plane
**What it does:** Orchestrates disaggregated inference — routing, scheduling,
autoscaling, service discovery.

**Components to port:**
- **Router** — KV-aware request routing (Rust binary)
- **Planner** — SLA-driven autoscaler (Rust binary)
- **Frontend** — HTTP API endpoint (Rust + Python)
- **KVBM** — KV Block Manager for cache management

**Port considerations:**
- Rust cross-compiles cleanly to aarch64-unknown-linux-gnu
- Python components run unchanged on ARM64
- No x86-specific intrinsics in control plane code
- protobuf, hwloc, libudev all have ARM64 packages

### 3. Connection Manager (Discovery/Request/Event Planes)
**What it does:** Manages inter-component communication for the disaggregated
inference cluster.

**Architecture (Dynamo v0.9.0+):**
- **Discovery Plane** — Service registration/discovery
  - Kubernetes-native: EndpointSlices (no external deps)
  - Standalone: etcd (works on ARM64)
- **Request Plane** — Inter-service messaging
  - TCP transport (replaced NATS in v0.8.0+)
  - ZMQ for high-performance transport
- **Event Plane** — Pub/sub for system events
  - ZMQ transport + MessagePack serialization

**Port considerations:**
- ZeroMQ (libzmq) supports ARM64 natively
- MessagePack has no platform-specific code
- etcd has official ARM64 binaries
- TCP transport is architecture-independent
- K8s discovery uses standard API — no port needed

## Architecture: BF-3 as Control Plane Host

```
┌─────────────────────────────────────────────────────┐
│                   GPU Compute Node                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│  │  GPU 0   │  │  GPU 1   │  │  GPU N   │          │
│  │ (Decode) │  │(Prefill) │  │ (Worker) │          │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘          │
│       │              │              │                │
│       └──────────────┼──────────────┘                │
│                      │ PCIe / NVLink                 │
│  ┌───────────────────┴───────────────────────────┐  │
│  │            BlueField-3 SuperNIC               │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │          Grace CPU (ARM64)              │  │  │
│  │  │                                         │  │  │
│  │  │  ┌─────────┐ ┌─────────┐ ┌──────────┐ │  │  │
│  │  │  │ Dynamo  │ │  NIXL   │ │Connection│ │  │  │
│  │  │  │ Router  │ │ Agent   │ │ Manager  │ │  │  │
│  │  │  │+Planner │ │(control)│ │(ZMQ+TCP) │ │  │  │
│  │  │  └─────────┘ └─────────┘ └──────────┘ │  │  │
│  │  │                                         │  │  │
│  │  │  ┌─────────┐ ┌─────────┐              │  │  │
│  │  │  │  etcd   │ │  KVBM   │              │  │  │
│  │  │  │(discov.)│ │(KV mgmt)│              │  │  │
│  │  │  └─────────┘ └─────────┘              │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  │                                               │  │
│  │  ┌─────────────┐     ┌─────────────────────┐ │  │
│  │  │ ConnectX-7  │     │  RDMA / RoCE v2     │ │  │
│  │  │ (400Gb/s)   │────▶│  to other nodes     │ │  │
│  │  └─────────────┘     └─────────────────────┘ │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Why BF-3 for control plane:**
- Offloads control plane from host x86 CPU → frees host for GPU workloads
- Grace CPU has plenty of cores for routing/scheduling decisions
- ConnectX-7 provides direct RDMA path for NIXL metadata exchange
- Native network stack access for lowest-latency service discovery
- Isolates inference orchestration from inference compute

## Build Strategy

### Phase 1: Native ARM64 Build on Grace
Build directly on a Grace CPU system (or BF-3 DPU shell):
- Install aarch64 toolchain, Rust, Python, CUDA toolkit
- Build UCX with mlx5 + RDMA support
- Build NIXL with UCX backend
- Build Dynamo control plane components

### Phase 2: Cross-Compilation from x86
For CI/CD, build from x86 host:
- Use `aarch64-unknown-linux-gnu` Rust target
- Cross-compile C++ with aarch64-linux-gnu-g++
- Multi-arch Docker images (buildx)

### Phase 3: Kubernetes Deployment
- Deploy control plane pods on BF-3 Grace CPU nodes
- Use node selectors/taints for BF-3 scheduling
- Workers remain on GPU nodes (x86 or Grace Blackwell)
