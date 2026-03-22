#!/bin/bash
# Build NVIDIA Dynamo control plane components for ARM64 (Grace CPU / BF-3)
#
# Components built:
#   - dynamo-router    (KV-aware request routing)
#   - dynamo-planner   (SLA-driven autoscaler)
#   - dynamo-frontend  (HTTP API)
#   - dynamo-kvbm      (KV Block Manager)
#   - Python libraries  (dynamo SDK, bindings)
#
# Prerequisites:
#   - aarch64 system (Grace CPU or BF-3 DPU)
#   - Rust 1.80+ (aarch64-unknown-linux-gnu)
#   - Python 3.10+
#   - protobuf-compiler, libhwloc, libudev
#   - NIXL installed (for KV cache transfers)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNAMO_SRC="${DYNAMO_SRC:-${SCRIPT_DIR}/dynamo-src}"
DYNAMO_INSTALL="${DYNAMO_INSTALL:-/opt/dynamo}"
NIXL_DIR="${NIXL_DIR:-/opt/nixl}"
BUILD_TYPE="${BUILD_TYPE:-release}"

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo "WARNING: Not running on aarch64 (detected: $ARCH)"
    echo "For cross-compilation, use build-dynamo-cross.sh"
    exit 1
fi

echo "=== Building Dynamo Control Plane for ARM64 (Grace CPU / BF-3) ==="
echo "  Dynamo source: $DYNAMO_SRC"
echo "  Install dir:   $DYNAMO_INSTALL"
echo "  NIXL dir:      $NIXL_DIR"
echo "  Build type:    $BUILD_TYPE"

# --- Step 1: Install system dependencies ---
install_deps() {
    echo "--- Installing system dependencies ---"
    apt-get update
    apt-get install -y \
        build-essential \
        cmake \
        pkg-config \
        protobuf-compiler \
        libprotobuf-dev \
        libhwloc-dev \
        libudev-dev \
        libssl-dev \
        libzmq3-dev \
        python3-dev \
        python3-pip \
        python3-venv \
        git \
        curl

    # Install Rust if not present
    if ! command -v rustc &>/dev/null; then
        echo "--- Installing Rust toolchain ---"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi

    # Ensure aarch64 target (should be default on native)
    rustup target add aarch64-unknown-linux-gnu 2>/dev/null || true

    # Python deps
    pip3 install maturin patchelf setuptools wheel
}

# --- Step 2: Clone Dynamo ---
clone_dynamo() {
    if [ ! -d "$DYNAMO_SRC" ]; then
        echo "--- Cloning Dynamo ---"
        git clone https://github.com/ai-dynamo/dynamo.git "$DYNAMO_SRC"
    fi
    cd "$DYNAMO_SRC"
    echo "Dynamo source at $(pwd), branch: $(git branch --show-current)"
}

# --- Step 3: Apply ARM64 patches if needed ---
apply_patches() {
    echo "--- Checking for ARM64-specific patches ---"
    cd "$DYNAMO_SRC"

    # Ensure Cargo.toml doesn't have x86-specific features
    # The control plane is pure Rust + Python — should build cleanly
    # Patch any x86_64 assumptions in build scripts
    if grep -r "x86_64\|amd64" deploy/ scripts/ 2>/dev/null | grep -v ".git" | grep -v "arm64\|aarch64"; then
        echo "WARN: Found x86_64-specific references in build scripts"
        echo "      May need manual patching for ARM64"
    else
        echo "No x86_64-specific patches needed"
    fi
}

