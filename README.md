# GRE Manager

A small interactive Bash utility for creating, inspecting, and removing Linux GRE tunnels through explicitly confirmed systemd services.

- **English:** this section.
- **فارسی:** [راهنمای فارسی](#راهنمای-فارسی)

> **Status:** local validation and unit-rendering tests pass. A real GRE end-to-end connection needs two reachable, separately configured servers and is **not tested by this repository**.

## Safety first

This version intentionally avoids surprising host-wide changes:

- It does **not** install packages or call a package manager.
- It does **not** query an external “what is my IP” service. Blank local-public-IP input is detected only from the local route; otherwise you must enter the address.
- It does **not** change global `sysctl` settings (including forwarding, buffers, qdisc, or BBR).
- It does **not** add, delete, or flush firewall rules. Permit GRE protocol 47 in your existing firewall policy only if your deployment requires it.
- It does **not** flush a global route cache or unload/reload the GRE kernel module during cleanup.
- Creating a tunnel asks for confirmation, and deleting one requires typing its name. The “remove all” action requires typing `FLUSH`.
- Generated units use validated values, absolute command paths, and a restricted systemd capability set. The service owns its named interface and the explicit `/32` peer route.

The script still performs privileged network operations when you confirm them: loading `ip_gre`, creating/removing a named link, assigning its address, and adding/removing the peer route. Read the generated unit before enabling it on a production host.

## Requirements

- Bash 4 or newer
- `ip` from iproute2
- systemd (`systemctl`)
- `modprobe` from kmod
- `awk`, `mktemp`, and `install`
- Root privileges for create, delete, and cleanup; status listing also works as a normal user when `ip` is available

No license is declared by this repository. No additional compatibility claim is made beyond the requirements above; the local review used Bash syntax checks and non-root-friendly pure validation tests.

## Use

Review the script, then run it locally (avoid piping unreviewed code from the Internet):

```bash
chmod +x gre_manager.sh
sudo ./gre_manager.sh
```

The create flow asks for:

1. A Linux interface name (letters/numbers, `_` or `-`, maximum 15 characters).
2. Remote and local public IPv4 addresses.
3. Local and remote tunnel IPv4 addresses in the same `/1`–`/31` subnet (default `/30`).

The generated service is `gre-<interface>.service` under `/etc/systemd/system/`. The unit creates the GRE interface, sets MTU 1476 and queue length 10000 to retain the original defaults, assigns the local address, and installs a route to the requested remote tunnel address. It does not enable forwarding: enable forwarding separately only when this host is intentionally routing traffic between networks, for example with a reviewed `/etc/sysctl.d/` configuration.

### Firewall and forwarding migration

Earlier releases automatically inserted an iptables GRE rule and changed global buffer/BBR settings and `net.ipv4.ip_forward`. Those actions have been removed. Existing units created by an earlier release are not rewritten automatically; inspect and replace them deliberately. Configure firewall and forwarding policy outside this utility, according to your distribution and whether this host is an endpoint or a router.

## Tests

The test harness never invokes `ip`, `systemctl`, `modprobe`, or any privileged operation:

```bash
bash -n gre_manager.sh
bash tests/test_gre_manager.sh
```

It checks IPv4 and interface-name validation, prefix/subnet rules, and generated-unit content. ShellCheck is recommended when available:

```bash
shellcheck gre_manager.sh tests/test_gre_manager.sh
```

The repository does not claim GRE interoperability or remote-server integration testing. Do not run the tunnel-management actions in automated tests without isolated network namespaces and a deliberate test plan.

## Changelog

### Unreleased — safer maintenance release

- Replaced automatic package installation and external IP lookup with prerequisite errors and local-route detection.
- Removed automatic global sysctl tuning, automatic iptables changes, route-cache flushing, and module reload during cleanup.
- Added strict validation for IPv4 values, tunnel names, prefix lengths, and same-subnet peer addresses.
- Generated units atomically with absolute paths and a restricted systemd capability set; added explicit peer-route ownership and cleanup.
- Added confirmation prompts for create, delete, and destructive cleanup.
- Added non-privileged validation/unit-rendering tests and bilingual documentation.

## راهنمای فارسی

### معرفی

این ابزار کوچک Bash برای ساخت، مشاهده و حذف تونل GRE لینوکس از طریق سرویس‌های systemd است. عملیات ایجاد، حذف و پاک‌سازی به دسترسی root نیاز دارد و قبل از تغییر شبکه تأیید صریح می‌گیرد.

> **وضعیت آزمون:** آزمون‌های اعتبارسنجی محلی و تولید متن واحد systemd موفق هستند. اتصال واقعی GRE به دو سرور جداگانه و قابل‌دسترسی نیاز دارد و در این مخزن آزمایش نشده است.

### نکات ایمنی

- بسته‌ای نصب نمی‌شود و `apt` یا مدیر بسته اجرا نمی‌شود.
- برای تشخیص IP عمومی به سرویس خارجی متصل نمی‌شود؛ با خالی گذاشتن IP محلی فقط از مسیر محلی استفاده می‌شود.
- تنظیمات سراسری `sysctl`، از جمله forwarding، بافرها، qdisc و BBR تغییر نمی‌کند.
- قانون فایروال ساخته، حذف یا flush نمی‌شود. در صورت نیاز، اجازه پروتکل GRE (شماره ۴۷) را جداگانه و مطابق سیاست فایروال خود تنظیم کنید.
- هنگام پاک‌سازی route cache سراسری flush نمی‌شود و ماژول GRE unload/reload نمی‌گردد.
- ساخت تونل با تأیید انجام می‌شود؛ برای حذف باید نام تونل تایپ شود و برای حذف همه باید کلمه `FLUSH` وارد شود.

با این حال، پس از تأیید شما عملیات privileged مانند بارگذاری `ip_gre`، ساخت/حذف interface، تنظیم IP و جایگزینی/حذف route مربوط به peer انجام می‌شود. واحد تولیدشده را قبل از فعال‌سازی در محیط production بررسی کنید.

### نیازمندی‌ها و اجرا

نیازمندی‌ها شامل Bash نسخه ۴ یا جدیدتر، `ip` از iproute2، systemd/systemctl، `modprobe` از kmod و ابزارهای `awk`، `mktemp` و `install` است. این پروژه هیچ مجوزی اعلام نمی‌کند و ادعای سازگاری بیشتری از این نیازمندی‌ها ندارد.

```bash
chmod +x gre_manager.sh
sudo ./gre_manager.sh
```

آدرس‌های tunnel محلی و دور باید در یک subnet با prefix بین `/1` تا `/31` باشند (پیش‌فرض `/30`). سرویس ساخته‌شده `gre-<interface>.service` است، MTU برابر ۱۴۷۶ و queue برابر ۱۰۰۰۰ را مانند نسخه قبلی حفظ می‌کند و route صریح `/32` برای آدرس tunnel دور ایجاد می‌کند. forwarding به‌صورت خودکار فعال نمی‌شود؛ فقط در صورت نیاز و پس از بررسی، آن را خارج از این ابزار تنظیم کنید.

### تغییر از نسخه‌های قبل

نسخه‌های قبلی قانون iptables را خودکار اضافه می‌کردند و sysctlهای سراسری، forwarding و تنظیمات BBR را تغییر می‌دادند. این رفتارها حذف شده‌اند. سرویس‌های قدیمی خودکار بازنویسی نمی‌شوند؛ آن‌ها را بررسی و در صورت نیاز آگاهانه جایگزین کنید. آزمون end-to-end GRE در این پروژه انجام نشده است.
