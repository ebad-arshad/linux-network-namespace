#!/usr/bin/env bash
set -euo pipefail

# Define variables
OUT_IFACE="enp8s0" # ip route | grep default
HOST_IP="192.168.1.50" # ip addr | grep -w inet
BR_IP="172.20.0.1/24"
ALPHA_IP="172.20.0.10/24"
BETA_IP="172.20.0.20/24"

echo "[+] Creating namespaces..."
sudo ip netns add node-alpha
sudo ip netns add node-beta

echo "[+] Enabling loopback interfaces..."
sudo ip netns exec node-alpha ip link set lo up
sudo ip netns exec node-beta ip link set lo up

echo "[+] Configuring virtual bridge..."
sudo ip link add name br0 type bridge
sudo ip addr add "${BR_IP}" dev br0
sudo ip link set dev br0 up

echo "[+] Attaching node-alpha veth pair..."
sudo ip link add veth-alpha-br type veth peer name veth-alpha netns node-alpha
sudo ip link set veth-alpha-br master br0
sudo ip link set veth-alpha-br up
sudo ip netns exec node-alpha ip addr add "${ALPHA_IP}" dev veth-alpha
sudo ip netns exec node-alpha ip link set veth-alpha up

echo "[+] Attaching node-beta veth pair..."
sudo ip link add veth-beta-br type veth peer name veth-beta netns node-beta
sudo ip link set veth-beta-br master br0
sudo ip link set veth-beta-br up
sudo ip netns exec node-beta ip addr add "${BETA_IP}" dev veth-beta
sudo ip netns exec node-beta ip link set veth-beta up

echo "[+] Setting default routes inside namespaces..."
sudo ip netns exec node-alpha ip route add default via 172.20.0.1
sudo ip netns exec node-beta ip route add default via 172.20.0.1

echo "[+] Enabling IPv4 packet forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "[+] Configuring NAT Egress (SNAT/Masquerade)..."
sudo iptables -t nat -A POSTROUTING -s 172.20.0.0/24 -o "${OUT_IFACE}" -j MASQUERADE
sudo iptables -A FORWARD -i br0 -o "${OUT_IFACE}" -j ACCEPT
sudo iptables -A FORWARD -i "${OUT_IFACE}" -o br0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "[+] Configuring NAT Ingress (Port Forwarding DNAT: 9090 -> 8080)..."
sudo iptables -t nat -A PREROUTING -p tcp -d "${HOST_IP}" --dport 9090 -j DNAT --to-destination 172.20.0.10:8080
sudo iptables -t nat -A OUTPUT -p tcp -d "${HOST_IP}" --dport 9090 -j DNAT --to-destination 172.20.0.10:8080
sudo iptables -A FORWARD -p tcp -d 172.20.0.10 --dport 8080 -j ACCEPT

echo "[+] Configuring isolated DNS resolvers..."
sudo mkdir -p /etc/netns/node-alpha /etc/netns/node-beta
echo "nameserver 8.8.8.8" | sudo tee /etc/netns/node-alpha/resolv.conf > /dev/null
echo "nameserver 1.1.1.1" | sudo tee /etc/netns/node-beta/resolv.conf > /dev/null

echo "[✓] Mini-CNI setup complete!"
