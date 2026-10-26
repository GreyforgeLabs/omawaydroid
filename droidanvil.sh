#!/usr/bin/env bash
# droidanvil: Waydroid that just works on Omarchy and Arch Linux.
#
#   droidanvil.sh install [--android 13|16|17] [--vanilla]   set up Waydroid end to end
#   droidanvil.sh doctor                                      read-only health check
#   droidanvil.sh uninstall [--purge]                         undo what install did
#
# Runs as your normal user and asks sudo for the root steps.
set -euo pipefail

VERSION=0.1.0
TAG=droidanvil
ATV=https://waydroid-atv.github.io/ota
SF_MIRRORS=(autoselect freefr netactuate pilotfiber phoenixnap netix)

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B= G= Y= R= N=; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %sok%s   %s\n' "$G" "$N" "$*"; }
warn() { printf '  %swarn%s %s\n' "$Y" "$N" "$*"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  %sfail%s %s\n' "$R" "$N" "$*"; FAILURES=$((FAILURES + 1)); }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
WARNINGS=0 FAILURES=0
WORK_DIR=
trap '[[ -n $WORK_DIR ]] && rm -rf "$WORK_DIR"' EXIT

usage() {
    cat <<'EOF'
droidanvil: Waydroid that just works on Omarchy and Arch Linux.

  droidanvil.sh install [--android 13|16|17] [--vanilla]   set up Waydroid end to end
  droidanvil.sh doctor                                      read-only health check
  droidanvil.sh uninstall [--purge]                         undo what install did
EOF
}

# --- host facts -----------------------------------------------------------------------

kconfig() { zcat /proc/config.gz 2>/dev/null | grep -E "^$1=" | cut -d= -f2 | tr -d '"' || true; }

# builtin | module | dkms | none
binder_kind() {
    if [[ $(kconfig CONFIG_ANDROID_BINDER_IPC_RUST) == y || $(kconfig CONFIG_ANDROID_BINDER_IPC) == y ]]; then
        echo builtin
    elif [[ $(kconfig CONFIG_ANDROID_BINDER_IPC) == m ]]; then
        echo module
    elif dkms_leftovers | grep -q .; then
        echo dkms
    elif [[ ! -r /proc/config.gz ]] && grep -qw binder /proc/filesystems; then
        echo builtin
    else
        echo none
    fi
}

# Anything that would load the out-of-tree binder_linux module.
dkms_leftovers() {
    pacman -Q binder_linux-dkms anbox-modules-dkms 2>/dev/null | awk '{print "package " $1}' || true
    compgen -G "/usr/lib/modules/*/updates/dkms/binder_linux.ko*" | sed 's/^/module /' || true
    grep -ls '^[[:space:]]*binder_linux' /etc/modules-load.d/*.conf 2>/dev/null | sed 's/^/autoload /' || true
}

# True when ufw already lets Waydroid's bridge do DHCP and forward traffic, whoever added the rules.
ufw_allows_waydroid() {
    local st
    st=$(sudo ufw status)
    grep -qE '^67/udp on waydroid0 +ALLOW' <<< "$st" &&
        grep -qE '^Anywhere +ALLOW FWD +Anywhere on waydroid0' <<< "$st" &&
        grep -qE '^Anywhere on waydroid0 +ALLOW FWD' <<< "$st"
}

ufw_active() { [[ -r /etc/ufw/ufw.conf ]] && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf && systemctl is-active -q ufw; }
firewalld_active() { systemctl is-active -q firewalld 2>/dev/null; }

# --- checks ---------------------------------------------------------------------------

check_host() {
    say "Checking this machine"
    command -v pacman > /dev/null || die "droidanvil supports Arch-based systems (Omarchy, Arch, EndeavourOS, CachyOS) for now"
    [[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported for now"

    if [[ -n ${WAYLAND_DISPLAY:-} ]]; then ok "Wayland session ($WAYLAND_DISPLAY)"
    else bad "no Wayland session: Waydroid needs one (from X11, run it inside 'cage' or 'weston')"; fi

    case $(binder_kind) in
        builtin) ok "kernel $(uname -r) has binder built in" ;;
        module)  ok "kernel $(uname -r) ships binder as a module" ;;
        dkms)    warn "binder comes from a DKMS module; it can break on kernel updates (Omarchy 7.2.8-9+ and Arch linux/zen/lts include binder)" ;;
        none)    bad "kernel $(uname -r) has no binder driver: update (Omarchy: omarchy-update) or install linux-zen, then reboot" ;;
    esac

    local leftovers
    leftovers=$(dkms_leftovers)
    if [[ $(binder_kind) == builtin && -n $leftovers ]]; then
        bad "a leftover binder DKMS module collides with the built-in driver (EBUSY at boot, random freezes; omarchy#16625):"
        sed 's/^/         /' <<< "$leftovers"
        echo "         fix: sudo pacman -Rns binder_linux-dkms   (and remove binder_linux from /etc/modules-load.d), then reboot"
    fi

    local avail_kb free_kb
    avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    (( avail_kb > 2 * 1024 * 1024 )) && ok "$((avail_kb / 1024)) MB memory available" || warn "only $((avail_kb / 1024)) MB memory available; Android needs about 2 GB"
    free_kb=$(df -Pk /var/lib | awk 'NR == 2 {print $4}')
    (( free_kb > 8 * 1024 * 1024 )) && ok "$((free_kb / 1024 / 1024)) GB free for images" || warn "only $((free_kb / 1024 / 1024)) GB free under /var/lib; images need about 6 GB"
}

check_firewall() {
    if ufw_active; then
        if ufw_allows_waydroid; then ok "ufw allows Waydroid's network"
        else warn "ufw is active and will block Waydroid's DHCP/DNS/forwarding (Android gets no IP); install adds the rules"; fi
    elif firewalld_active; then
        if sudo firewall-cmd --zone=trusted --query-interface=waydroid0 > /dev/null 2>&1; then ok "firewalld trusts waydroid0"
        else warn "firewalld is active; Waydroid's bridge must be in the trusted zone; install adds it"; fi
    else
        ok "no ufw/firewalld"
    fi
}

check_waydroid() {
    if ! pacman -Q waydroid > /dev/null 2>&1; then echo "  --   Waydroid not installed"; return; fi
    ok "$(pacman -Q waydroid)"
    python3 -I -c 'import gbinder' 2> /dev/null && ok "python-gbinder imports" \
        || bad "python-gbinder is broken (usually after a Python upgrade): sudo pacman -Syu python-gbinder"
    if [[ -r /var/lib/waydroid/waydroid.cfg ]]; then
        local sys ven
        sys=$(awk -F' = ' '$1 == "system_datetime" {print $2}' /var/lib/waydroid/waydroid.cfg)
        ven=$(awk -F' = ' '$1 == "vendor_datetime" {print $2}' /var/lib/waydroid/waydroid.cfg)
        ok "initialized; images built $(date -d "@$sys" +%F 2>/dev/null || echo ?) (system), $(date -d "@$ven" +%F 2>/dev/null || echo ?) (vendor)"
    else
        echo "  --   not initialized yet"
    fi
    systemctl is-active -q waydroid-container && ok "waydroid-container is running" || echo "  --   waydroid-container is stopped"
}

# --- install steps --------------------------------------------------------------------

open_firewall() {
    if ufw_active; then
        ufw_allows_waydroid && { ok "ufw already allows Waydroid's network"; return; }
        sudo ufw allow in on waydroid0 to any port 67 proto udp comment "$TAG" > /dev/null
        sudo ufw allow in on waydroid0 to any port 53 comment "$TAG" > /dev/null
        sudo ufw route allow in on waydroid0 comment "$TAG" > /dev/null
        sudo ufw route allow out on waydroid0 comment "$TAG" > /dev/null
        ok "ufw: allowed DHCP, DNS and forwarding on waydroid0 only"
    elif firewalld_active; then
        sudo firewall-cmd --permanent --zone=trusted --add-interface=waydroid0 > /dev/null
        sudo firewall-cmd --reload > /dev/null
        ok "firewalld: waydroid0 added to the trusted zone"
    fi
}

close_firewall() {
    if ufw_active; then
        local n
        # Delete from the highest number down so the remaining numbers stay valid.
        for n in $(sudo ufw status numbered | grep "# $TAG" | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn); do
            sudo ufw --force delete "$n" > /dev/null
        done
        ok "ufw: removed droidanvil rules"
    elif firewalld_active; then
        sudo firewall-cmd --permanent --zone=trusted --remove-interface=waydroid0 > /dev/null 2>&1 || true
        sudo firewall-cmd --reload > /dev/null
        ok "firewalld: removed waydroid0 from the trusted zone"
    fi
}

# Download one image zip from the fastest working SourceForge mirror and check its hash.
fetch() {  # url sha256 dest
    local url=$1 sum=$2 dest=$3 direct mirror
    direct=$(sed -E 's#^https://sourceforge\.net/projects/([^/]+)/files/(.*)/download$#https://downloads.sourceforge.net/project/\1/\2#' <<< "$url")
    if [[ -f $dest ]] && sha256sum "$dest" | grep -q "^$sum "; then return 0; fi
    for mirror in "${SF_MIRRORS[@]}"; do
        local src=$direct
        [[ $direct != "$url" ]] && src="$direct?use_mirror=$mirror"
        # Give up on a mirror that stays under 1 MB/s for 20 s; resume the partial file on the next one.
        if curl -fL --progress-bar -C - --speed-limit 1000000 --speed-time 20 -o "$dest" "$src"; then
            sha256sum "$dest" | grep -q "^$sum " && return 0
            rm -f "$dest"
        fi
        [[ $direct == "$url" ]] && break
    done
    die "could not download $(basename "$dest") with a matching checksum"
}

# Waydroid's own downloader cannot pick a mirror, so build a local copy of the OTA channel whose
# entries point at verified files on disk, let `waydroid init` consume it, then point the config
# back at the real channel so `waydroid upgrade` keeps working.
init_images() {  # system_channel vendor_channel system_type
    local sys_ch=$1 ven_ch=$2 type=$3 work
    work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/droidanvil.XXXXXX")
    WORK_DIR=$work
    local sys_json=lineage/waydroid_x86_64/$type.json ven_json=waydroid_x86_64/MAINLINE.json
    mkdir -p "$work/system/lineage/waydroid_x86_64" "$work/vendor/waydroid_x86_64"
    local part ch rel
    for part in system vendor; do
        [[ $part == system ]] && { ch=$sys_ch; rel=$sys_json; } || { ch=$ven_ch; rel=$ven_json; }
        curl -fsSL "$ch/$rel" -o "$work/$part.upstream.json" || die "cannot read the $part channel $ch/$rel"
        read -r url sum name < <(python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))["response"][0]
print(r["url"], r["id"], r["filename"])' "$work/$part.upstream.json")
        say "Downloading $name"
        fetch "$url" "$sum" "$work/$name"
        python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["response"] = d["response"][:1]
d["response"][0]["url"] = "file://" + sys.argv[2]
json.dump(d, open(sys.argv[3], "w"))' "$work/$part.upstream.json" "$work/$name" "$work/$part/$rel"
    done
    say "Initializing Waydroid"
    sudo waydroid init -f -c "file://$work/system" -v "file://$work/vendor" -r lineage -s "$type"
    sudo sed -i -e "s#^system_ota = .*#system_ota = $sys_ch/$sys_json#" \
                -e "s#^vendor_ota = .*#vendor_ota = $ven_ch/$ven_json#" /var/lib/waydroid/waydroid.cfg
    ok "updates will come from $sys_ch"
    rm -rf "$work"
}

cmd_install() {
    local android=13 type=GAPPS
    while (( $# )); do
        case $1 in
            --android) android=${2:?}; shift ;;
            --vanilla) type=VANILLA ;;
            *) die "unknown option $1" ;;
        esac
        shift
    done
    check_host
    (( FAILURES == 0 )) || die "fix the problems above, then run install again"

    say "Installing Waydroid"
    sudo pacman -S --needed --noconfirm waydroid
    open_firewall

    case $android in
        13) init_images https://ota.waydro.id/system https://ota.waydro.id/vendor "$type" ;;
        16|17)
            warn "Android $android images are community builds by WayDroid-ATV (https://github.com/WayDroid-ATV/waydroid-builds), not official Waydroid"
            local ch=a16-qpr2
            [[ $android == 17 ]] && ch=a17-qpr0
            init_images "$ATV/$ch/system" "$ATV/$ch/vendor" "$type" ;;
        *) die "--android must be 13, 16 or 17" ;;
    esac

    sudo systemctl enable --now waydroid-container
    say "Done. Start Android with:  waydroid show-full-ui"
}

cmd_doctor() {
    check_host
    check_firewall
    check_waydroid
    echo
    say "$FAILURES problem(s), $WARNINGS warning(s)"
    (( FAILURES == 0 ))
}

cmd_uninstall() {
    local purge=0
    [[ ${1:-} == --purge ]] && purge=1
    say "Removing droidanvil changes"
    waydroid session stop > /dev/null 2>&1 || true
    sudo systemctl disable --now waydroid-container > /dev/null 2>&1 || true
    close_firewall
    if (( purge )); then
        sudo pacman -Rns --noconfirm waydroid
        sudo rm -rf /var/lib/waydroid "$HOME/.local/share/waydroid"
        ok "removed Waydroid and all Android data"
    fi
}

case ${1:-} in
    install)   shift; cmd_install "$@" ;;
    doctor)    cmd_doctor ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    -v|--version) echo "droidanvil $VERSION" ;;
    *) usage; exit 2 ;;
esac
