#!/bin/bash
# Setup BF-3 SH (Self-Hosted) with GPU on PCIe root complex
# This script configures the BF-3 to act as the sole host for a GPU
# in an adjacent PCIe slot via the Cabline CA-II Plus connector.
#
# Prerequisites:
#   - BF-3 SH (B3220SH) or BF-3 with firmware configured for self-hosted mode
#   - GPU installed in adjacent PCIe slot connected via Cabline
#   - Ubuntu 22.04/24.04 aarch64 running on BF-3 ARM cores
#   - Root access on BF-3

set -euo pipefail

echo "============================================="
echo "  BF-3 SH + GPU Setup"
echo "  Self-Hosted Mode (ARM as Root Complex)"
echo "============================================="

# --- Step 1: Verify BF-3 is in self-hosted mode ---
verify_self_hosted() {
    echo ""
    echo "--- Verifying BF-3 Self-Hosted Mode ---"

    # Check if running on ARM
    ARCH=$(uname -m)
    if [ "$ARCH" != "aarch64" ]; then
        echo "FAIL: Not running on aarch64 (got: $ARCH)"
        exit 1
    fi
    echo "OK: Running on aarch64"

    # Check for BF-3 identification
    if [ -f /sys/firmware/acpi/tables/MCFG ] || lspci 2>/dev/null | grep -qi "Mellanox\|ConnectX"; then
        echo "OK: BF-3 hardware detected"
    else
        echo "WARN: Could not confirm BF-3 hardware"
    fi

    # Check mlxconfig for self-hosted mode (if mlxconfig available)
    if command -v mlxconfig &>/dev/null; then
        local INTERNAL_CPU_MODEL=$(mlxconfig -d /dev/mst/mt41692_pciconf0 q 2>/dev/null | grep INTERNAL_CPU_MODEL || echo "")
        if echo "$INTERNAL_CPU_MODEL" | grep -qi "EMBEDDED_CPU"; then
            echo "OK: BF-3 firmware in embedded CPU (self-hosted) mode"
        else
            echo "INFO: INTERNAL_CPU_MODEL: $INTERNAL_CPU_MODEL"
            echo "      Ensure self-hosted mode is enabled in firmware"
        fi
    else
        echo "WARN: mlxconfig not found — cannot verify firmware mode"
        echo "      Install: apt install mft (Mellanox Firmware Tools)"
    fi
}

# --- Step 2: Verify GPU on PCIe root complex ---
verify_gpu_pcie() {
    echo ""
    echo "--- Verifying GPU on PCIe Root Complex ---"

    # List PCIe devices — GPU should appear as a downstream device
    echo "PCIe devices:"
    lspci -nn 2>/dev/null | grep -i "nvidia\|3d controller\|vga\|display" | head -10

    # Get GPU BDF
    GPU_BDF=$(lspci -d 10de: 2>/dev/null | grep -i "3d\|vga\|tesla\|a100\|h100\|l40\|a30\|a10" | head -1 | awk '{print $1}')
    if [ -n "$GPU_BDF" ]; then
        echo "OK: GPU found at PCIe BDF: $GPU_BDF"

        # Check PCIe link
        echo "PCIe link status:"
        lspci -vvs "$GPU_BDF" 2>/dev/null | grep -i "lnksta\|lnkcap\|width\|speed" | head -4 | sed 's/^/  /'

        # Check P2P topology with ConnectX-7
        CX_BDF=$(lspci -d 15b3: 2>/dev/null | head -1 | awk '{print $1}')
        if [ -n "$CX_BDF" ]; then
            echo ""
            echo "ConnectX-7 at: $CX_BDF"
            echo "GPU at:        $GPU_BDF"

            # Both should share the same root complex (BF-3 internal switch)
            CX_ROOT=$(basename "$(readlink -f "/sys/bus/pci/devices/0000:${CX_BDF}/../.." 2>/dev/null)" 2>/dev/null || echo "unknown")
            GPU_ROOT=$(basename "$(readlink -f "/sys/bus/pci/devices/0000:${GPU_BDF}/../.." 2>/dev/null)" 2>/dev/null || echo "unknown")
            echo "ConnectX-7 root: $CX_ROOT"
            echo "GPU root:        $GPU_ROOT"
        fi
    else
        echo "FAIL: No NVIDIA GPU found on PCIe bus"
        echo "  Check: Is GPU installed in adjacent slot?"
        echo "  Check: Is Cabline CA-II Plus connected?"
        echo "  Check: PCIe bifurcation config (mlxconfig)"
    fi
}

