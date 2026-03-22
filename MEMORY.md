# Decision Log — Zero-Trust Inference on BlueField

Reverse-chronological log of architectural decisions and pivots.

---

## 2026-03-22: BF-2 viable for dev/debug

**Question:** Can we develop on BF-2 (available in home lab) instead of BF-3?

**Answer:** Yes. DOCA SDK guarantees source + binary compatibility across
BF-2 and BF-3. Same representor port architecture, same ECPF DPU mode,
same eBPF/XDP hooks. BF-2 has 8x A72 cores (tighter than BF-3's 16x A78)
but sufficient for control plane + foil-cilium development.

Only missing: DPA (BF-3 only), GDAKI (BF-3 only), PCIe Gen5, 400Gb/s.
None of these are in the security-critical path.

**Open question:** Does BF-2 have CC/TEE hardware? (Under investigation)

---

## 2026-03-22: Standard HGX H200 ships with B3220 DPU, not SH

**Question:** Do 8xH200 nodes come with BF-3? Is it SH variant?

**Answer:** Yes, standard HGX H200 nodes ship with BF-3 B3220 DPUs in the
NIC tray (1:1 GPU-to-NIC ratio). But these are standard B3220 (endpoint mode),
NOT the B3220SH (self-hosted / root complex mode).

**Impact:** Don't need SH mode. BF-3 runs in DPU mode as network security
gateway. x86 host runs inference. Need to rearchitect configs for this split
(currently configs assume SH where ARM cores drive GPU).

---

## 2026-03-22: foil-cilium replaces OPA + custom audit + custom IPsec

**Question:** How to implement RDMA policy enforcement?

**Decision:** Use foil-cilium (custom Cilium fork) on K3s. Provides:
- CiliumNetworkPolicies with ibverbs verb-level policing
- Hubble RDMA flow records (replaces custom audit)
- Transparent IPsec encryption (replaces standalone DOCA IPsec config)
- SPIFFE mutual authentication
- CNP default-deny on RoCE v2 (UDP 4791)

foil-cilium works because on BF-3 DPU mode, representor ports expose
all NIC traffic to eBPF hooks running on ARM cores. RoCE v2 is UDP —
Cilium can match and filter it.

**Removed:** OPA Rego policies, custom audit logger, standalone IPsec config.
**Kept:** DOCA Flow (PCIe-level DMA firewall), SPIRE, GPU CC attestation.

---

## 2026-03-22: BF-3 SH root complex controls GPU in adjacent PCIe slot

**Question:** What's the hardware architecture?

**Answer (initial, later revised):** BF-3 SH (B3220SH) operates in self-hosted
mode. ARM A78 cores are the PCIe root complex owner. GPU sits in adjacent
slot connected via Cabline CA-II Plus. No x86 host. BF-3 runs everything:
control plane, inference workers, CUDA.

**Later revised:** This is the SH variant only. Standard HGX uses B3220 DPU
mode. See decision above.

---

## 2026-03-22: Target is BF-3 (not BF-4)

**Correction:** BF-4 doesn't exist (yet). Target is BF-3.

---

## 2026-03-22: Project goal — zero-trust inference appliance

**Goal:** Drop a BFB appliance into 8xH200 nodes. Replace the permissive,
no-auth, no-filter x86 host RDMA control plane with:
- Security-first
- Policy-based
- Default-deny
- Strong identity (SPIFFE + DICE)
- Control plane on the NIC card (BlueField)

Protect confidential inference (CC decode in GPU TEE) with strong DMA
zero-trust control plane. Prompts should never be cleartext outside TEE.

---

## Initial: Port Dynamo + NIXL to ARM64

**Original plan:** Port NVIDIA Dynamo disaggregated inference control plane
from x86_64 to ARM64 targeting BlueField + Grace CPU.

**Components:** NIXL (KV cache transfer), Dynamo (router, planner, frontend,
KVBM), Connection Manager (ZMQ, TCP, etcd).

**Evolved into:** Security-first zero-trust appliance, not just an ARM64 port.
