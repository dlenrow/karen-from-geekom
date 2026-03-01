#!/bin/bash

# 1. Deploy the updated pod
kubectl apply -f network-bridge-deployment.yaml
echo "Deployment started..."

# Wait for the pod to be ready
kubectl wait --for=condition=ready pod -l app=network-bridge --timeout=60s

# Get the IPs for testing (assigned in the YAML)
BRIDGE_IP="192.168.1.1"
PEER_IP="192.168.1.2"

# 2. Run a ping test from the host to the bridge IP
echo "Pinging bridge IP ($BRIDGE_IP) from host..."
ping -c 3 $BRIDGE_IP

# 3. Set up tcpdump to observe the traffic on the bridge IP from the host
echo "Capturing traffic on the bridge interface (expected ICMP responses)..."
sudo tcpdump -i any host $PEER_IP -c 10 &

# 4. Run another ping test to see if responses are captured
ping -c 3 $PEER_IP

# 5. Cleanup resources after testing
kubectl delete deployment network-bridge-deployment
echo "Cleanup complete."


