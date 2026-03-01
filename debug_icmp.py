import socket
import struct
import os
import sys

def checksum(data):
    """Calculate the ICMP checksum."""
    s = 0
    n = len(data)
    for i in range(0, n, 2):
        if i + 1 < n:
            s += (data[i] << 8) + data[i + 1]
        else:
            s += data[i] << 8
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF

def create_icmp_packet():
    """Create an ICMP echo request packet."""
    icmp_type = 8  # Echo request
    icmp_code = 0
    icmp_id = os.getpid() & 0xFFFF  # Use process ID as ICMP ID
    icmp_seq = 1
    payload = b"debugping"  # Example payload
    header = struct.pack('!BBHHH', icmp_type, icmp_code, 0, icmp_id, icmp_seq)
    packet = header + payload
    chk = checksum(packet)
    header = struct.pack('!BBHHH', icmp_type, icmp_code, chk, icmp_id, icmp_seq)
    return header + payload

def send_icmp_request(src_ip, dest_ip, interface):
    """Send an ICMP request with a custom source IP and specified interface."""
    packet = create_icmp_packet()
    try:
        # Create a raw socket
        sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
        sock.setsockopt(socket.SOL_SOCKET, 25, interface.encode())
        
        # Build an IP header
        ip_ver = 4
        ip_ihl = 5
        ip_tos = 0
        ip_tot_len = 20 + len(packet)  # IP header + ICMP
        ip_id = 54321
        ip_frag_off = 0
        ip_ttl = 64
        ip_proto = socket.IPPROTO_ICMP
        ip_checksum = 0  # Calculated later
        ip_src = socket.inet_aton(src_ip)
        ip_dest = socket.inet_aton(dest_ip)
        
        ip_header = struct.pack(
            '!BBHHHBBH4s4s',
            (ip_ver << 4) + ip_ihl,
            ip_tos,
            ip_tot_len,
            ip_id,
            ip_frag_off,
            ip_ttl,
            ip_proto,
            ip_checksum,
            ip_src,
            ip_dest,
        )
        
        # Send the packet
        sock.sendto(ip_header + packet, (dest_ip, 0))
        print(f"Sent ICMP request from {src_ip} to {dest_ip} via {interface}")
    except PermissionError:
        print("You need to run this script as root!")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: sudo python3 debug_icmp.py <src_ip> <dest_ip> <interface>")
        sys.exit(1)

    src_ip = sys.argv[1]
    dest_ip = sys.argv[2]
    interface = sys.argv[3]

    send_icmp_request(src_ip, dest_ip, interface)

