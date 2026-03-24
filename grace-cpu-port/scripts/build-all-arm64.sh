#!/bin/bash
# Master build script: Build full Dynamo inference stack for BF-3 SH
# BF-3 SH is the sole host — ARM cores drive GPU via PCIe root complex
#
# Usage:
#   ./build-all-arm64.sh              # Full native build on BF-3
#   ./build-all-arm64.sh setup        # Setup BF-3 SH + GPU (run first!)
#   ./build-all-arm64.sh docker       # Build Docker images
#   ./build-all-arm64.sh deploy       # Deploy to K8s
#   ./build-all-arm64.sh verify       # Verify environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================="
echo "  Disaggregated Inference — Full Stack"
echo "  Target: BF-3 SH (ARM64 + GPU on root complex)"
echo "============================================="
echo ""

case "${1:-native}" in
    setup)
        echo "=== Phase 0: Setup BF-3 SH + GPU ==="
        bash "${PROJECT_DIR}/scripts/setup-bf3-sh-gpu.sh" all
        ;;

    verify)
        echo "=== Verifying BF-3 SH Environment ==="
        bash "${PROJECT_DIR}/scripts/verify-bf3-env.sh"
        echo ""
        bash "${PROJECT_DIR}/scripts/setup-bf3-sh-gpu.sh" verify
        ;;

    native)
        echo "=== Phase 1: Build NIXL (UCX + GDAKI) ==="
        bash "${PROJECT_DIR}/nixl/build-nixl-arm64.sh" all

        echo ""
        echo "=== Phase 2: Build Dynamo (Full Stack) ==="
        bash "${PROJECT_DIR}/dynamo/build-dynamo-arm64.sh" all

        echo ""
        echo "=== Phase 3: Setup Connection Manager deps ==="
        if [ "${STANDALONE:-false}" = "true" ]; then
            bash "${PROJECT_DIR}/connection-manager/setup-etcd-arm64.sh"
        else
            echo "Skipping etcd (K8s or file-based discovery). Set STANDALONE=true to install."
        fi

        echo ""
        echo "=== Build Complete ==="
        echo "  NIXL:     /opt/nixl"
        echo "  Dynamo:   /opt/dynamo"
        echo "  Configs:  ${PROJECT_DIR}/dynamo/dynamo-bf3-config.yaml"
        echo "            ${PROJECT_DIR}/nixl/nixl-bf3-config.yaml"
        echo "            ${PROJECT_DIR}/connection-manager/connection-manager-bf3.yaml"
        echo ""
        echo "  To run inference:"
        echo "    /opt/dynamo/bin/dynamo-serve --config ${PROJECT_DIR}/dynamo/dynamo-bf3-config.yaml"
        ;;

    docker)
        echo "=== Building Docker images for BF-3 SH ==="

        # Build NIXL image first (used as base)
        echo "--- Building NIXL ARM64 image ---"
        docker buildx build \
            --platform linux/arm64 \
            -t nixl:arm64 \
            -f "${PROJECT_DIR}/nixl/Dockerfile.arm64" \
            "${PROJECT_DIR}/nixl/"

        # Build Dynamo full-stack image
        echo "--- Building Dynamo BF-3 SH image ---"
        docker buildx build \
            --platform linux/arm64 \
            -t dynamo-bf3sh:arm64 \
            -f "${PROJECT_DIR}/dynamo/Dockerfile.arm64" \
            "${PROJECT_DIR}/dynamo/"

        echo "Docker images built: nixl:arm64, dynamo-bf3sh:arm64"
        echo ""
        echo "  To run with GPU:"
        echo "    docker run --gpus all --privileged --network host dynamo-bf3sh:arm64"
        ;;

    deploy)
        echo "=== Deploying to Kubernetes ==="

        kubectl apply -f "${PROJECT_DIR}/k8s/namespace.yaml"

        echo ""
        echo "Deploy mode:"
        echo "  1) Single-node (colocated prefill+decode on one BF-3):"
        echo "     kubectl apply -f ${PROJECT_DIR}/k8s/bf3-control-plane.yaml"
        echo ""
        echo "  2) Multi-node (disaggregated across BF-3 SH nodes):"
        echo "     kubectl apply -f ${PROJECT_DIR}/k8s/gpu-workers.yaml"

        # Default: single-node
        kubectl apply -f "${PROJECT_DIR}/k8s/bf3-control-plane.yaml"

        echo ""
        echo "Deployed. Check status:"
        echo "  kubectl -n dynamo-inference get pods"
        echo "  kubectl -n dynamo-inference get svc"
        ;;

    *)
        echo "Usage: $0 {setup|verify|native|docker|deploy}"
        echo ""
        echo "  setup   - Configure BF-3 SH hardware (GPU, GPUDirect, hugepages)"
        echo "  verify  - Verify BF-3 SH environment is ready"
        echo "  native  - Build NIXL + Dynamo natively on BF-3"
        echo "  docker  - Build Docker images"
        echo "  deploy  - Deploy to Kubernetes"
        exit 1
        ;;
esac
