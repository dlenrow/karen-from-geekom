from scapy.all import IP, ICMP, send

# Configure source and destination IPs
src_ip = "100.121.170.114"  # Replace with the laptop's Tailscale IP
dst_ip = "100.89.87.97"  # Replace with the appliance's Tailscale IP

# Configure the interface to send the packet
interface = "enx_w52"  # Replace with the correct interface name

# Create an IP packet with ICMP (ping request)
packet = IP(src=src_ip, dst=dst_ip) / ICMP()

# Send the packet on the specified interface
print(f"Sending packet from {src_ip} to {dst_ip} via {interface}")
send(packet, iface=interface)
send(packet, iface=interface)
send(packet, iface=interface)
send(packet, iface=interface)
send(packet, iface=interface)
send(packet, iface=interface)
send(packet, iface=interface)
send(packet, iface=interface)
send(packet, iface=interface)
send(packet, iface=interface)

