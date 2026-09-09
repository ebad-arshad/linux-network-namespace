#!/usr/bin/env bash
set -uo pipefail

OUT_IFACE="enp8s0"
HOST_IP="192.168.1.50"

echo "[+] Removing namespaces..."
sudo ip netns del node-alpha 2>/dev/null || true
sudo ip netns del node-beta 2>/dev/null || true

echo "[+] Bringing down and deleting bridge..."
sudo ip link set dev br0 down 2>/dev/null || true
sudo ip link del dev br0 2>/dev/null || true

echo "[+] Cleaning up iptables rules..."
sudo iptables -t nat -D POSTROUTING -s 172.20.0.0/24 -o "${OUT_IFACE}" -j MASQUERADE 2>/dev/null || true
sudo iptables -D FORWARD -i br0 -o "${OUT_IFACE}" -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i "${OUT_IFACE}" -o br0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
sudo iptables -t nat -D PREROUTING -p tcp -d "${HOST_IP}" --dport 9090 -j DNAT --to-destination 172.20.0.10:8080 2>/dev/null || true
sudo iptables -t nat -D OUTPUT -p tcp -d "${HOST_IP}" --dport 9090 -j DNAT --to-destination 172.20.0.10:8080 2>/dev/null || true
sudo iptables -D FORWARD -p tcp -d 172.20.0.10 --dport 8080 -j ACCEPT 2>/dev/null || true

echo "[+] Removing DNS directories..."
sudo rm -rf /etc/netns/node-alpha /etc/netns/node-beta

echo "[✓] System network clean and restored."
