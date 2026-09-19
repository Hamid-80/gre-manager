#!/usr/bin/env bash
# GRE Manager: create, inspect, and remove explicitly requested GRE tunnels.
#
# This program deliberately does not install packages, call an external IP
# discovery service, change global sysctls, or change firewall policy.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Kept overridable so pure tests can use a temporary unit directory.
SYSTEMD_UNIT_DIR=${SYSTEMD_UNIT_DIR:-/etc/systemd/system}
IP_CMD=''
SYSTEMCTL_CMD=''
MODPROBE_CMD=''

log_error() { printf '%b[Error]%b %s\n' "$RED" "$NC" "$*" >&2; }
log_warn() { printf '%b[Warning]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_ok() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }

is_valid_ip() {
    local value=${1:-} octet
    local o1 o2 o3 o4

    [[ $value =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r o1 o2 o3 o4 <<< "$value"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

is_valid_mask() {
    [[ ${1:-} =~ ^([1-9]|[12][0-9]|3[01])$ ]]
}

# Linux interface names are at most 15 bytes. Restricting names to this set
# also makes their use in a generated systemd unit unambiguous.
is_valid_tunnel_name() {
    [[ ${1:-} =~ ^[[:alnum:]][[:alnum:]_-]{0,14}$ ]]
}

# Set REPLY to an IPv4 address represented as an unsigned 32-bit integer.
ipv4_to_int() {
    local o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<< "${1:-}"
    REPLY=$((10#$o1 * 16777216 + 10#$o2 * 65536 + 10#$o3 * 256 + 10#$o4))
}

# GRE peer addresses are expected to share the configured tunnel subnet.
is_same_subnet() {
    local mask left right network_mask
    mask=${3:-}
    is_valid_mask "$mask" || return 1
    ipv4_to_int "$1"
    left=$REPLY
    ipv4_to_int "$2"
    right=$REPLY
    network_mask=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
    (( (left & network_mask) == (right & network_mask) ))
}

validate_tunnel_values() {
    local local_tun=${1:-} remote_tun=${2:-} mask=${3:-}
    is_valid_ip "$local_tun" || { log_error "Invalid local tunnel IPv4 address: $local_tun"; return 1; }
    is_valid_ip "$remote_tun" || { log_error "Invalid remote tunnel IPv4 address: $remote_tun"; return 1; }
    is_valid_mask "$mask" || { log_error "Mask must be an integer from 1 through 31."; return 1; }
    [[ $local_tun != "$remote_tun" ]] || { log_error "Local and remote tunnel addresses must differ."; return 1; }
    is_same_subnet "$local_tun" "$remote_tun" "$mask" || {
        log_error "Local and remote tunnel addresses must be in the same /$mask subnet.";
        return 1
    }
}

require_root() {
    if [[ $(id -u) -ne 0 ]]; then
        log_error "This operation needs root privileges; run the script with sudo."
        return 1
    fi
}

require_ip_command() {
    if ! command -v ip >/dev/null 2>&1; then
        log_error "Missing required command: ip (from iproute2)"
        return 1
    fi
    IP_CMD=$(command -v ip)
}

require_commands() {
    local command_name missing=()
    require_ip_command || return 1
    for command_name in systemctl modprobe awk mktemp install; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if ((${#missing[@]})); then
        log_error "Missing required command(s): ${missing[*]}"
        log_error "Install the prerequisites using your operating system's package manager, then retry."
        return 1
    fi
    SYSTEMCTL_CMD=$(command -v systemctl)
    MODPROBE_CMD=$(command -v modprobe)
}

unit_path_for() {
    is_valid_tunnel_name "${1:-}" || return 1
    printf '%s/gre-%s.service\n' "$SYSTEMD_UNIT_DIR" "$1"
}

# Render only validated values into a native systemd unit. There is no shell
# interpolation in the resulting ExecStart lines.
render_unit() {
    local tun_name=${1:?} local_pub=${2:?} remote_pub=${3:?}
    local local_tun=${4:?} remote_tun=${5:?} mask=${6:?}
    local ip_cmd=${7:?} modprobe_cmd=${8:?}

    is_valid_tunnel_name "$tun_name" || return 1
    is_valid_ip "$local_pub" || return 1
    is_valid_ip "$remote_pub" || return 1
    validate_tunnel_values "$local_tun" "$remote_tun" "$mask" >/dev/null || return 1
    [[ $ip_cmd == /* && $modprobe_cmd == /* ]] || return 1

    cat <<EOF
[Unit]
Description=GRE Tunnel Manager (${tun_name})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=30
# The service has only the network capabilities and module-loading capability it needs; it has no shell.
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_MODULE
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full

ExecStartPre=${modprobe_cmd} ip_gre
ExecStart=${ip_cmd} link add ${tun_name} type gre local ${local_pub} remote ${remote_pub} ttl 255
ExecStart=${ip_cmd} link set ${tun_name} mtu 1476 txqueuelen 10000 up
ExecStart=${ip_cmd} addr add ${local_tun}/${mask} dev ${tun_name}
ExecStart=${ip_cmd} route add ${remote_tun}/32 dev ${tun_name}

ExecStop=-${ip_cmd} route del ${remote_tun}/32 dev ${tun_name}
ExecStop=-${ip_cmd} link set ${tun_name} down
ExecStop=-${ip_cmd} link del ${tun_name}

[Install]
WantedBy=multi-user.target
EOF
}

write_unit() {
    local unit_path=$1 tmp_path=$2
    shift 2
    if ! render_unit "$@" > "$tmp_path"; then
        rm -f -- "$tmp_path"
        return 1
    fi
    if ! install -m 0644 -- "$tmp_path" "$unit_path"; then
        rm -f -- "$tmp_path"
        return 1
    fi
    rm -f -- "$tmp_path"
}

show_menu() {
    printf '%b=================================================%b\n' "$CYAN" "$NC"
    printf '%b       GRE Tunnel Manager (safer edition)%b\n' "$GREEN" "$NC"
    printf '%b=================================================%b\n' "$CYAN" "$NC"
    printf ' 1) %bCreate a new GRE tunnel%b\n' "$YELLOW" "$NC"
    printf ' 2) %bDelete a managed GRE tunnel%b\n' "$RED" "$NC"
    printf ' 3) %bList GRE tunnel status%b\n' "$BLUE" "$NC"
    printf ' 4) %bRemove all managed tunnels (destructive)%b\n' "$CYAN" "$NC"
    printf ' 5) Exit\n'
    printf '%b=================================================%b\n' "$CYAN" "$NC"
    IFS= read -r -p 'Select an option [1-5]: ' choice
}

create_tunnel() {
    local tun_name remote_pub local_pub local_tun remote_tun mask choice
    local unit_path tmp_path

    require_root || return 1
    require_commands || return 1

    printf '\n%b--- Create New GRE Tunnel ---%b\n' "$GREEN" "$NC"
    IFS= read -r -p 'Tunnel interface name (for example, gre1): ' tun_name
    if ! is_valid_tunnel_name "$tun_name"; then
        log_error 'Tunnel name must start with a letter/number, contain only letters, numbers, _ or -, and be at most 15 characters.'
        return 1
    fi

    unit_path=$(unit_path_for "$tun_name")
    if [[ -e $unit_path ]] || "$IP_CMD" link show "$tun_name" >/dev/null 2>&1; then
        log_error "Tunnel interface or service already exists: $tun_name"
        return 1
    fi

    IFS= read -r -p 'Remote public IPv4 address: ' remote_pub
    is_valid_ip "$remote_pub" || { log_error 'Invalid remote public IPv4 address.'; return 1; }

    IFS= read -r -p 'Local public IPv4 address (Enter to detect from the local route): ' local_pub
    if [[ -z $local_pub ]]; then
        local_pub=$("$IP_CMD" -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit }}')
        if [[ -n $local_pub ]]; then
            printf '%bDetected local address: %s%b\n' "$YELLOW" "$local_pub" "$NC"
        fi
    fi
    is_valid_ip "$local_pub" || { log_error 'A valid local public IPv4 address is required; no external IP lookup is performed.'; return 1; }

    IFS= read -r -p 'Local tunnel IPv4 address (for example, 10.10.1.1): ' local_tun
    IFS= read -r -p 'Remote tunnel IPv4 address (for example, 10.10.1.2): ' remote_tun
    IFS= read -r -p 'Tunnel prefix length (default 30, valid 1-31): ' mask
    mask=${mask:-30}
    validate_tunnel_values "$local_tun" "$remote_tun" "$mask" || return 1

    printf '\nLocal public:  %s\nRemote public: %s\nLocal tunnel:  %s/%s\nRemote tunnel: %s/%s\n' \
        "$local_pub" "$remote_pub" "$local_tun" "$mask" "$remote_tun" "$mask"
    IFS= read -r -p 'Create and enable this systemd service now? [y/N] ' choice
    [[ $choice =~ ^[Yy]$ ]] || { log_warn 'Canceled.'; return 0; }

    # Loading the module is local and scoped to the requested create action.
    if ! "$MODPROBE_CMD" ip_gre; then
        log_error 'Could not load the ip_gre kernel module.'
        return 1
    fi

    tmp_path=$(mktemp "$SYSTEMD_UNIT_DIR/.gre-${tun_name}.XXXXXX") || {
        log_error "Could not create a temporary unit in $SYSTEMD_UNIT_DIR"
        return 1
    }
    if ! (umask 077; write_unit "$unit_path" "$tmp_path" "$tun_name" "$local_pub" "$remote_pub" "$local_tun" "$remote_tun" "$mask" "$IP_CMD" "$MODPROBE_CMD"); then
        rm -f -- "$tmp_path"
        log_error 'Could not write the systemd unit.'
        return 1
    fi

    if ! "$SYSTEMCTL_CMD" daemon-reload || ! "$SYSTEMCTL_CMD" enable "gre-${tun_name}.service" >/dev/null; then
        log_error 'systemd could not install the unit; the unit file was left for inspection.'
        return 1
    fi
    if ! "$SYSTEMCTL_CMD" start "gre-${tun_name}.service"; then
        log_error "The unit did not start. Inspect: journalctl -u gre-${tun_name}.service"
        return 1
    fi

    log_ok "GRE tunnel '$tun_name' is active."
    printf 'The manager did not alter global sysctls or firewall rules.\n'
}

list_service_names() {
    local path base name
    for path in "$SYSTEMD_UNIT_DIR"/gre-*.service; do
        [[ -f $path ]] || continue
        base=${path##*/}
        name=${base#gre-}
        name=${name%.service}
        is_valid_tunnel_name "$name" && printf '%s\n' "$name"
    done
}

stop_and_remove_tunnel() {
    local target_tun=${1:?} unit_path
    unit_path=$(unit_path_for "$target_tun") || return 1

    if ! "$SYSTEMCTL_CMD" stop "gre-${target_tun}.service"; then
        log_error "Could not stop gre-${target_tun}.service; leaving its unit in place."
        return 1
    fi
    "$SYSTEMCTL_CMD" disable "gre-${target_tun}.service" >/dev/null 2>&1 || log_warn "Could not disable gre-${target_tun}.service."
    rm -f -- "$unit_path" || return 1
    # The explicit name prevents a wildcard from touching unrelated links.
    "$IP_CMD" addr flush dev "$target_tun" >/dev/null 2>&1 || true
    "$IP_CMD" link set "$target_tun" down >/dev/null 2>&1 || true
    "$IP_CMD" link del "$target_tun" >/dev/null 2>&1 || true
    return 0
}

delete_tunnel() {
    local services=() name choice_num target_tun confirmation

    require_root || return 1
    require_commands || return 1
    while IFS= read -r name; do services+=("$name"); done < <(list_service_names)
    if ((${#services[@]} == 0)); then
        log_warn 'No managed GRE tunnel services found.'
        return 0
    fi

    printf '\n%b--- Delete GRE Tunnel ---%b\n' "$RED" "$NC"
    local index=1
    for name in "${services[@]}"; do printf ' %d) %s\n' "$index" "$name"; ((index++)); done
    IFS= read -r -p 'Enter a number (0 to cancel): ' choice_num
    [[ $choice_num =~ ^[0-9]+$ ]] || { log_warn 'Canceled.'; return 0; }
    (( choice_num > 0 && choice_num <= ${#services[@]} )) || { log_warn 'Canceled.'; return 0; }
    target_tun=${services[$((choice_num - 1))]}
    IFS= read -r -p "Type '$target_tun' to confirm deletion: " confirmation
    [[ $confirmation == "$target_tun" ]] || { log_warn 'Canceled.'; return 0; }

    if stop_and_remove_tunnel "$target_tun"; then
        "$SYSTEMCTL_CMD" daemon-reload
        log_ok "Tunnel '$target_tun' and its manager unit were removed."
    else
        return 1
    fi
}

list_tunnels() {
    require_commands || return 1
    printf '\n%b--- GRE Interfaces ---%b\n' "$BLUE" "$NC"
    if ! "$IP_CMD" -d link show type gre 2>/dev/null; then
        log_warn 'No GRE interfaces found (or the kernel does not support GRE listing).'
    fi
}

flush_ghost_interfaces() {
    local services=() name confirmation failed=0
    require_root || return 1
    require_commands || return 1
    while IFS= read -r name; do services+=("$name"); done < <(list_service_names)
    if ((${#services[@]} == 0)); then
        log_warn 'No managed GRE tunnel services found.'
        return 0
    fi

    printf '%bThis removes every service named gre-<name>.service in %s and its matching interface.%b\n' "$YELLOW" "$SYSTEMD_UNIT_DIR" "$NC"
    IFS= read -r -p "Type FLUSH to confirm removal of ${#services[@]} tunnel(s): " confirmation
    [[ $confirmation == FLUSH ]] || { log_warn 'Canceled.'; return 0; }
    for name in "${services[@]}"; do
        if ! stop_and_remove_tunnel "$name"; then failed=1; fi
    done
    "$SYSTEMCTL_CMD" daemon-reload
    ((failed == 0)) && log_ok 'All selected managed tunnels were removed.'
    return "$failed"
}

main() {
    local choice
    while :; do
        show_menu || { printf '\n'; return 0; }
        case ${choice:-} in
            1) create_tunnel ;;
            2) delete_tunnel ;;
            3) list_tunnels ;;
            4) flush_ghost_interfaces ;;
            5) printf '%bExiting... Goodbye!%b\n' "$GREEN" "$NC"; return 0 ;;
            *) log_error 'Invalid option.' ;;
        esac
        printf '\n'
        IFS= read -r -p 'Press Enter to return to the menu...' || return 0
        [[ -t 1 ]] && clear
    done
}

# Tests source this file with GRE_MANAGER_TESTING=1 to avoid starting the UI.
if [[ ${GRE_MANAGER_TESTING:-0} != 1 ]]; then
    main "$@"
fi
