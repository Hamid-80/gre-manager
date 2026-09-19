# Changelog

## Unreleased — safer maintenance release

- Removed automatic package installation and external IP discovery.
- Removed automatic global sysctl tuning, iptables edits, route-cache flushing, and cleanup-time module reload.
- Added strict IPv4, interface-name, prefix, and tunnel-subnet validation.
- Rendered systemd units atomically with absolute paths, explicit peer-route ownership, and reduced capabilities.
- Added confirmations for create, delete, and all-tunnel cleanup.
- Added non-privileged validation and unit-rendering tests.
- Added English/Persian documentation and explicit notes that GRE end-to-end integration is untested.

No license or additional compatibility guarantee is introduced by this changelog.
