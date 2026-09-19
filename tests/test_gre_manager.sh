#!/usr/bin/env bash
# Non-root-friendly tests for validation and unit rendering. No network or
# privileged command is executed.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GRE_MANAGER_TESTING=1 source "$SCRIPT_DIR/../gre_manager.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

for ip in 0.0.0.0 10.10.1.1 192.168.001.254 255.255.255.255; do
    is_valid_ip "$ip" || fail "expected valid IPv4: $ip"
done
pass 'valid IPv4 addresses accepted'

for ip in '' 1.2.3 256.1.1.1 1.2.3.999 1.2.3.-1 '1.2.3.4 extra' '1.2.3.01x'; do
    if is_valid_ip "$ip"; then fail "expected invalid IPv4: $ip"; fi
done
pass 'invalid IPv4 addresses rejected'

for name in gre1 gre_1 GRE-2 a12345678901234; do
    is_valid_tunnel_name "$name" || fail "expected valid interface name: $name"
done
pass 'valid interface names accepted'

for name in '' '-gre1' 'gre.1' 'gre 1' 'gre/1' '1234567890123456'; do
    if is_valid_tunnel_name "$name"; then fail "expected invalid interface name: $name"; fi
done
pass 'unsafe and overlong interface names rejected'

for mask in 1 24 30 31; do
    is_valid_mask "$mask" || fail "expected valid prefix: $mask"
done
for mask in 0 32 33 x ''; do
    if is_valid_mask "$mask"; then fail "expected invalid prefix: $mask"; fi
done
pass 'prefix length boundaries enforced'

validate_tunnel_values 10.10.1.1 10.10.1.2 30 || fail 'same /30 peer addresses should validate'
if validate_tunnel_values 10.10.1.1 10.10.2.2 30; then fail 'different subnets should be rejected'; fi
if validate_tunnel_values 10.10.1.1 10.10.1.1 30; then fail 'identical peer addresses should be rejected'; fi
pass 'GRE peer subnet validation works'

unit=$(render_unit gre1 198.51.100.10 203.0.113.20 10.10.1.1 10.10.1.2 30 /usr/sbin/ip /usr/sbin/modprobe)
grep -Fq 'ExecStart=/usr/sbin/ip link add gre1 type gre local 198.51.100.10 remote 203.0.113.20 ttl 255' <<< "$unit" || fail 'unit did not render the GRE command'
grep -Fq 'ExecStart=/usr/sbin/ip route add 10.10.1.2/32 dev gre1' <<< "$unit" || fail 'unit did not render the peer route'
if grep -Eq 'iptables|sysctl|curl|apt-get' <<< "$unit"; then fail 'unit contains a removed global/firewall action'; fi
if grep -Eq '203\.0\.113\.20.*;|203\.0\.113\.20.*\$\(|10\.10\.1\.1.*;' <<< "$unit"; then fail 'unit appears to contain shell injection syntax'; fi
pass 'systemd unit rendering is scoped and free of removed side effects'

printf 'All GRE Manager tests passed.\n'
