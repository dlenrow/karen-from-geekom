# KAREN/KNP Geekom NUC System State
# Captured: 2026-03-01T18:48:38Z

## System
Hostname: drl-EffiZen-Series
OS: "Ubuntu 22.10"
Kernel: 5.19.0-46-generic
CPU: 
RAM: 
Disk: 

## Network
WiFi: wlo1 → 192.168.1.158/24 (DHCP from home router)
Eth enx0: 192.168.50.1/24 (static, KNP downstream)
Tailscale: 100.89.87.97
Cilium: 10.0.0.245

## K3s
Version: k3s version v1.30.6+k3s1 (1829eaae)
Workloads: VLAN 52-55 deployments (DHCP+NAT per VLAN)
CNI: Cilium + Multus (macvlan for VLANs)
Rancher: cattle-system (CrashLoopBackOff — stale)

## Services
k3s.service — Kubernetes
isc-dhcp-server — DHCP for downstream clients
tailscaled — Tailscale VPN
NetworkManager — WiFi + Ethernet

## DHCP Subnets
192.168.50.0/24 — enx0 downstream
192.168.51.0/24 — secondary
192.168.100.0/24 — VLAN 52
10.42.53.0/24 — VLAN 53
10.42.54.0/24 — VLAN 54
10.42.55.0/24 — VLAN 55
