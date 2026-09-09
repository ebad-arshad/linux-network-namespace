# Pure-Linux Container Network (Mini-CNI)
### Native Kernel Primitives Implementation & Engineering Post-Mortem

This repository contains the engineering implementation, architectural blueprints, and operational post-mortem for **Project 1: Pure-Linux Container Network**. The objective of this project was to construct a fully functional virtual container network on a single Linux host from scratch, completely banning the use of container runtimes (Docker, Podman) or external orchestration tools. All functionality relies strictly on native Linux kernel primitives and firewall subsystems.

---

## 1. Architectural Topology

The virtual network architecture isolates two distinct network environments (`node-alpha` and `node-beta`) within the host kernel, plumbing them into a virtual Layer-2 switch board and bridging them out to the public internet:

```text
+-------------------------------------------------------------------------+

|                              Host Machine                               |
|                                                                         |
| Physical Interface (Ethernet/Wi-Fi) <------------------------> Internet |
|                       ^                                                 |
|                 [NAT / iptables]                                        |
|                       v                                                 |
|                 Bridge: br0 (172.20.0.1/24)                             |
|                  /                       \                              |
|       veth-alpha-br                     veth-beta-br                    |
|             ^                                 ^                         |
|       (Virtual Wire)                    (Virtual Wire)                  |
|             v                                 v                         |
|        veth-alpha                        veth-beta                      |
|   +--------------------+            +--------------------+              |
|   |    Namespace:      |            |    Namespace:      |              |
|   |    node-alpha      |            |    node-beta       |              |
|   |  172.20.0.10/24    |            |  172.20.0.20/24    |              |
|   |  App Port: :8080   |            |                    |              |
|   +--------------------+            +--------------------+              |
+-------------------------------------------------------------------------+
```

---

## 2. Functional Requirements Implementation

### Requirement 1: Namespace Isolation
* **Implementation:** Created two completely isolated network namespaces named `node-alpha` and `node-beta`. 
* **Loopback Activation:** Manually activated the loopback (`lo`) interfaces within both rooms, enabling secure local Inter-Process Communication (IPC) and application binding on `127.0.0.1`.
* **Result:** Both environments maintain entirely separate, clean network socket spaces and independent routing tables.

### Requirement 2: Virtual Bridge & Layer-3 Switching
* **Implementation:** Provisioned a software bridge device (`br0`) assigned to `172.20.0.1/24` to act as the virtual switch board and local default gateway. 
* **Plumbing:** Created dual virtual Ethernet link pairs (`veth` cables). One end of each cable pair was attached to the `br0` host switch, while the opposite ends were injected straight across the namespace borders.
* **Static Addressing:** Assigned static endpoints (`172.20.0.10/24` for alpha and `172.20.0.20/24` for beta) and programmed default routes pointing directly to the bridge gateway.
* **Validation:** Verified that both nodes can instantly clear bidirectional ICMP echo handshakes and establish direct, raw peer-to-peer TCP streaming channels over the switch.

### Requirement 3: Egress Internet Routing (SNAT / Masquerading)
* **Kernel Routing:** Activated the core Linux kernel router switch by setting `net.ipv4.ip_forward = 1`.
* **Outbound NAT:** Applied a stateful **IP Masquerading (SNAT)** rule inside the `POSTROUTING` table targeting the host’s primary internet-facing hardware interface (`enp8s0`).
* **Firewall Adjustments:** Because background software (Docker) defaults the host `FORWARD` gate policy to `DROP`, explicit allow gates were inserted to permit passing traffic originating from `br0` to escape out of the external card.

### Requirement 4: Ingress Port Forwarding (DNAT)
* **Application Layer:** Launched a lightweight Python HTTP daemon inside the isolated room of `node-alpha` listening on `0.0.0.0:8080`.
* **Port Mapping:** Implemented destination address translation rules (**DNAT**) inside the firewall’s `PREROUTING` and local `OUTPUT` chains. This rule catches uninvited queries hitting `<Host-IP>:9090` or `localhost:9090`, rewrites the headers, and tunnels them cleanly down onto the bridge straight into `172.20.0.10:8080`.

