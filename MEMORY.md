# Decision Log — Zero-Trust Inference on BlueField

Reverse-chronological log of architectural decisions and pivots.

---

## 2026-03-22: Market thesis — $2.5T installed base, $5T next gen

**Installed base ($2.5T NVIDIA inference gear already deployed):**
- All of it has permissive, no-auth x86 RDMA control planes
- Needs an OVERLAY control plane solution — can't rip and replace
- BF-3 DPU already in the NIC tray (HGX H200, 1:1 GPU-to-NIC)
- Our BFB appliance is a drop-in overlay: flash BF-3, boot, done
- Zero changes to x86 host, zero changes to inference software
- Immediate value: default-deny, SPIFFE identity, RDMA audit

**Next gen ($5T Vera/Rubin generation):**
- Vera CC burns 10% CPU + latency on full-fabric encryption
- That's the only option if your access control is host-based
- Nobody will want to pay that tax if they can get the same security
  with Cilium RDMA on BF-4 at zero dataplane overhead
- BF-4 will have more ARM cores, more bandwidth, likely native
  RDMA-aware eBPF hooks (building on BF-3 representor model)
- foil-cilium CNP isolation on BF-4 = same security, no crypto tax
- Customers choose: 10% CPU + latency (Vera) vs 0% (Cilium on BF-4)

**Go-to-market: enterprise security channel, not NVIDIA**
- NVIDIA sells silicon, not security posture. They don't GAF.
- Enterprise buys zero-trust from security vendors:
  - Illumio (microsegmentation, already has enterprise ZT brand)
    + WWT (channel, integration, enterprise delivery)
  - Microsoft (Azure Confidential Computing, Defender for Cloud)
- Solution sold as: "zero-trust inference security for your GPU cluster"
  - Not "BlueField firmware update" — enterprise security product
  - Illumio/WWT: on-prem and colo HGX deployments
  - Microsoft: Azure GPU fleet, sovereign cloud
- BFB appliance is the deliverable, but packaging is enterprise security
- foil-cilium is the engine, but branding is the vendor's ZT platform

---

## 2026-03-22: Competitive positioning vs Vera CC (10% CPU + latency)

**Context:** Vera's confidential computing solution spends ~10% of CPU on
crypto and adds significant latency. Their threat model requires encrypting
everything because access control is weak — the control plane runs on the
same untrusted x86 host as the workload, so they can't enforce who talks
to whom at the fabric level. Encryption is their only option.

**Our advantage:** BF-3 DPU as a drop-in device IS the access control.
foil-cilium CNPs enforce ibverbs-level isolation on the NIC card itself.
The hardware trust boundary means:
- No dataplane encryption needed → 0% CPU overhead (vs Vera's 10%)
- No added latency on RDMA path (vs Vera's crypto latency)
- mTLS only on API edge (user ↔ TEE) — negligible vs full-fabric encryption
- Same or better security posture: access control > encryption-without-access-control

**Key insight:** Encryption compensates for weak access control. Strong access
control (enforced at hardware trust boundary) makes dataplane encryption
redundant. Vera encrypts because they must. We isolate because we can.

---

## 2026-03-22: No dataplane encryption — CNPs isolate, fabric is optical

**Question:** Do we need encrypted RDMA dataplane?

**Decision:** No. Disabled IPsec/WireGuard on the RDMA dataplane entirely.

**Rationale:**
- foil-cilium CNPs isolate RDMA users at ibverbs level — that's the real
  security control (who can talk to whom, with which verbs)
- BF-3 DPU IS the drop-in trust boundary — node-to-node encryption is
  redundant when the NIC card enforces policy
- Physical fabric is 800G optical — nobody is sniffing it
- IPsec burns scarce ARM cores (8 on BF-2, 16 on BF-3) and adds latency
  for zero security benefit in this threat model
- mTLS on the API path (user ↔ frontend ↔ GPU TEE) handles the
  encryption that actually matters — identity-bound, per-turn

**What still encrypts:** mTLS on inference API (port 8000). That's it.
**What doesn't encrypt:** Inter-node RDMA (KV cache), control plane inter-service.

---

## 2026-03-22: mTLS for inference API, IPsec for RDMA bulk

**Question:** What encryption for user ↔ GPU TEE inference turns?

**Decision:** mTLS (TLS 1.3 with client certs) for the inference API path.
IPsec stays for inter-node RDMA KV cache transfer.

**Rationale:** IPsec encrypts the pipe (node-to-node). mTLS encrypts the
conversation (per-connection, per-identity). For LLM turns:
- Client presents SPIFFE SVID — identity-bound, revocable, carries tenant claims
- L7 visible to Cilium/Envoy — can enforce per-route, per-method policy
- Hubble records who asked what (method, path, client ID) without seeing prompt content
- Per-tenant rate limiting keyed on client cert identity
- Individual client revocation without tearing down all traffic

IPsec stays for RDMA because:
- KV cache transfer is bulk, node-to-node, not per-request
- ConnectX-7 hardware offloads AES-256-GCM at line rate
- ibverbs policing via CNPs handles the access control layer

**Files:** cnp-inference-api-mtls.yaml, dynamo-bf3-config.yaml (security.mtls section)

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
