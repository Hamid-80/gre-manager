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

# --- Main Menu ---
show_menu() {
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${GREEN}    Advanced GRE Tunnel Manager (v2.5 Hybrid)     ${NC}"
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
    if [[ -z "$tun_name" ]]; then
        echo -e "${RED}[Error] Tunnel name cannot be empty!${NC}"
        return
    fi

    if [ -f "/etc/systemd/system/gre-${tun_name}.service" ] || ip link show "$tun_name" &>/dev/null; then
        echo -e "${RED}[Error] A tunnel or interface named '${tun_name}' already exists!${NC}"
        echo -e "${YELLOW}[Tip] If it's a ghost interface, run Option 4 from main menu to fix it.${NC}"
        return
    fi

    read -p "Enter Remote Public IP (Server B): " remote_pub
    if [[ -z "$remote_pub" ]]; then
        echo -e "${RED}[Error] Remote Public IP is required!${NC}"
        return
    fi

    read -p "Enter Local Public IP (Press Enter to auto-detect): " local_pub
    if [[ -z "$local_pub" ]]; then
        local_pub=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
        if [[ -z "$local_pub" ]]; then
            local_pub=$(curl -s --max-time 3 ifconfig.me)
        fi
        echo -e "${YELLOW}Auto-detected Local Public IP: ${GREEN}${local_pub}${NC}"
    fi

    read -p "Enter Local Tunnel IP (e.g., 10.10.1.1): " local_tun
    read -p "Enter Remote Tunnel IP (e.g., 10.10.1.2): " remote_tun
    read -p "Enter Subnet Mask (Default: 30): " mask
    mask=${mask:-30}

    if [[ -z "$local_tun" ]] || [[ -z "$remote_tun" ]]; then
        echo -e "${RED}[Error] Both Local and Remote Tunnel IPs are required!${NC}"
        return
    fi

    cat <<EOF > /etc/systemd/system/gre-${tun_name}.service
[Unit]
Description=GRE Tunnel ${tun_name}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "modprobe ip_gre && ip tunnel add ${tun_name} mode gre remote ${remote_pub} local ${local_pub} ttl 255 && ip link set ${tun_name} up && ip addr add ${local_tun}/${mask} dev ${tun_name}"
ExecStop=/bin/bash -c "ip addr flush dev ${tun_name} 2>/dev/null; ip link set ${tun_name} down 2>/dev/null; ip tunnel del ${tun_name} 2>/dev/null; ip link del ${tun_name} 2>/dev/null; true"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gre-${tun_name}.service &>/dev/null
    systemctl start gre-${tun_name}.service

    if [ $? -eq 0 ]; then
        echo -e "\n${GREEN}=================================================${NC}"
        echo -e "${GREEN}[SUCCESS] GRE Tunnel '${tun_name}' created and active!${NC}"
        echo -e " - Local Tunnel IP:       ${YELLOW}${local_tun}/${mask}${NC}"
        echo -e " - Remote Tunnel IP:      ${YELLOW}${remote_tun}/${mask}${NC}"
        echo -e "${GREEN}=================================================${NC}"
    else
        echo -e "${RED}[Error] Failed to start tunnel.${NC}"
        echo -e "${YELLOW}[Fix] Run Option 4 to clear stuck components, then try again with an standard name like gre1.${NC}"
    fi
}

# --- Function: Delete Tunnel ---
delete_tunnel() {
    echo -e "\n${RED}--- Delete GRE Tunnel ---${NC}"
    mapfile -t services < <(ls /etc/systemd/system/gre-*.service 2>/dev/null)
    
    if [ ${#services[@]} -eq 0 ]; then
        echo -e "${YELLOW}No active GRE tunnel services found on this system.${NC}"
        return
    fi

    echo -e "${CYAN}Available Tunnels to Delete:${NC}"
    local tun_list=()
    local i=1
    for svc in "${services[@]}"; do
        name=$(basename "$svc" | sed 's/gre-\(.*\)\.service/\1/')
        tun_list+=("$name")
        echo -e " ${YELLOW}$i)${NC} $name"
        ((i++))
    done

    echo ""
    read -p "Enter the number of the tunnel to delete (or 0 to cancel): " choice_num

    if ! [[ "$choice_num" =~ ^[0-9]+$ ]] || [ "$choice_num" -eq 0 ]; then
        echo -e "${YELLOW}Operation canceled.${NC}"
        return
    fi

    local idx=$((choice_num - 1))
    local target_tun="${tun_list[$idx]}"

    if [[ -z "$target_tun" ]]; then
        echo -e "${RED}[Error] Invalid selection!${NC}"
        return
    fi

    echo -e "\n${YELLOW}Stopping and removing tunnel '${target_tun}'...${NC}"
    systemctl stop "gre-${target_tun}.service" 2>/dev/null
    systemctl disable "gre-${target_tun}.service" 2>/dev/null
    rm -f "/etc/systemd/system/gre-${target_tun}.service"
    systemctl daemon-reload
    
    ip addr flush dev "$target_tun" 2>/dev/null
    ip link set "$target_tun" down 2>/dev/null
    ip tunnel del "$target_tun" 2>/dev/null
    ip link del "$target_tun" 2>/dev/null

    echo -e "${GREEN}[SUCCESS] Tunnel '${target_tun}' has been completely wiped!${NC}"
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

# --- Function: Flush & Fix Networking (NEW - NO REBOOT SOLUTION) ---
flush_ghost_interfaces() {
    echo -e "\n${CYAN}--- Launching Deep Network Flush & Repair ---${NC}"
    echo -e "${YELLOW}[1/4] Scanning and stopping all broken GRE systemd services...${NC}"
    
    # Force stop and remove any failed/active gre services
    for svc in /etc/systemd/system/gre-*.service; do
        if [ -f "$svc" ]; then
            systemctl stop "$(basename "$svc")" 2>/dev/null
            systemctl disable "$(basename "$svc")" 2>/dev/null
            rm -f "$svc"
        fi
    done
    systemctl daemon-reload

    echo -e "${YELLOW}[2/4] Wiping all GRE interfaces from Kernel space...${NC}"
    # Fetch all GRE interfaces including ghost ones and destroy them
    for tun in $(ip tunnel show | awk -F: '{print $1}' | grep -v "sit0\|ip6tnl0\|tunl0"); do
        ip addr flush dev "$tun" 2>/dev/null
        ip link set "$tun" down 2>/dev/null
        ip tunnel del "$tun" 2>/dev/null
        ip link del "$tun" 2>/dev/null
    done
    
    # Extra check for any lingering single-letter interfaces that broke before
    for letter in h H gre1 gre2 gre3; do
        ip link set "$letter" down 2>/dev/null
        ip tunnel del "$letter" 2>/dev/null
        ip link del "$letter" 2>/dev/null
    done

    echo -e "${YELLOW}[3/4] Resetting IP Netns and cleaning routing cache...${NC}"
    ip route flush cache

    echo -e "${YELLOW}[4/4] Reloading ip_gre Kernel Module...${NC}"
    modprobe -r ip_gre 2>/dev/null
    modprobe ip_gre 2>/dev/null

    echo -e "${GREEN}[SUCCESS] All ghost connections flushed! System is fixed WITHOUT rebooting.${NC}"
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
        *) echo -e "${RED}[Error] Invalid option! Please select between 1 and 5.${NC}" ;;
    esac
    echo ""
    read -p "Press Enter to return to menu..." temp
    clear
done
