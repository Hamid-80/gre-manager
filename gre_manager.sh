#!/bin/bash

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Check Root Privileges ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[Error] This script must be run as root (use sudo).${NC}"
  exit 1
fi

# --- Dependency Check ---
for pkg in ip curl iptables modprobe sysctl; do
    if ! command -v $pkg &> /dev/null; then
        echo -e "${YELLOW}[Warning] Command '$pkg' not found. Trying to install prerequisites...${NC}"
        apt-get update -yqq && apt-get install -yqq iproute2 curl iptables kmod procps
        break
    fi
done

# --- Helper Function: IP Validator ---
is_valid_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS; IFS='.'; ip_array=($ip); IFS=$OIFS
        [[ ${ip_array[0]} -le 255 && ${ip_array[1]} -le 255 && ${ip_array[2]} -le 255 && ${ip_array[3]} -le 255 ]]
        return $?
    else
        return 1
    fi
}

# --- Apply Global Kernel Optimizations ---
apply_kernel_tweaks() {
    # Network buffers for high throughput UDP/GRE
    sysctl -w net.core.rmem_max=25000000 &>/dev/null
    sysctl -w net.core.wmem_max=25000000 &>/dev/null
    sysctl -w net.core.rmem_default=25000000 &>/dev/null
    sysctl -w net.core.wmem_default=25000000 &>/dev/null
    
    # Enable BBR congestion control for better tunnel speed
    sysctl -w net.core.default_qdisc=fq &>/dev/null
    sysctl -w net.ipv4.tcp_congestion_control=bbr &>/dev/null
}

# --- Main Menu ---
show_menu() {
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${GREEN}    Advanced GRE Tunnel Manager (v5.0 Debian 12/13)  ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo -e " 1) ${YELLOW}Create a New GRE Tunnel${NC}"
    echo -e " 2) ${RED}Delete an Existing GRE Tunnel${NC}"
    echo -e " 3) ${BLUE}List & Check Tunnel Status${NC}"
    echo -e " 4) ${CYAN}Flush & Fix Networking (No Reboot Needed)${NC}"
    echo -e " 5) Exit"
    echo -e "${CYAN}=================================================${NC}"
    read -p "Please select an option [1-5]: " choice
}

# --- Function: Create Tunnel ---
create_tunnel() {
    echo -e "\n${GREEN}--- Create New GRE Tunnel ---${NC}"
    read -p "Enter Tunnel Interface Name (e.g., gre1): " tun_name
    
    # Validate tunnel name (alphanumeric only)
    if [[ ! "$tun_name" =~ ^[a-zA-Z0-9]+$ ]]; then
        echo -e "${RED}[Error] Tunnel name must be alphanumeric without spaces!${NC}"
        return
    fi

    if [ -f "/etc/systemd/system/gre-${tun_name}.service" ] || ip link show "$tun_name" &>/dev/null; then
        echo -e "${RED}[Error] Interface '${tun_name}' already exists! Run Option 4 to clean up.${NC}"
        return
    fi

    read -p "Enter Remote Public IP (Server B): " remote_pub
    if ! is_valid_ip "$remote_pub"; then
        echo -e "${RED}[Error] Invalid IP address format!${NC}"
        return
    fi

    read -p "Enter Local Public IP (Press Enter to auto-detect): " local_pub
    if [[ -z "$local_pub" ]]; then
        # More robust extraction using awk
        local_pub=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
        if [[ -z "$local_pub" ]]; then
            local_pub=$(curl -s --max-time 3 api.ipify.org)
        fi
        echo -e "${YELLOW}Auto-detected Local Public IP: ${GREEN}${local_pub}${NC}"
    fi

    read -p "Enter Local Tunnel IP (e.g., 10.10.1.1): " local_tun
    read -p "Enter Remote Tunnel IP (e.g., 10.10.1.2): " remote_tun
    if ! is_valid_ip "$local_tun" || ! is_valid_ip "$remote_tun"; then
        echo -e "${RED}[Error] Invalid Tunnel IP format!${NC}"
        return
    fi

    read -p "Enter Subnet Mask (Default: 30): " mask
    mask=${mask:-30}

    # Apply global kernel tweaks before starting
    apply_kernel_tweaks

    # Determine absolute paths for systemd requirements
    CMD_IP=$(command -v ip)
    CMD_IPT=$(command -v iptables)
    CMD_SYSCTL=$(command -v sysctl)
    CMD_MOD=$(command -v modprobe)

    # Generate multi-line native Systemd file
    cat <<EOF > /etc/systemd/system/gre-${tun_name}.service
[Unit]
Description=Robust GRE Tunnel ${tun_name}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

# Pre-start: Load module and open firewall
ExecStartPre=-${CMD_MOD} ip_gre
ExecStartPre=-${CMD_IPT} -I INPUT -p gre -s ${remote_pub} -j ACCEPT

# Start: Build tunnel (Modern iproute2 syntax)
ExecStart=${CMD_IP} link add ${tun_name} type gre local ${local_pub} remote ${remote_pub} ttl 255
ExecStart=${CMD_IP} link set ${tun_name} mtu 1476 txqueuelen 10000 up
ExecStart=${CMD_IP} addr add ${local_tun}/${mask} dev ${tun_name}
ExecStart=${CMD_SYSCTL} -w net.ipv4.ip_forward=1
ExecStart=${CMD_SYSCTL} -w net.ipv4.conf.${tun_name}.rp_filter=0

# Stop: Tear down tunnel
ExecStop=-${CMD_IP} link set ${tun_name} down
ExecStop=-${CMD_IP} link del ${tun_name}
ExecStopPost=-${CMD_IPT} -D INPUT -p gre -s ${remote_pub} -j ACCEPT

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gre-${tun_name}.service &>/dev/null
    systemctl start gre-${tun_name}.service

    if systemctl is-active --quiet gre-${tun_name}.service; then
        echo -e "\n${GREEN}=================================================${NC}"
        echo -e "${GREEN}[SUCCESS] GRE Tunnel '${tun_name}' created and fully active!${NC}"
        echo -e " - Local Tunnel IP:       ${YELLOW}${local_tun}/${mask}${NC}"
        echo -e " - Remote Tunnel IP:      ${YELLOW}${remote_tun}/${mask}${NC}"
        echo -e " - Security:              ${CYAN}Iptables rule auto-added for GRE (Protocol 47)${NC}"
        echo -e " - Optimizations:         ${CYAN}MTU 1476, TX-Queue 10k, BBR, Expanded Buffers${NC}"
        echo -e "${GREEN}=================================================${NC}"
    else
        echo -e "${RED}[Error] Failed to start tunnel. Check logs with: journalctl -u gre-${tun_name}.service${NC}"
    fi
}

