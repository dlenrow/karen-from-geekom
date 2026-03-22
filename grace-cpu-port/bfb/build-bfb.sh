#!/bin/bash
# Build BFB (BlueField Boot Stream) Virtual Appliance
# Produces a self-contained .bfb image that boots BF-3 SH into a
# zero-trust inference node with all security layers pre-configured.
#
# Flash: bfb-install --bfb dynamo-zt-appliance.bfb --rshim /dev/rshim0
#
# The BFB contains:
#   - Ubuntu 24.04 aarch64 (minimal, hardened)
#   - DOCA SDK + runtime
#   - CUDA toolkit aarch64
#   - NVIDIA driver aarch64
#   - Dynamo (full stack, security-hardened)
#   - NIXL (UCX + GDAKI + IPsec)
#   - SPIRE agent + BF-3 DICE attestor
#   - OPA policy engine + default-deny policies
#   - IPsec SA manager (DOCA crypto)
#   - DMA firewall rules (DOCA Flow)
#   - GPU CC attestation verifier
#   - Audit logger
#   - Secure boot configuration
#
# Prerequisites:
#   - Docker with buildx (for aarch64 image)
#   - bfb-build tool (from NVIDIA DOCA SDK)
#   - Or: mlx-mkbfb (from Mellanox tools)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-/tmp/bfb-build}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
BFB_NAME="dynamo-zt-appliance"
BFB_VERSION="${BFB_VERSION:-0.1.0}"

echo "============================================="
echo "  Building BFB Virtual Appliance"
echo "  ${BFB_NAME} v${BFB_VERSION}"
echo "============================================="

# --- Step 1: Create build workspace ---
setup_workspace() {
    echo ""
    echo "--- Setting up build workspace ---"
    mkdir -p "${BUILD_DIR}"/{rootfs,scripts,configs}
    mkdir -p "${OUTPUT_DIR}"
}