# --- Step 3: Install CUDA toolkit for aarch64 ---
install_cuda_arm64() {
    echo ""
    echo "--- Installing CUDA Toolkit (aarch64) ---"

    if command -v nvcc &>/dev/null; then
        echo "CUDA already installed: $(nvcc --version | grep release)"
        return 0
    fi

    # Add NVIDIA CUDA repo for aarch64
    local DISTRO="ubuntu2204"  # or ubuntu2404
    local CUDA_VERSION="12-8"

    wget -q https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/sbsa/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb
    apt-get update
    apt-get install -y cuda-toolkit-${CUDA_VERSION}

    # Add to PATH
    echo 'export PATH=/usr/local/cuda/bin:$PATH' >> /etc/profile.d/cuda.sh
    echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /etc/profile.d/cuda.sh
    source /etc/profile.d/cuda.sh

    echo "CUDA installed: $(nvcc --version | grep release)"
}

# --- Step 4: Install NVIDIA driver for aarch64 ---
install_nvidia_driver() {
    echo ""
    echo "--- Installing NVIDIA Driver (aarch64) ---"

    if command -v nvidia-smi &>/dev/null; then
        echo "NVIDIA driver already installed:"
        nvidia-smi --query-gpu=name,driver_version,pci.bus_id --format=csv,noheader
        return 0
    fi

    apt-get update
    apt-get install -y nvidia-driver-575-server  # or appropriate version

    echo "NVIDIA driver installed. Reboot may be required."
}

# --- Step 5: Enable GPUDirect RDMA ---
setup_gpudirect_rdma() {
    echo ""
    echo "--- Enabling GPUDirect RDMA ---"

    # Load nvidia-peermem kernel module
    modprobe nvidia-peermem 2>/dev/null && echo "OK: nvidia-peermem loaded" || {
        echo "WARN: nvidia-peermem module not found"
        echo "  Install: apt install nvidia-fabricmanager (or build from source)"
    }

    # Verify
    if lsmod | grep -q nvidia_peermem; then
        echo "OK: nvidia-peermem module loaded — GPUDirect RDMA enabled"
    fi

    # Make persistent
    echo "nvidia-peermem" >> /etc/modules-load.d/gpudirect.conf 2>/dev/null || true

    # Disable ACS (Access Control Services) for P2P
    # This allows direct P2P between ConnectX-7 and GPU through root complex
    echo ""
    echo "--- Disabling PCIe ACS for P2P ---"
    for dev in /sys/bus/pci/devices/*/; do
        if [ -f "${dev}config" ]; then
            # Check if device has ACS capability
            local acs_ctrl="${dev}acs_ctrl"
            if [ -f "$acs_ctrl" ]; then
                echo "Disabling ACS on $(basename $dev)"
                setpci -s "$(basename $dev)" ECAP_ACS+6.w=0000 2>/dev/null || true
            fi
        fi
    done

    # Disable IOMMU for GPUDirect (if enabled)
    if grep -q "iommu=on\|iommu=pt" /proc/cmdline; then
        echo "WARN: IOMMU is active. For best GPUDirect performance, add 'iommu=off' to kernel cmdline"
        echo "  Or use 'iommu=pt' (passthrough) as a compromise"
    fi
}

# --- Step 6: Configure CPU affinity for inference ---
setup_cpu_affinity() {
    echo ""
    echo "--- Configuring CPU Affinity (16 cores) ---"

    # Create cpuset for control plane (cores 0-3)
    mkdir -p /sys/fs/cgroup/cpuset/dynamo-control 2>/dev/null || true
    echo "0-3" > /sys/fs/cgroup/cpuset/dynamo-control/cpuset.cpus 2>/dev/null || true
    echo "0" > /sys/fs/cgroup/cpuset/dynamo-control/cpuset.mems 2>/dev/null || true

    # Create cpuset for inference workers (cores 4-13)
    mkdir -p /sys/fs/cgroup/cpuset/dynamo-workers 2>/dev/null || true
    echo "4-13" > /sys/fs/cgroup/cpuset/dynamo-workers/cpuset.cpus 2>/dev/null || true
    echo "0" > /sys/fs/cgroup/cpuset/dynamo-workers/cpuset.mems 2>/dev/null || true

    # Create cpuset for system/RDMA (cores 14-15)
    mkdir -p /sys/fs/cgroup/cpuset/system-rdma 2>/dev/null || true
    echo "14-15" > /sys/fs/cgroup/cpuset/system-rdma/cpuset.cpus 2>/dev/null || true
    echo "0" > /sys/fs/cgroup/cpuset/system-rdma/cpuset.mems 2>/dev/null || true

    # Pin RDMA IRQs to cores 14-15
    for irq in /proc/irq/*/mlx5_*; do
        if [ -d "$irq" ]; then
            echo "c000" > "${irq}/smp_affinity" 2>/dev/null || true  # Cores 14-15
        fi
    done

    echo "CPU affinity configured:"
    echo "  Cores 0-3:   Control plane (router, frontend, KVBM, events)"
    echo "  Cores 4-13:  Inference workers (SGLang/vLLM)"
    echo "  Cores 14-15: System, RDMA IRQs, NIXL completions"
}

