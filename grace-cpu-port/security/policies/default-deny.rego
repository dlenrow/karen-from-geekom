# OPA Policy: Default-Deny Zero-Trust Inference Control Plane
# Runs on BF-3 SH ARM cores. Every RDMA operation, inference request,
# and DMA transfer is evaluated against this policy.
#
# PRINCIPLE: Default DENY. Explicit allow rules only.

package dynamo.inference

import rego.v1

# ============================================================
# DEFAULT: DENY EVERYTHING
# ============================================================
default allow := false

# ============================================================
# INFERENCE REQUEST SUBMISSION
# ============================================================

# Allow inference requests from authenticated tenants
allow if {
    input.action == "inference.submit"
    valid_spiffe_id(input.caller)
    tenant_authorized(input.caller, input.model)
    within_rate_limit(input.caller)
    not blacklisted(input.caller)
}

# ============================================================
# KV CACHE TRANSFER (NIXL / RDMA)
# ============================================================

# Allow KV cache transfer between attested peer nodes in same cluster
allow if {
    input.action == "kvcache.transfer"
    valid_spiffe_id(input.caller)
    valid_spiffe_id(input.target)
    same_cluster(input.caller, input.target)
    peer_attested(input.caller)
    peer_attested(input.target)
    ipsec_sa_active(input.caller, input.target)
}

# ============================================================
# RDMA CONNECTION ESTABLISHMENT
# ============================================================

# Allow RDMA connections only from verified peers with valid mTLS
allow if {
    input.action == "rdma.connect"
    valid_spiffe_id(input.caller)
    peer_attested(input.caller)
    ipsec_sa_active(input.caller, input.self)
    not peer_revoked(input.caller)
    rdma_qp_within_limit(input.caller)
}

# ============================================================
# GPU DMA ACCESS
# ============================================================

# Allow DMA to GPU only for authenticated, attested operations
allow if {
    input.action == "gpu.dma"
    input.direction == "write"
    valid_spiffe_id(input.caller)
    gpu_tee_attested(input.gpu_id)
    dma_region_permitted(input.caller, input.gpu_region)
}

# Allow DMA from GPU (results) to authenticated callers
allow if {
    input.action == "gpu.dma"
    input.direction == "read"
    valid_spiffe_id(input.caller)
    gpu_tee_attested(input.gpu_id)
    result_authorized(input.caller, input.request_id)
}

# ============================================================
# MODEL LOADING
# ============================================================

# Allow model loading only with admin identity + signed manifest
allow if {
    input.action == "model.load"
    valid_spiffe_id(input.caller)
    is_admin(input.caller)
    model_manifest_signed(input.model_manifest)
    model_manifest_valid(input.model_manifest)
}

# ============================================================
# CONTROL PLANE OPERATIONS
# ============================================================

# Allow discovery/heartbeat between cluster members
allow if {
    input.action == "discovery.register"
    valid_spiffe_id(input.caller)
    same_cluster(input.caller, input.self)
    peer_attested(input.caller)
}

allow if {
    input.action == "discovery.query"
    valid_spiffe_id(input.caller)
    same_cluster(input.caller, input.self)
}

# Allow metrics scraping from monitoring identity
allow if {
    input.action == "metrics.scrape"
    valid_spiffe_id(input.caller)
    is_monitoring(input.caller)
}

# ============================================================
# HELPER RULES
# ============================================================

valid_spiffe_id(identity) if {
    startswith(identity.spiffe_id, "spiffe://")
    identity.svid_valid == true
    identity.svid_not_expired == true
}

tenant_authorized(caller, model) if {
    caller.tenant_id in data.authorized_tenants[model]
}

same_cluster(a, b) if {
    a.cluster_id == b.cluster_id
}

peer_attested(peer) if {
    peer.dice_attestation_valid == true
    peer.boot_measurements_match == true
    peer.attestation_age_seconds < 3600
}

gpu_tee_attested(gpu_id) if {
    data.gpu_attestations[gpu_id].cc_mode == true
    data.gpu_attestations[gpu_id].spdm_valid == true
    data.gpu_attestations[gpu_id].attestation_age_seconds < 3600
}

ipsec_sa_active(src, dst) if {
    sa := data.ipsec_associations[concat("->", [src.node_id, dst.node_id])]
    sa.state == "ESTABLISHED"
    sa.cipher == "AES-256-GCM"
}

within_rate_limit(caller) if {
    data.rate_limits[caller.tenant_id].requests_remaining > 0
}

is_admin(caller) if {
    caller.role == "admin"
    caller.admin_attestation_valid == true
}

is_monitoring(caller) if {
    caller.role == "monitoring"
}

blacklisted(caller) if {
    caller.spiffe_id in data.blacklist
}

peer_revoked(peer) if {
    peer.spiffe_id in data.revoked_peers
}

rdma_qp_within_limit(caller) if {
    data.rdma_qp_count[caller.node_id] < data.rdma_qp_limit
}

dma_region_permitted(caller, region) if {
    region in data.permitted_dma_regions[caller.tenant_id]
}

model_manifest_signed(manifest) if {
    manifest.signature_valid == true
    manifest.signer in data.trusted_signers
}

model_manifest_valid(manifest) if {
    manifest.hash_verified == true
    not manifest.revoked
}

result_authorized(caller, request_id) if {
    data.active_requests[request_id].caller_id == caller.spiffe_id
}

# ============================================================
# AUDIT: Log all decisions
# ============================================================

audit_entry := {
    "timestamp": input.timestamp,
    "action": input.action,
    "caller": input.caller.spiffe_id,
    "decision": allow,
    "reason": reason,
}

reason := "allowed" if { allow }
reason := "denied: no matching allow rule" if { not allow }
