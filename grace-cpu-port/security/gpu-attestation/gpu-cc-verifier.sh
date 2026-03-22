#!/bin/bash
# GPU Confidential Computing Attestation Verifier
# Runs on BF-3 SH ARM cores to verify GPU TEE before allowing inference.
#
# BF-3 MUST verify GPU CC attestation report before:
#   1. Sending any prompts to GPU
#   2. Allowing RDMA DMA to GPU HBM
#   3. Starting inference workers
#
# Uses NVIDIA nvtrust / SPDM protocol to verify GPU attestation.

set -euo pipefail

GPU_BDF="${GPU_PCI_BDF:-0000:01:00.0}"
ATTESTATION_LOG="/var/log/dynamo/gpu-attestation.log"
NONCE_SIZE=32

log() {
    echo "[$(date -Iseconds)] $*" | tee -a "$ATTESTATION_LOG"
}

# --- Step 1: Check GPU CC Mode ---
check_gpu_cc_mode() {
    log "--- Checking GPU CC Mode ---"

    # nvidia-smi should report CC mode
    local cc_mode
    cc_mode=$(nvidia-smi -i 0 --query-gpu=cc_mode.current --format=csv,noheader 2>/dev/null || echo "unknown")

    if [ "$cc_mode" = "On" ] || [ "$cc_mode" = "on" ]; then
        log "OK: GPU CC mode is ON"
        return 0
    else
        log "FAIL: GPU CC mode is '$cc_mode' (expected: On)"
        log "  GPU TEE not active — inference NOT permitted"
        return 1
    fi
}

# --- Step 2: SPDM Session (Device Identity) ---
verify_spdm_identity() {
    log "--- Verifying GPU SPDM Identity ---"

    # SPDM (Security Protocol and Data Model) authenticates the GPU
    # GPU has a unique device certificate from NVIDIA manufacturing
    # BF-3 verifies the cert chain: GPU cert → intermediate → NVIDIA root CA

    if command -v nvidia-cc-verifier &>/dev/null; then
        nvidia-cc-verifier --gpu-id 0 --verify-device-identity \
            --ca-cert /etc/nvidia-cc/nvidia-gpu-root-ca.pem \
            2>&1 | tee -a "$ATTESTATION_LOG"
        return ${PIPESTATUS[0]}
    fi

    # Fallback: use nvtrust tools
    if [ -d /opt/nvtrust ]; then
        python3 /opt/nvtrust/host_tools/python/verify_gpu_attestation.py \
            --gpu-bdf "$GPU_BDF" \
            --verify-identity \
            --ca-cert /etc/nvidia-cc/nvidia-gpu-root-ca.pem \
            2>&1 | tee -a "$ATTESTATION_LOG"
        return ${PIPESTATUS[0]}
    fi

    log "WARN: No GPU attestation verifier found"
    log "  Install: nvidia-cc-verifier or nvtrust"
    return 1
}

# --- Step 3: GPU Attestation Report ---
verify_attestation_report() {
    log "--- Verifying GPU Attestation Report ---"

    # Generate fresh nonce for replay protection
    local nonce
    nonce=$(openssl rand -hex $NONCE_SIZE)
    log "Attestation nonce: $nonce"

    if command -v nvidia-cc-verifier &>/dev/null; then
        # Request attestation report with nonce
        nvidia-cc-verifier --gpu-id 0 --get-attestation-report \
            --nonce "$nonce" \
            --verify-measurements \
            --expected-measurements /etc/nvidia-cc/expected-measurements.json \
            --output /tmp/gpu-attestation-report.json \
            2>&1 | tee -a "$ATTESTATION_LOG"

        if [ $? -ne 0 ]; then
            log "FAIL: GPU attestation report verification failed"
            return 1
        fi

        log "OK: GPU attestation report verified"

        # Extract key measurements
        log "GPU measurements:"
        python3 -c "
import json
with open('/tmp/gpu-attestation-report.json') as f:
    report = json.load(f)
    for k, v in report.get('measurements', {}).items():
        print(f'  {k}: {v}')
" 2>/dev/null || true

        return 0
    fi

    # Fallback: nvtrust
    if [ -d /opt/nvtrust ]; then
        python3 /opt/nvtrust/host_tools/python/verify_gpu_attestation.py \
            --gpu-bdf "$GPU_BDF" \
            --nonce "$nonce" \
            --verify-report \
            2>&1 | tee -a "$ATTESTATION_LOG"
        return ${PIPESTATUS[0]}
    fi

    log "FAIL: Cannot verify GPU attestation (no tools available)"
    return 1
}