# --- Function: Delete Tunnel ---
delete_tunnel() {
    echo -e "\n${RED}--- Delete GRE Tunnel ---${NC}"
    mapfile -t services < <(ls /etc/systemd/system/gre-*.service 2>/dev/null)
    
    if [ ${#services[@]} -eq 0 ]; then
        echo -e "${YELLOW}No active GRE tunnel services found.${NC}"
        return
    fi

    echo -e "${CYAN}Available Tunnels:${NC}"
    local tun_list=()
    local i=1
    for svc in "${services[@]}"; do
        name=$(basename "$svc" | sed 's/gre-\(.*\)\.service/\1/')
        tun_list+=("$name")
        echo -e " ${YELLOW}$i)${NC} $name"
        ((i++))
    done

    echo ""
    read -p "Enter number to delete (or 0 to cancel): " choice_num

    if ! [[ "$choice_num" =~ ^[0-9]+$ ]] || [ "$choice_num" -eq 0 ] || [ "$choice_num" -gt "${#tun_list[@]}" ]; then
        echo -e "${YELLOW}Canceled.${NC}"
        return
    fi

    local idx=$((choice_num - 1))
    local target_tun="${tun_list[$idx]}"

    echo -e "\n${YELLOW}Destroying tunnel '${target_tun}'...${NC}"
    
    # Properly stop via systemd first
    systemctl stop "gre-${target_tun}.service" 2>/dev/null
    systemctl disable "gre-${target_tun}.service" 2>/dev/null
    rm -f "/etc/systemd/system/gre-${target_tun}.service"
    systemctl daemon-reload

    # Fail-safe manual cleanup
    ip addr flush dev "$target_tun" 2>/dev/null
    ip link set "$target_tun" down 2>/dev/null
    ip link del "$target_tun" 2>/dev/null

    echo -e "${GREEN}[SUCCESS] Tunnel '${target_tun}' and its firewall rules completely wiped!${NC}"
}

# --- Function: List Tunnels ---
list_tunnels() {
    echo -e "\n${BLUE}--- Active GRE Interfaces & IPs ---${NC}"
    local count=$(ip -d link show type gre 2>/dev/null | grep -c "gre")
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}No GRE interfaces currently active in kernel.${NC}"
    else
        ip -br addr show | grep -iE "gre|tun" | while read -r line; do
            echo -e "${GREEN}►${NC} $line"
        done
    fi
}

# --- Function: Flush & Fix Networking ---
flush_ghost_interfaces() {
    echo -e "\n${CYAN}--- Launching Deep Network Flush & Repair ---${NC}"
    echo -e "${YELLOW}[1/4] Stopping all broken GRE systemd services & firewall rules...${NC}"
    
    for svc in /etc/systemd/system/gre-*.service; do
        if [ -f "$svc" ]; then
            systemctl stop "$(basename "$svc")" 2>/dev/null
            systemctl disable "$(basename "$svc")" 2>/dev/null
            rm -f "$svc"
        fi
    done
    systemctl daemon-reload

    echo -e "${YELLOW}[2/4] Wiping all GRE interfaces from Kernel space...${NC}"
    # Modern approach to list and delete GRE links
    for tun in $(ip -o link show type gre | awk -F': ' '{print $2}' | grep -v "gre0"); do
        ip addr flush dev "$tun" 2>/dev/null
        ip link set "$tun" down 2>/dev/null
        ip link del "$tun" 2>/dev/null
    done
    
    # Fallback for old manual links
    for letter in h H gre1 gre2 gre3; do
        ip link set "$letter" down 2>/dev/null
        ip link del "$letter" 2>/dev/null
    done

    echo -e "${YELLOW}[3/4] Resetting IP Netns and routing cache...${NC}"
    ip route flush cache

    echo -e "${YELLOW}[4/4] Reloading ip_gre Kernel Module...${NC}"
    modprobe -r ip_gre 2>/dev/null
    modprobe ip_gre 2>/dev/null

    echo -e "${GREEN}[SUCCESS] System is cleanly reset without rebooting.${NC}"
}

# --- Main Application Loop ---
while true; do
    show_menu
    case $choice in
        1) create_tunnel ;;
        2) delete_tunnel ;;
        3) list_tunnels ;;
        4) flush_ghost_interfaces ;;
        5) echo -e "${GREEN}Exiting... Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${RED}[Error] Invalid option!${NC}" ;;
    esac
    echo ""
    read -p "Press Enter to return to menu..." temp
    clear
done
