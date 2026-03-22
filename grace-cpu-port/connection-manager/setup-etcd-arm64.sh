#!/bin/bash
# Setup etcd on BF-3 Grace CPU for standalone (non-K8s) Dynamo discovery
# etcd provides the kv_store backend for service discovery and NIXL metadata

set -euo pipefail

ETCD_VERSION="${ETCD_VERSION:-3.5.17}"
ETCD_INSTALL="${ETCD_INSTALL:-/opt/etcd}"
ETCD_DATA="${ETCD_DATA:-/var/lib/etcd}"
BF3_IP="${BF3_IP:-0.0.0.0}"

ARCH=$(uname -m)
case "$ARCH" in
    aarch64) ETCD_ARCH="arm64" ;;
    x86_64)  ETCD_ARCH="amd64" ;;
    *)       echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

echo "=== Setting up etcd ${ETCD_VERSION} (${ETCD_ARCH}) for BF-3 ==="

# Download etcd
mkdir -p "$ETCD_INSTALL"
cd /tmp

ETCD_URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}.tar.gz"
echo "Downloading: $ETCD_URL"
wget -q "$ETCD_URL" -O etcd.tar.gz
tar xzf etcd.tar.gz
cp "etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}/etcd" "${ETCD_INSTALL}/"
cp "etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}/etcdctl" "${ETCD_INSTALL}/"
rm -rf "etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}" etcd.tar.gz

# Create data directory
mkdir -p "$ETCD_DATA"

# Verify
"${ETCD_INSTALL}/etcd" --version
"${ETCD_INSTALL}/etcdctl" version

# Create systemd service
cat > /etc/systemd/system/etcd-dynamo.service << 'ETCD_SERVICE'
[Unit]
Description=etcd for Dynamo Discovery (BF-3)
After=network.target

[Service]
Type=notify
ExecStart=/opt/etcd/etcd \
  --name bf3-etcd \
  --data-dir /var/lib/etcd \
  --listen-client-urls http://0.0.0.0:2379 \
  --advertise-client-urls http://${BF3_IP}:2379 \
  --listen-peer-urls http://0.0.0.0:2380 \
  --initial-advertise-peer-urls http://${BF3_IP}:2380 \
  --initial-cluster bf3-etcd=http://${BF3_IP}:2380 \
  --initial-cluster-state new \
  --quota-backend-bytes 2147483648 \
  --auto-compaction-retention 1
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
ETCD_SERVICE

echo "etcd installed to ${ETCD_INSTALL}"
echo "To start: systemctl enable --now etcd-dynamo"
echo "To verify: ${ETCD_INSTALL}/etcdctl endpoint health"
