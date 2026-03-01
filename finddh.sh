#!/bin/bash

# Loop over all .pcap files in the current directory
for pcap_file in *.pcap; do
    # Use tshark to search for "DHCP" packets in the current .pcap file
    if tshark -r "$pcap_file" | grep -q -i "icmp"; then
        # If "DHCP" is found, print the filename
        echo "ICMP packets found in $pcap_file"
    fi
done

