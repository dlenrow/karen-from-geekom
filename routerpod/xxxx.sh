#!/bin/bash

# Define the trunk interface and VLAN parameters
TRUNK_IFACE="enx0"
VLAN_ID=52
VLAN_IFACE="${TRUNK_IFACE}.${VLAN_ID}"
IP_ADDR="192.168.100.1/24"

# Check if the trunk interface exists
if ! ip link show "$TRUNK_IFACE" &>/dev/null; then
  echo "Error: Trunk interface $TRUNK_IFACE does not exist."
  exit 1
fi

# Create the VLAN interface
echo "Creating VLAN interface $VLAN_IFACE on $TRUNK_IFACE for VLAN ID $VLAN_ID..."
ip link add link "$TRUNK_IFACE" name "$VLAN_IFACE" type vlan id "$VLAN_ID"

# Bring up the VLAN interface
echo "Bringing up VLAN interface $VLAN_IFACE with IP address $IP_ADDR..."
ip addr add "$IP_ADDR" dev "$VLAN_IFACE"
ip link set dev "$VLAN_IFACE" up

# Enable promiscuous mode on the trunk interface (optional for debugging)
echo "Enabling promiscuous mode on $TRUNK_IFACE for debugging..."
ip link set dev "$TRUNK_IFACE" promisc on

# Verify the configuration
echo "VLAN $VLAN_ID interface $VLAN_IFACE setup complete. Current configuration:"
ip addr show "$VLAN_IFACE"
ip link show "$VLAN_IFACE"

# Confirm traffic with tcpdump
echo "Starting tcpdump on $VLAN_IFACE to verify traffic..."
tcpdump -i "$VLAN_IFACE" -nn -e vlan &