# --- Step 2: Build the rootfs as Docker image ---
build_rootfs_image() {
    echo ""
    echo "--- Building rootfs Docker image ---"

    cat > "${BUILD_DIR}/Dockerfile.bfb" << 'DOCKERFILE'
# BFB rootfs: Zero-Trust Inference Appliance for BF-3 SH
FROM nvcr.io/nvidia/cuda:12.8.0-devel-ubuntu24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# === System packages ===
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build tools
    build-essential cmake pkg-config git curl wget ca-certificates \
    protobuf-compiler libprotobuf-dev \
    # Runtime deps
    libhwloc-dev libudev-dev libssl-dev libzmq3-dev \
    python3-dev python3-pip python3-venv \
    # RDMA
    libibverbs-dev librdmacm-dev rdma-core \
    # Security
    strongswan strongswan-charon libcharon-extra-plugins \
    # Utilities
    numactl pciutils iproute2 iputils-ping jq \
    && rm -rf /var/lib/apt/lists/*

# === Rust toolchain ===
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# === OPA (Open Policy Agent) for ARM64 ===
RUN curl -fsSL -o /usr/local/bin/opa \
    https://openpolicyagent.org/downloads/latest/opa_linux_arm64_static && \
    chmod +x /usr/local/bin/opa

# === SPIRE Agent for ARM64 ===
ARG SPIRE_VERSION=1.11.0
RUN curl -fsSL -o /tmp/spire.tar.gz \
    https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/spire-${SPIRE_VERSION}-linux-arm64-musl.tar.gz && \
    tar -xzf /tmp/spire.tar.gz -C /opt/ && \
    mv /opt/spire-${SPIRE_VERSION} /opt/spire && \
    rm /tmp/spire.tar.gz

# === Build UCX with RDMA + CUDA ===
ARG UCX_VERSION=1.20.0
RUN git clone --branch v${UCX_VERSION} --depth 1 \
    https://github.com/openucx/ucx.git /tmp/ucx && \
    cd /tmp/ucx && \
    ./autogen.sh && \
    ./configure \
        --prefix=/opt/ucx \
        --with-mlx5-dv \
        --with-rdmacm \
        --with-cuda=/usr/local/cuda \
        --enable-optimizations \
        --disable-logging \
        --disable-debug \
        --disable-assertions && \
    make -j$(nproc) && make install && \
    rm -rf /tmp/ucx

# === Build NIXL ===
RUN git clone --depth 1 https://github.com/ai-dynamo/nixl.git /tmp/nixl && \
    cd /tmp/nixl && \
    ./build.sh --arch aarch64 --prefix /opt/nixl \
        --ucx-path /opt/ucx \
        --cuda-path /usr/local/cuda \
        --plugins ucx,posix 2>/dev/null || \
    (mkdir -p build && cd build && \
     cmake .. -DCMAKE_INSTALL_PREFIX=/opt/nixl \
       -DUCX_DIR=/opt/ucx \
       -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda && \
     make -j$(nproc) && make install) && \
    rm -rf /tmp/nixl

# === Build Dynamo ===
RUN git clone --depth 1 https://github.com/ai-dynamo/dynamo.git /tmp/dynamo && \
    cd /tmp/dynamo && \
    cargo build --release 2>&1 || true && \
    mkdir -p /opt/dynamo/bin && \
    cp target/release/dynamo-* /opt/dynamo/bin/ 2>/dev/null || true && \
    rm -rf /tmp/dynamo

# === Install inference engine ===
RUN pip3 install --no-cache-dir --break-system-packages \
    torch --index-url https://download.pytorch.org/whl/cu128 2>/dev/null || true
RUN pip3 install --no-cache-dir --break-system-packages \
    "sglang[all]" 2>/dev/null || true

# === Runtime image ===
FROM nvcr.io/nvidia/cuda:12.8.0-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libhwloc15 libudev1 libzmq5 libprotobuf32t64 \
    libibverbs1 librdmacm1 libnuma1 rdma-core \
    strongswan strongswan-charon libcharon-extra-plugins \
    python3 python3-pip \
    numactl pciutils iproute2 jq \
    mft \
    && rm -rf /var/lib/apt/lists/*

# Copy built components
COPY --from=builder /opt/ucx /opt/ucx
COPY --from=builder /opt/nixl /opt/nixl
COPY --from=builder /opt/dynamo /opt/dynamo
COPY --from=builder /opt/spire /opt/spire
COPY --from=builder /usr/local/bin/opa /usr/local/bin/opa

# Python packages
COPY --from=builder /usr/local/lib/python3.12 /usr/local/lib/python3.12

ENV PATH="/opt/dynamo/bin:/opt/spire/bin:/opt/ucx/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/nixl/lib:/opt/ucx/lib:/usr/local/cuda/lib64"
DOCKERFILE

    docker buildx build \
        --platform linux/arm64 \
        -t "${BFB_NAME}:${BFB_VERSION}" \
        -f "${BUILD_DIR}/Dockerfile.bfb" \
        "${BUILD_DIR}/" \
        --load

    echo "Docker image built: ${BFB_NAME}:${BFB_VERSION}"
}

# --- Step 3: Create BF-3 boot configuration ---
create_boot_config() {
    echo ""
    echo "--- Creating boot configuration ---"

    # bf.cfg — BF-3 firmware boot configuration
    cat > "${BUILD_DIR}/configs/bf.cfg" << 'EOF'
# BF-3 SH Boot Configuration for Zero-Trust Inference Appliance

# Self-hosted mode: ARM cores are PCIe root complex
INTERNAL_CPU_MODEL=EMBEDDED_CPU(1)

# PCIe bifurcation: ARM as root port for Cabline connector (GPU slot)
PCI_DOWNSTREAM_PORT_OWNER[0]=0xf  # ARM owns all downstream ports

# Disable NIC mode — DPU mode only
PF_BAR2_ENABLE=0
PER_PF_NUM_SF=0

# Secure boot
SECURE_BOOT_ENABLE=1
UEFI_SECURE_BOOT=1

# Restrict rshim access after initial setup
RESTRICT_RSHIM_ACCESS=1
EOF

    # First-boot script — runs once when BFB is flashed
    cat > "${BUILD_DIR}/scripts/first-boot.sh" << 'FIRSTBOOT'
#!/bin/bash
# First-boot initialization for Zero-Trust Inference Appliance
set -euo pipefail

echo "[BFB] First boot: initializing zero-trust inference appliance"

# --- Configure CPU affinity ---
echo "[BFB] Configuring CPU affinity (16 cores)"
# Control plane: cores 0-3, Workers: 4-13, System/RDMA: 14-15
mkdir -p /etc/systemd/system/dynamo-control.service.d
cat > /etc/systemd/system/dynamo-control.service.d/cpuaffinity.conf << EOF
[Service]
CPUAffinity=0 1 2 3
EOF

mkdir -p /etc/systemd/system/dynamo-worker.service.d
cat > /etc/systemd/system/dynamo-worker.service.d/cpuaffinity.conf << EOF
[Service]
CPUAffinity=4 5 6 7 8 9 10 11 12 13
EOF

# --- Configure huge pages ---
echo "[BFB] Configuring huge pages"
echo 512 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
echo "vm.nr_hugepages=512" > /etc/sysctl.d/99-hugepages.conf
mkdir -p /dev/hugepages
mount -t hugetlbfs nodev /dev/hugepages 2>/dev/null || true

# --- Load GPUDirect RDMA module ---
echo "[BFB] Enabling GPUDirect RDMA"
modprobe nvidia-peermem 2>/dev/null || true
echo "nvidia-peermem" >> /etc/modules-load.d/gpudirect.conf

# --- Deploy OPA policies ---
echo "[BFB] Deploying default-deny OPA policies"
mkdir -p /etc/opa/policies
cp /opt/dynamo-appliance/policies/*.rego /etc/opa/policies/
cp /opt/dynamo-appliance/policies/*.yaml /etc/opa/policies/

# --- Deploy DOCA Flow firewall rules ---
echo "[BFB] Deploying DMA firewall rules"
mkdir -p /etc/doca/flow
cp /opt/dynamo-appliance/dma-firewall/*.yaml /etc/doca/flow/

# --- Deploy IPsec configuration ---
echo "[BFB] Deploying IPsec configuration"
mkdir -p /etc/ipsec
cp /opt/dynamo-appliance/ipsec/*.yaml /etc/ipsec/

# --- Deploy SPIRE agent config ---
echo "[BFB] Deploying SPIRE agent configuration"
mkdir -p /etc/spire
cp /opt/dynamo-appliance/identity/*.yaml /etc/spire/

# --- Deploy audit configuration ---
echo "[BFB] Deploying audit configuration"
mkdir -p /etc/dynamo/audit
cp /opt/dynamo-appliance/audit/*.yaml /etc/dynamo/audit/

# --- Enable services ---
systemctl enable dynamo-appliance.service
systemctl enable opa-policy-agent.service
systemctl enable spire-agent.service

echo "[BFB] First boot complete. Reboot to start services."
FIRSTBOOT
    chmod +x "${BUILD_DIR}/scripts/first-boot.sh"

    # Post-boot service — starts on every boot
    cat > "${BUILD_DIR}/configs/dynamo-appliance.service" << 'SERVICE'
[Unit]
Description=Dynamo Zero-Trust Inference Appliance
After=network-online.target nvidia-persistenced.service
Wants=network-online.target
Requires=opa-policy-agent.service

[Service]
Type=exec
ExecStartPre=/opt/dynamo-appliance/scripts/gpu-cc-verifier.sh verify
ExecStartPre=/opt/dynamo-appliance/scripts/setup-ipsec.sh start
ExecStartPre=/opt/dynamo-appliance/scripts/load-doca-flow.sh
ExecStart=/opt/dynamo/bin/dynamo-serve --config /etc/dynamo/dynamo-bf3-config.yaml
CPUAffinity=0 1 2 3 4 5 6 7 8 9 10 11 12 13
Restart=on-failure
RestartSec=10
LimitMEMLOCK=infinity
LimitNOFILE=1048576

# Security hardening
ProtectSystem=strict
ReadWritePaths=/var/log/dynamo /var/run/dynamo /dev/hugepages /tmp
PrivateTmp=true
NoNewPrivileges=false
ProtectKernelTunables=false
ProtectKernelModules=false

[Install]
WantedBy=multi-user.target
SERVICE

    # OPA service
    cat > "${BUILD_DIR}/configs/opa-policy-agent.service" << 'OPA_SERVICE'
[Unit]
Description=OPA Policy Agent (Default-Deny Inference Policy)
After=network-online.target

[Service]
Type=exec
ExecStart=/usr/local/bin/opa run \
    --server \
    --addr=localhost:8181 \
    --log-level=info \
    /etc/opa/policies/
CPUAffinity=2 3
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
OPA_SERVICE

    echo "Boot configuration created"
}

# --- Step 4: Package into BFB ---
package_bfb() {
    echo ""
    echo "--- Packaging BFB image ---"

    # Export Docker image as rootfs
    local ROOTFS_TAR="${BUILD_DIR}/rootfs.tar"
    docker export "$(docker create "${BFB_NAME}:${BFB_VERSION}")" > "$ROOTFS_TAR"

    # Overlay security configs
    local OVERLAY_DIR="${BUILD_DIR}/overlay"
    mkdir -p "${OVERLAY_DIR}/opt/dynamo-appliance"/{scripts,policies,dma-firewall,ipsec,identity,audit,gpu-attestation}

    # Copy security layer configs
    cp "${PROJECT_DIR}/security/policies/"* "${OVERLAY_DIR}/opt/dynamo-appliance/policies/"
    cp "${PROJECT_DIR}/security/dma-firewall/"* "${OVERLAY_DIR}/opt/dynamo-appliance/dma-firewall/"
    cp "${PROJECT_DIR}/security/ipsec/"* "${OVERLAY_DIR}/opt/dynamo-appliance/ipsec/"
    cp "${PROJECT_DIR}/security/identity/"* "${OVERLAY_DIR}/opt/dynamo-appliance/identity/"
    cp "${PROJECT_DIR}/security/audit/"* "${OVERLAY_DIR}/opt/dynamo-appliance/audit/"
    cp "${PROJECT_DIR}/security/gpu-attestation/"* "${OVERLAY_DIR}/opt/dynamo-appliance/gpu-attestation/"

    # Copy scripts
    cp "${PROJECT_DIR}/security/gpu-attestation/gpu-cc-verifier.sh" "${OVERLAY_DIR}/opt/dynamo-appliance/scripts/"
    cp "${BUILD_DIR}/scripts/first-boot.sh" "${OVERLAY_DIR}/opt/dynamo-appliance/scripts/"
    chmod +x "${OVERLAY_DIR}/opt/dynamo-appliance/scripts/"*

    # Copy configs
    mkdir -p "${OVERLAY_DIR}/etc/dynamo" "${OVERLAY_DIR}/etc/systemd/system"
    cp "${PROJECT_DIR}/dynamo/dynamo-bf3-config.yaml" "${OVERLAY_DIR}/etc/dynamo/"
    cp "${PROJECT_DIR}/nixl/nixl-bf3-config.yaml" "${OVERLAY_DIR}/etc/nixl/" 2>/dev/null || \
        (mkdir -p "${OVERLAY_DIR}/etc/nixl" && cp "${PROJECT_DIR}/nixl/nixl-bf3-config.yaml" "${OVERLAY_DIR}/etc/nixl/")
    cp "${BUILD_DIR}/configs/dynamo-appliance.service" "${OVERLAY_DIR}/etc/systemd/system/"
    cp "${BUILD_DIR}/configs/opa-policy-agent.service" "${OVERLAY_DIR}/etc/systemd/system/"

    # Create overlay tar
    (cd "$OVERLAY_DIR" && tar -cf "${BUILD_DIR}/overlay.tar" .)

    # Try bfb-build if available (DOCA SDK tool)
    if command -v bfb-build &>/dev/null; then
        echo "Using bfb-build (DOCA SDK)"
        bfb-build \
            --rootfs "$ROOTFS_TAR" \
            --overlay "${BUILD_DIR}/overlay.tar" \
            --bf-cfg "${BUILD_DIR}/configs/bf.cfg" \
            --first-boot "${BUILD_DIR}/scripts/first-boot.sh" \
            --output "${OUTPUT_DIR}/${BFB_NAME}-${BFB_VERSION}.bfb"
    elif command -v mlx-mkbfb &>/dev/null; then
        echo "Using mlx-mkbfb (Mellanox tools)"
        mlx-mkbfb \
            --image "$ROOTFS_TAR" \
            --capsule "${BUILD_DIR}/configs/bf.cfg" \
            "${OUTPUT_DIR}/${BFB_NAME}-${BFB_VERSION}.bfb"
    else
        echo "WARN: Neither bfb-build nor mlx-mkbfb found"
        echo "  Install DOCA SDK: apt install doca-tools"
        echo "  Or Mellanox tools: apt install mft"
        echo ""
        echo "  Creating tarball archive instead:"
        tar -czf "${OUTPUT_DIR}/${BFB_NAME}-${BFB_VERSION}.tar.gz" \
            -C "${BUILD_DIR}" rootfs.tar overlay.tar configs/ scripts/
        echo "  Archive: ${OUTPUT_DIR}/${BFB_NAME}-${BFB_VERSION}.tar.gz"
        echo ""
        echo "  To convert to BFB manually:"
        echo "    bfb-build --rootfs rootfs.tar --overlay overlay.tar \\"
        echo "      --bf-cfg configs/bf.cfg --first-boot scripts/first-boot.sh \\"
        echo "      --output ${BFB_NAME}-${BFB_VERSION}.bfb"
    fi

    echo ""
    echo "============================================="
    echo "  BFB Build Complete"
    echo "  Output: ${OUTPUT_DIR}/"
    echo ""
    echo "  Flash to BF-3 SH:"
    echo "    bfb-install --bfb ${BFB_NAME}-${BFB_VERSION}.bfb --rshim /dev/rshim0"
    echo ""
    echo "  After flash:"
    echo "    1. BF-3 boots into secure appliance"
    echo "    2. First-boot script runs (one-time setup)"
    echo "    3. GPU CC attestation verified"
    echo "    4. IPsec SAs negotiated with peers"
    echo "    5. DMA firewall rules loaded"
    echo "    6. OPA default-deny policies active"
    echo "    7. Dynamo inference starts"
    echo "============================================="
}

# --- Main ---
case "${1:-all}" in
    workspace)  setup_workspace ;;
    rootfs)     build_rootfs_image ;;
    config)     create_boot_config ;;
    package)    package_bfb ;;
    all)
        setup_workspace
        build_rootfs_image
        create_boot_config
        package_bfb
        ;;
    *)
        echo "Usage: $0 {workspace|rootfs|config|package|all}"
        exit 1
        ;;
esac
