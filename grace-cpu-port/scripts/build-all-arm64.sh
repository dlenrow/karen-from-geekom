#!/bin/bash
# Master build script: Build entire disaggregated inference control plane for BF-3 Grace CPU
#
# Usage:
#   ./build-all-arm64.sh              # Full build (native on aarch64)
#   ./build-all-arm64.sh docker       # Build Docker images
#   ./build-all-arm64.sh deploy       # Deploy to K8s

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================="
echo "  Disaggregated Inference Control Plane"
echo "  Target: BF-3 Grace CPU (ARM64/aarch64)"
echo "============================================="
echo ""

case "${1:-native}" in
    native)
        echo "=== Phase 1: Build NIXL ==="
        bash "${PROJECT_DIR}/nixl/build-nixl-arm64.sh" all

        echo ""
        echo "=== Phase 2: Build Dynamo Control Plane ==="
        bash "${PROJECT_DIR}/dynamo/build-dynamo-arm64.sh" all

        echo ""
        echo "=== Phase 3: Setup Connection Manager deps ==="
        # etcd is optional — only for standalone (non-K8s) deployments
        if [ "${STANDALONE:-false}" = "true" ]; then
            bash "${PROJECT_DIR}/connection-manager/setup-etcd-arm64.sh"
        else
            echo "Skipping etcd (K8s discovery mode). Set STANDALONE=true to install."
        fi

        echo ""
        echo "=== Build Complete ==="
        echo "  NIXL:    /opt/nixl"
        echo "  Dynamo:  /opt/dynamo"
        echo "  Config:  ${PROJECT_DIR}/dynamo/dynamo-bf3-config.yaml"
        echo "           ${PROJECT_DIR}/nixl/nixl-bf3-config.yaml"
        echo "           ${PROJECT_DIR}/connection-manager/connection-manager-bf3.yaml"
        ;;

    docker)
        echo "=== Building Docker images for ARM64 ==="

        # Build NIXL image first (used as base)
        echo "--- Building NIXL ARM64 image ---"
        docker buildx build \
            --platform linux/arm64 \
            -t nixl:arm64 \
            -f "${PROJECT_DIR}/nixl/Dockerfile.arm64" \
            "${PROJECT_DIR}/nixl/"

        # Build Dynamo control plane image
        echo "--- Building Dynamo CP ARM64 image ---"
        docker buildx build \
            --platform linux/arm64 \
            -t dynamo-cp:arm64 \
            -f "${PROJECT_DIR}/dynamo/Dockerfile.arm64" \
            "${PROJECT_DIR}/dynamo/"

        echo "Docker images built: nixl:arm64, dynamo-cp:arm64"
        ;;

    deploy)
        echo "=== Deploying to Kubernetes ==="

        kubectl apply -f "${PROJECT_DIR}/k8s/namespace.yaml"
        kubectl apply -f "${PROJECT_DIR}/k8s/bf3-control-plane.yaml"
        kubectl apply -f "${PROJECT_DIR}/k8s/gpu-workers.yaml"

        echo ""
        echo "Deployed. Check status:"
        echo "  kubectl -n dynamo-inference get pods"
        echo "  kubectl -n dynamo-inference get svc"
        ;;

    *)
        echo "Usage: $0 {native|docker|deploy}"
        exit 1
        ;;
esac