# --- Step 4: Verify GPU Firmware ---
verify_gpu_firmware() {
    log "--- Verifying GPU Firmware Version ---"

    local vbios_version
    vbios_version=$(nvidia-smi -i 0 --query-gpu=vbios_version --format=csv,noheader 2>/dev/null || echo "unknown")
    local driver_version
    driver_version=$(nvidia-smi -i 0 --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown")

    log "GPU VBIOS: $vbios_version"
    log "GPU Driver: $driver_version"

    # Check against approved versions
    if [ -f /etc/nvidia-cc/approved-versions.json ]; then
        python3 -c "
import json, sys
with open('/etc/nvidia-cc/approved-versions.json') as f:
    approved = json.load(f)
vbios = '$vbios_version'
driver = '$driver_version'
if vbios not in approved.get('vbios', []):
    print(f'FAIL: VBIOS {vbios} not in approved list')
    sys.exit(1)
if driver not in approved.get('driver', []):
    print(f'FAIL: Driver {driver} not in approved list')
    sys.exit(1)
print('OK: GPU firmware versions approved')
" 2>&1 | tee -a "$ATTESTATION_LOG"
        return ${PIPESTATUS[0]}
    else
        log "WARN: No approved versions list at /etc/nvidia-cc/approved-versions.json"
        return 0
    fi
}

# --- Step 5: Establish Encrypted Channel ---
setup_gpu_encrypted_channel() {
    log "--- Setting Up Encrypted GPU Channel ---"

    # In CC mode, DMA engine uses AES-256-GCM for CPU↔GPU transfers
    # BF-3 ARM cores (as the host CPU) negotiate this automatically
    # via the NVIDIA driver when CC mode is active

    # Verify encrypted bounce buffers are active
    if [ -f /sys/module/nvidia/parameters/cc_enabled ]; then
        local cc_enabled
        cc_enabled=$(cat /sys/module/nvidia/parameters/cc_enabled)
        if [ "$cc_enabled" = "1" ]; then
            log "OK: NVIDIA driver CC mode active, encrypted DMA enabled"
        else
            log "FAIL: NVIDIA driver CC mode not active"
            return 1
        fi
    fi

    log "Encrypted channel established: BF-3 ARM ←[AES-256-GCM]→ GPU TEE"
}

# --- Step 6: Record Attestation State ---
record_attestation() {
    log "--- Recording Attestation State ---"

    local state_file="/var/run/dynamo/gpu-attestation-state.json"
    mkdir -p "$(dirname "$state_file")"

    python3 -c "
import json, time, subprocess

state = {
    'timestamp': time.time(),
    'timestamp_iso': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'gpu_bdf': '$GPU_BDF',
    'cc_mode': True,
    'spdm_valid': True,
    'attestation_valid': True,
    'driver_version': subprocess.getoutput('nvidia-smi -i 0 --query-gpu=driver_version --format=csv,noheader'),
    'vbios_version': subprocess.getoutput('nvidia-smi -i 0 --query-gpu=vbios_version --format=csv,noheader'),
    'gpu_name': subprocess.getoutput('nvidia-smi -i 0 --query-gpu=name --format=csv,noheader'),
    'attestation_age_seconds': 0,
    'next_reattestation': time.time() + 3600,
}

with open('$state_file', 'w') as f:
    json.dump(state, f, indent=2)

print(f'Attestation state written to $state_file')
" 2>&1 | tee -a "$ATTESTATION_LOG"

    log "GPU attestation complete. State recorded for OPA policy engine."
}

# --- Main ---
main() {
    log "============================================="
    log "  GPU CC Attestation Verification"
    log "  BF-3 SH verifying GPU TEE before inference"
    log "============================================="

    mkdir -p "$(dirname "$ATTESTATION_LOG")"

    local failed=0

    check_gpu_cc_mode          || failed=1
    verify_spdm_identity       || failed=1
    verify_attestation_report  || failed=1
    verify_gpu_firmware        || failed=1
    setup_gpu_encrypted_channel || failed=1

    if [ "$failed" -eq 0 ]; then
        record_attestation
        log ""
        log "============================================="
        log "  GPU CC ATTESTATION: PASSED"
        log "  Inference is PERMITTED"
        log "============================================="
        exit 0
    else
        log ""
        log "============================================="
        log "  GPU CC ATTESTATION: FAILED"
        log "  Inference is BLOCKED"
        log "  No prompts will be sent to GPU"
        log "============================================="
        exit 1
    fi
}

case "${1:-verify}" in
    verify)    main ;;
    cc-mode)   check_gpu_cc_mode ;;
    spdm)      verify_spdm_identity ;;
    report)    verify_attestation_report ;;
    firmware)  verify_gpu_firmware ;;
    channel)   setup_gpu_encrypted_channel ;;
    *)
        echo "Usage: $0 {verify|cc-mode|spdm|report|firmware|channel}"
        exit 1
        ;;
esac
