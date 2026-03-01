#!/bin/bash

# Check if the duration in seconds is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <duration_in_seconds>"
  exit 1
fi

DURATION=$1

# Discover available interfaces
INTERFACES=$(tcpdump -D | awk -F'.' '{print $2}' | awk '{print $1}')

# Delete existing dump files
rm -f tcpdump_*.pcap

# Start a tcpdump session for each interface
for IFACE in $INTERFACES; do
  echo "Starting tcpdump on interface $IFACE"
  sudo tcpdump -i "$IFACE" -vvv -e -w "tcpdump_${IFACE}.pcap" &
done

# Capture for the specified duration
sleep "$DURATION"

# Stop all tcpdump processes
echo "Stopping all tcpdump sessions..."
sudo pkill tcpdump

echo "Capture complete. Files saved as tcpdump_<interface>.pcap"


