#!/bin/bash

# Set alias for kubectl command
alias k='sudo k3s kubectl'

# 1. Deploy the updated pod and service
k apply -f net-bridge-test-deployment.yaml
k apply -f net-bridge-test-service.yaml
k apply -f net-bridge-test-policy.yaml
echo "Deployment, Service, and initial Network Policy applied..."

# Wait for the pod to be ready
k wait --for=condition=ready pod -l app=net-bridge-test --timeout=60s

# Define the bridge IPs for testing
BRIDGE_IP="192.168.1.1"
PEER_IP="192.168.1.2"

# 2. Run a ping test from the host to the bridge IP
echo "Pinging bridge IP ($BRIDGE_IP) from host..."
ping -c 3 $BRIDGE_IP

# 3. Modify the Network Policy to allow only UDP traffic
echo "Applying Network Policy to allow only UDP..."
k delete -f net-bridge-test-policy.yaml
cat <<EOF | k apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-udp
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: net-bridge-test
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
      ports:
        - protocol: UDP
EOF

# 4. Test connectivity with restricted Network Policy
echo "Running ping test again to see it blocked by Network Policy..."
ping -c 3 $BRIDGE_IP

# 5. Cleanup resources
k delete -f net-bridge-test-deployment.yaml
k delete -f net-bridge-test-service.yaml
k delete -f net-bridge-test-policy.yaml
echo "Cleanup complete."