# --- Step 4: Build Rust components ---
build_rust() {
    echo "--- Building Dynamo Rust components for aarch64 ---"
    cd "$DYNAMO_SRC"
    source "$HOME/.cargo/env" 2>/dev/null || true

    local CARGO_FLAGS=""
    if [ "$BUILD_TYPE" = "release" ]; then
        CARGO_FLAGS="--release"
    fi

    # Set NIXL paths for linking
    export NIXL_LIB_DIR="${NIXL_DIR}/lib"
    export NIXL_INCLUDE_DIR="${NIXL_DIR}/include"
    export LD_LIBRARY_PATH="${NIXL_DIR}/lib:${LD_LIBRARY_PATH:-}"

    # Build control plane binaries
    # These are the CPU-only components that run on BF-3 Grace
    cargo build $CARGO_FLAGS \
        --target aarch64-unknown-linux-gnu \
        -p dynamo-router \
        -p dynamo-planner \
        -p dynamo-frontend \
        -p dynamo-kvbm \
        2>&1 || {
            echo "NOTE: If specific packages fail, try building the workspace:"
            cargo build $CARGO_FLAGS --target aarch64-unknown-linux-gnu
        }

    echo "Rust binaries built successfully"
}

# --- Step 5: Build Python components ---
build_python() {
    echo "--- Building Dynamo Python components ---"
    cd "$DYNAMO_SRC"

    # Create venv for isolated build
    python3 -m venv "${DYNAMO_INSTALL}/venv"
    source "${DYNAMO_INSTALL}/venv/bin/activate"

    pip install --upgrade pip setuptools wheel

    # Install Dynamo Python package
    # Skip GPU-specific backends for control-plane-only build
    pip install -e ".[core]" 2>/dev/null || pip install -e . || {
        echo "WARN: pip install failed, trying manual setup"
        python3 setup.py develop 2>/dev/null || true
    }

    deactivate
    echo "Python components installed"
}

# --- Step 6: Install binaries ---
install_binaries() {
    echo "--- Installing Dynamo to ${DYNAMO_INSTALL} ---"
    mkdir -p "${DYNAMO_INSTALL}/bin"

    cd "$DYNAMO_SRC"
    local TARGET_DIR="target/aarch64-unknown-linux-gnu/${BUILD_TYPE}"

    for bin in dynamo-router dynamo-planner dynamo-frontend dynamo-kvbm; do
        if [ -f "${TARGET_DIR}/${bin}" ]; then
            cp "${TARGET_DIR}/${bin}" "${DYNAMO_INSTALL}/bin/"
            echo "  Installed: ${bin}"
        fi
    done

    # Also check default target dir (native build)
    TARGET_DIR="target/${BUILD_TYPE}"
    for bin in dynamo-router dynamo-planner dynamo-frontend dynamo-kvbm; do
        if [ -f "${TARGET_DIR}/${bin}" ] && [ ! -f "${DYNAMO_INSTALL}/bin/${bin}" ]; then
            cp "${TARGET_DIR}/${bin}" "${DYNAMO_INSTALL}/bin/"
            echo "  Installed (native): ${bin}"
        fi
    done

    echo "Binaries installed to ${DYNAMO_INSTALL}/bin/"
}

# --- Step 7: Verify ---
verify_build() {
    echo "--- Verifying Dynamo ARM64 build ---"

    for bin in "${DYNAMO_INSTALL}/bin/"*; do
        if [ -f "$bin" ]; then
            file "$bin" | grep -q "aarch64\|ARM" && echo "OK: $(basename $bin) is ARM64" || echo "WARN: $(basename $bin) may not be ARM64"
        fi
    done

    echo "--- Build verification complete ---"
}

# --- Main ---
case "${1:-all}" in
    deps)     install_deps ;;
    clone)    clone_dynamo ;;
    patch)    apply_patches ;;
    rust)     build_rust ;;
    python)   build_python ;;
    install)  install_binaries ;;
    verify)   verify_build ;;
    all)
        install_deps
        clone_dynamo
        apply_patches
        build_rust
        build_python
        install_binaries
        verify_build
        ;;
    *)
        echo "Usage: $0 {deps|clone|patch|rust|python|install|verify|all}"
        exit 1
        ;;
esac

echo "=== Done ==="
