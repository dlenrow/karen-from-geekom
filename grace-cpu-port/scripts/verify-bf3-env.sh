#!/bin/bash
# Verify BF-3 Grace CPU environment is ready for building/running
# the disaggregated inference control plane

set -euo pipefail

echo "=== BF-3 Grace CPU Environment Check ==="
echo ""

PASS=0
WARN=0
FAIL=0

check() {
    local desc="$1"
    local cmd="$2"
    local required="${3:-true}"

    if eval "$cmd" &>/dev/null; then
        echo "  [OK]   $desc"
        ((PASS++))
    elif [ "$required" = "true" ]; then
        echo "  [FAIL] $desc"
        ((FAIL++))
    else
        echo "  [WARN] $desc (optional)"
        ((WARN++))
    fi
}

# Architecture
echo "--- Architecture ---"
ARCH=$(uname -m)
echo "  Arch: $ARCH"
if [ "$ARCH" = "aarch64" ]; then
    echo "  [OK]   Running on ARM64"
    ((PASS++))
else
    echo "  [FAIL] Not ARM64 (got: $ARCH)"
    ((FAIL++))
fi

# CPU info
echo ""
echo "--- CPU ---"
if [ -f /proc/cpuinfo ]; then
    CORES=$(nproc 2>/dev/null || echo "unknown")
    echo "  Cores: $CORES"
    grep -q "Neoverse" /proc/cpuinfo 2>/dev/null && echo "  [OK]   Grace CPU (Neoverse V2)" && ((PASS++)) || echo "  [INFO] CPU type: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
fi

# Memory
echo ""
echo "--- Memory ---"
if [ -f /proc/meminfo ]; then
    MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    echo "  Total: ${MEM_GB} GB"
    HUGEPAGES=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
    echo "  HugePages: $HUGEPAGES"
fi

# RDMA / InfiniBand
echo ""
echo "--- RDMA / Network ---"
check "ibverbs library" "ldconfig -p | grep -q libibverbs"
check "rdma-core" "command -v ibv_devinfo"
check "mlx5 devices" "ls /sys/class/infiniband/mlx5_* 2>/dev/null" "false"
if command -v ibv_devinfo &>/dev/null; then
    echo "  Devices:"
    ibv_devinfo -l 2>/dev/null | head -10 | sed 's/^/    /'
fi

# CUDA
echo ""
echo "--- CUDA ---"
check "nvcc compiler" "command -v nvcc"
check "CUDA runtime" "ls /usr/local/cuda/lib64/libcudart.so* 2>/dev/null" "false"
if command -v nvcc &>/dev/null; then
    echo "  Version: $(nvcc --version 2>/dev/null | grep release | awk '{print $6}')"
fi

# Build tools
echo ""
echo "--- Build Tools ---"
check "gcc/g++" "command -v g++"
check "cmake" "command -v cmake"
check "meson" "command -v meson"
check "ninja" "command -v ninja"
check "rustc" "command -v rustc"
check "python3" "command -v python3"
check "pip3" "command -v pip3"
check "protoc" "command -v protoc"
check "pkg-config" "command -v pkg-config"

# UCX
echo ""
echo "--- UCX ---"
check "UCX installed" "command -v ucx_info || ls /opt/ucx/bin/ucx_info 2>/dev/null"
if command -v ucx_info &>/dev/null; then
    echo "  Version: $(ucx_info -v 2>/dev/null | head -1)"
    echo "  Transports:"
    ucx_info -d 2>/dev/null | grep "Transport" | head -5 | sed 's/^/    /'
fi

# Container runtime
echo ""
echo "--- Container Runtime ---"
check "docker" "command -v docker" "false"
check "kubectl" "command -v kubectl" "false"

# Summary
echo ""
echo "=== Summary ==="
echo "  Passed:  $PASS"
echo "  Warnings: $WARN"
echo "  Failed:  $FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Some required checks failed. Install missing dependencies before building."
    exit 1
fi