# --- Step 7: Configure huge pages ---
setup_hugepages() {
    echo ""
    echo "--- Configuring Huge Pages ---"

    # 2MB huge pages for NIXL buffer pool and KV cache spillover
    local HUGEPAGES=${HUGEPAGES:-512}  # 512 x 2MB = 1GB
    echo "$HUGEPAGES" > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    echo "Allocated $HUGEPAGES x 2MB huge pages ($(( HUGEPAGES * 2 ))MB)"

    # Mount hugetlbfs
    mkdir -p /dev/hugepages
    mount -t hugetlbfs nodev /dev/hugepages 2>/dev/null || true

    # Make persistent
    echo "vm.nr_hugepages=$HUGEPAGES" >> /etc/sysctl.d/99-hugepages.conf 2>/dev/null || true
}

# --- Step 8: Verify full setup ---
verify_setup() {
    echo ""
    echo "============================================="
    echo "  BF-3 SH + GPU Setup Verification"
    echo "============================================="

    echo ""
    echo "--- System ---"
    echo "  Arch: $(uname -m)"
    echo "  Kernel: $(uname -r)"
    echo "  Cores: $(nproc)"
    echo "  Memory: $(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo)"

    echo ""
    echo "--- GPU ---"
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=name,memory.total,pci.bus_id,pcie.link.gen.current,pcie.link.width.current \
            --format=csv,noheader 2>/dev/null | sed 's/^/  /'
    else
        echo "  nvidia-smi not found"
    fi

    echo ""
    echo "--- CUDA ---"
    if command -v nvcc &>/dev/null; then
        echo "  $(nvcc --version 2>/dev/null | grep release)"
    else
        echo "  nvcc not found"
    fi

    echo ""
    echo "--- RDMA ---"
    if command -v ibv_devinfo &>/dev/null; then
        ibv_devinfo -l 2>/dev/null | sed 's/^/  /'
    fi

    echo ""
    echo "--- GPUDirect RDMA ---"
    if lsmod | grep -q nvidia_peermem; then
        echo "  OK: nvidia-peermem loaded"
    else
        echo "  WARN: nvidia-peermem not loaded"
    fi

    echo ""
    echo "--- GPU↔NIC P2P Topology ---"
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi topo -m 2>/dev/null | head -10 | sed 's/^/  /' || echo "  (topo check requires multi-GPU or nvidia-fabricmanager)"
    fi

    echo ""
    echo "--- Huge Pages ---"
    echo "  Total: $(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages) x 2MB"
    echo "  Free:  $(cat /sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages) x 2MB"

    echo ""
    echo "============================================="
    echo "  Setup verification complete"
    echo "============================================="
}

# --- Main ---
case "${1:-all}" in
    verify-mode)   verify_self_hosted ;;
    verify-gpu)    verify_gpu_pcie ;;
    cuda)          install_cuda_arm64 ;;
    driver)        install_nvidia_driver ;;
    gpudirect)     setup_gpudirect_rdma ;;
    affinity)      setup_cpu_affinity ;;
    hugepages)     setup_hugepages ;;
    verify)        verify_setup ;;
    all)
        verify_self_hosted
        verify_gpu_pcie
        install_nvidia_driver
        install_cuda_arm64
        setup_gpudirect_rdma
        setup_cpu_affinity
        setup_hugepages
        verify_setup
        ;;
    *)
        echo "Usage: $0 {verify-mode|verify-gpu|driver|cuda|gpudirect|affinity|hugepages|verify|all}"
        exit 1
        ;;
esac