### Requirement 5: Isolated DNS Resolution
* **Anti-Information Leakage:** Enforced total filesystem isolation by completely banning host `/etc/resolv.conf` bind-mounting tricks.
* **Network Directories:** Leveraged the native Linux `/etc/netns/` vault structure. Created independent configuration spaces (`/etc/netns/node-alpha/` and `/etc/netns/node-beta/`) housing dedicated, unique upstream nameserver rules.
* **Result:** Namespaces successfully map outward-bound UDP Port 53 packets across the bridge to independent public DNS entities (Google `8.8.8.8` and Cloudflare `1.1.1.1`) with zero host network footprint leaks.

---

## 3. Deep-Dive Packet Flow Walkthrough

### Egress Path: `node-alpha` Pings the Global Internet (`8.8.8.8`)
1. **Birth:** A user inside `node-alpha` runs a ping. The namespace operating system creates an ICMP packet. It checks its local routing table, sees `8.8.8.8` is outside its neighborhood, and fires it down the `veth-alpha` wire targeting the default gateway (`172.20.0.1`).
2. **The Forward Check:** The packet lands on the host's `br0` bridge. The host kernel realizes it is a middleman router for this packet and sends it down the `FORWARD` chain conveyor belt. It moves line-by-line from top to bottom, boomeranging safely out of empty Docker sub-chains until it hits our manual allowance rule: `in=br0 out=enp8s0 ACCEPT`. The gate opens.
3. **The Masking Station:** Before exiting into the wild wires, the packet hits the `POSTROUTING` table. Our `MASQUERADE` rule triggers. The host kernel rips off the internal private source label (`172.20.0.10`) and slaps the host's real physical ethernet IP address on the package envelope.
4. **The Response Trip:** Google receives the packet and replies back to the host's public IP address. When the response lands on the host's card, the connection tracking engine (`ctstate ESTABLISHED,RELATED`) cross-references its short-term RAM memory, recognizes the return packet, automatically rewrites the destination back to `172.20.0.10`, and passes it down the bridge into the node room safely.

### Ingress Path: Host Browser Accesses the Port Forward (`localhost:9090`)
1. **The Interception:** A request hits `localhost:9090`. Because it originates locally, it steps onto the `OUTPUT` NAT chain factory floor. 
2. **The DNAT Rewrite:** Our rule triggers: It intercepts the packet matching destination port 9090, rips off the `localhost` destination tag, and stamps `172.20.0.10:8080` onto the packet header instead.
3. **The Micro-Segmentation Protection:** The packet flows onto the bridge and runs into the container room. If a malicious attacker attempts to exploit port 9090, they find themselves permanently locked inside the isolated prison cell of `node-alpha`. They cannot perform lateral movement because there are no physical or logical routes connecting the alpha namespace to your host files or neighboring enterprise networks. If the container or namespace is deleted, the port instantly returns a hard-coded `Connection refused` error at the kernel level, leaving zero attack surface.

---

## 4. Key Takeaways and Verification Records

* **Sequential Execution:** Verified that `iptables` reads lines exclusively from top to bottom. Order is critical; hidden interface columns (`-v` flag) show how Docker implicitly filters traffic by bridge interface names (`docker0` vs `br0`).
* **Stateful Optimization:** Utilized connection tracking to maximize CPU efficiency. Only the very first packet of a data conversation undergoes heavy security screening; all subsequent `ESTABLISHED` replies slide through the gates instantly.
* **Infrastructure as Code Validation:** Having mapped out the raw namespaces, link descriptors, and network sockets completely by hand provides a deep structural appreciation for the automated declarative cycles executed by modern `docker-compose` engines.
