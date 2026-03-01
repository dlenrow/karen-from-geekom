#!/bin/bash

# Check if the base interface enx exists
if ! ip link show enx &> /dev/null; then
  echo "Base interface enx not found. Please ensure enx is up before running this script."
  exit 1
fi

# Check if enx_w52 already exists and delete if it does
if ip link show enx_w52 &> /dev/null; then
  echo "Deleting existing enx_w52 interface..."
  ip link delete enx_w52
fi

# Create VLAN interface enx_w52 with VLAN ID 52
echo "Creating VLAN interface enx_w52 with VLAN ID 52 on base interface enx..."
ip link add link enx name enx_w52 type vlan id 52

# Bring the interface up
ip link set enx_w52 up

# Optional: Assign an IP address if required (adjust IP address as needed)
# ip addr add 10.42.52.1/24 dev enx_w52

echo "Interface enx_w52 created and brought up in the default namespace."

