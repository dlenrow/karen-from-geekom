#!/bin/bash
# Build NIXL for ARM64 (aarch64) on Grace CPU / BF-3
# Targets: Native build on Grace CPU or cross-compile from x86_64
#
# Prerequisites:
#   - Ubuntu 22.04/24.04 (aarch64)
#   - CUDA toolkit 12.x+ (aarch64)
#   - UCX 1.20.x built with mlx5 support
#   - Python 3.10+
#   - meson, ninja, cmake

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIXL_SRC="${NIXL_SRC:-${SCRIPT_DIR}/nixl-src}"
NIXL_INSTALL="${NIXL_INSTALL:-/opt/nixl}"
UCX_DIR="${UCX_DIR:-/opt/ucx}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
BUILD_TYPE="${BUILD_TYPE:-release}"
ENABLE_GDS="${ENABLE_GDS:-false}"
ENABLE_ETCD="${ENABLE_ETCD:-true}"

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo "WARNING: Not running on aarch64 (detected: $ARCH)"
    echo "This script is intended for native ARM64 builds."
    echo "For cross-compilation, use build-nixl-cross.sh"
    exit 1
fi

echo "=== Building NIXL for ARM64 (Grace CPU / BF-3) ==="
echo "  NIXL source:  $NIXL_SRC"
echo "  Install dir:  $NIXL_INSTALL"
echo "  UCX dir:      $UCX_DIR"
echo "  CUDA home:    $CUDA_HOME"
echo "  Build type:   $BUILD_TYPE"

# --- Step 1: Install system dependencies ---
install_deps() {
    echo "--- Installing system dependencies ---"
    apt-get update
    apt-get install -y \
        build-essential \
        cmake \
        meson \
        ninja-build \
        python3-dev \
        python3-pip \
        python3-venv \
        pkg-config \
        libibverbs-dev \
        librdmacm-dev \
        libnuma-dev \
        libhwloc-dev \
        git \
        wget
    pip3 install pybind11 tomlkit meson-python
}

# --- Step 2: Build UCX with mlx5 + RDMA for ARM64 ---
build_ucx() {
    local UCX_VERSION="${UCX_VERSION:-1.20.0}"
    echo "--- Building UCX ${UCX_VERSION} for aarch64 ---"

    if [ -f "${UCX_DIR}/lib/libucp.so" ]; then
        echo "UCX already built at ${UCX_DIR}, skipping"
        return 0
    fi

    local UCX_BUILD_DIR="/tmp/ucx-build"
    mkdir -p "$UCX_BUILD_DIR"
    cd "$UCX_BUILD_DIR"

    if [ ! -d "ucx-${UCX_VERSION}" ]; then
        wget -q "https://github.com/openucx/ucx/releases/download/v${UCX_VERSION}/ucx-${UCX_VERSION}.tar.gz"
        tar xzf "ucx-${UCX_VERSION}.tar.gz"
    fi

    cd "ucx-${UCX_VERSION}"
    ./configure \
        --prefix="${UCX_DIR}" \
        --enable-mt \
        --with-rdmacm \
        --with-verbs \
        --with-mlx5-dv \
        --with-cuda="${CUDA_HOME}" \
        --enable-optimizations \
        --disable-logging \
        --disable-debug \
        --disable-assertions

    make -j"$(nproc)"
    make install

    echo "UCX installed to ${UCX_DIR}"
}

# --- Step 3: Clone NIXL if needed ---
clone_nixl() {
    if [ ! -d "$NIXL_SRC" ]; then
        echo "--- Cloning NIXL ---"
        git clone https://github.com/ai-dynamo/nixl.git "$NIXL_SRC"
    fi
    cd "$NIXL_SRC"
    echo "NIXL source at $(pwd), branch: $(git branch --show-current)"
}

# --- Step 4: Build NIXL ---
build_nixl() {
    echo "--- Building NIXL for aarch64 ---"
    cd "$NIXL_SRC"

    local PLUGINS="ucx,posix"
    if [ "$ENABLE_GDS" = "true" ]; then
        PLUGINS="${PLUGINS},gds"
    fi

    # Configure with meson
    meson setup builddir \
        --prefix="$NIXL_INSTALL" \
        --buildtype="$BUILD_TYPE" \
        -Denable_plugins="$PLUGINS" \
        -Ducx_path="$UCX_DIR" \
        -Dcuda_path="$CUDA_HOME" \
        -Dpython=true \
        -Drust=true \
        || meson setup --reconfigure builddir \
            --prefix="$NIXL_INSTALL" \
            --buildtype="$BUILD_TYPE" \
            -Denable_plugins="$PLUGINS" \
            -Ducx_path="$UCX_DIR" \
            -Dcuda_path="$CUDA_HOME" \
            -Dpython=true \
            -Drust=true

    # Build
    ninja -C builddir -j"$(nproc)"

    # Install
    ninja -C builddir install

    echo "NIXL installed to ${NIXL_INSTALL}"
}

# --- Step 5: Verify build ---
verify_build() {
    echo "--- Verifying NIXL ARM64 build ---"

    # Check architecture
    local NIXL_LIB=$(find "$NIXL_INSTALL" -name "libnixl*" -type f | head -1)
    if [ -n "$NIXL_LIB" ]; then
        file "$NIXL_LIB" | grep -q "aarch64" && echo "OK: Library is aarch64" || echo "WARN: Library may not be aarch64"
    fi

    # Check UCX plugin loaded
    if [ -d "${NIXL_INSTALL}/lib" ]; then
        ls -la "${NIXL_INSTALL}/lib/"
    fi

    # Test Python import
    PYTHONPATH="${NIXL_INSTALL}/lib/python3/dist-packages:${PYTHONPATH:-}" \
        python3 -c "import nixl; print(f'NIXL version: {nixl.__version__}')" 2>/dev/null \
        && echo "OK: Python bindings work" \
        || echo "WARN: Python import failed (may need PYTHONPATH adjustment)"

    echo "--- Build verification complete ---"
}

# --- Main ---
case "${1:-all}" in
    deps)     install_deps ;;
    ucx)      build_ucx ;;
    clone)    clone_nixl ;;
    build)    build_nixl ;;
    verify)   verify_build ;;
    all)
        install_deps
        build_ucx
        clone_nixl
        build_nixl
        verify_build
        ;;
    *)
        echo "Usage: $0 {deps|ucx|clone|build|verify|all}"
        exit 1
        ;;
esac

echo "=== Done ==="
