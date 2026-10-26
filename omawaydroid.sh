#!/usr/bin/env bash
# omawaydroid: Waydroid that just works on Omarchy and Arch Linux.
# Runs as your normal user and asks sudo for the root steps.
set -euo pipefail

VERSION=0.1.0
TAG=omawaydroid
ATV=https://waydroid-atv.github.io/ota
# The Android 16 channel still serves the 2026-07-17 build, whose display service crash-loops
# (WayDroid-ATV issue #37). Until the channel has something newer, install the fixed 2026-08-03
# build the same builder published in that issue. It exists with Google apps only.
A16_FIXED_URL="https://drive.usercontent.google.com/download?id=1MeFBajp-IVILssFEmMLaGz3BWN2qvKuG&export=download&confirm=t"
A16_FIXED_SHA=6c057275bcadde60fa3d19f4012455a643ed18e5846a1227971e526d6491ed44
A16_FIXED_NAME=lineage-23.2-20260803-GAPPS-waydroid_x86_64.zip
A16_FIXED_STAMP=1785785040
# Android 16 and 17 images only show apps inside the full Android window, so app-menu entries
# (`waydroid app launch|intent`) go through this wrapper, which opens that window afterwards.
SHIM=$HOME/.local/bin/waydroid
SHIM_MARK="# omawaydroid-shim v1"
# Android 16 shows its lock screen on every start unless this default is set before the first boot.
LOCK_PROP=ro.lockscreen.disable.default
SF_MIRRORS=(autoselect freefr netactuate pilotfiber phoenixnap netix)
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/omawaydroid
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/omawaydroid
CFG=/var/lib/waydroid/waydroid.cfg
PREINSTALLED=(/etc/waydroid-extra/images /usr/share/waydroid-extra/images)
# Skip a mirror that stays below this many bytes per second for 30 seconds.
MIN_BPS=${OMAWAYDROID_MIN_BPS:-100000}

# ufw rules omawaydroid needs, without the leading action word.
UFW_RULES=(
    "in on waydroid0 to any port 67 proto udp"
    "in on waydroid0 to any port 53"
    "route in on waydroid0"
    "route out on waydroid0"
)

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B= G= Y= R= N=; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %sok%s   %s\n' "$G" "$N" "$*"; }
info() { printf '  --   %s\n' "$*"; }
warn() { printf '  %swarn%s %s\n' "$Y" "$N" "$*"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  %sfail%s %s\n' "$R" "$N" "$*"; FAILURES=$((FAILURES + 1)); }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
WARNINGS=0 FAILURES=0
WORK_DIR=
trap '[[ -n $WORK_DIR ]] && rm -rf "$WORK_DIR"' EXIT

usage() {
    cat <<'EOF'
omawaydroid: Waydroid that just works on Omarchy and Arch Linux.

  omawaydroid.sh install [--android 13|16|17] [--vanilla] [--force]
                                   set up Waydroid end to end; --force replaces an existing
                                   install from a different channel (Android data is kept)
  omawaydroid.sh doctor             read-only health check
  omawaydroid.sh uninstall [--purge]
                                   undo omawaydroid's changes; --purge also removes Waydroid
                                   and all Android data
EOF
}

cfg_get() { [[ -r $CFG ]] && awk -F' = ' -v k="$1" '$1 == k {print $2}' "$CFG" || true; }

# --- host facts -----------------------------------------------------------------------

kernel_config() {
    zcat /proc/config.gz 2>/dev/null && return
    cat "/usr/lib/modules/$(uname -r)/build/.config" 2>/dev/null && return
    cat "/boot/config-$(uname -r)" 2>/dev/null || true
}

# builtin | module | dkms | none
binder_kind() {
    local cfg
    cfg=$(kernel_config)
    if grep -qE '^CONFIG_ANDROID_BINDER_IPC(_RUST)?=y' <<< "$cfg"; then
        echo builtin
    elif grep -q '^CONFIG_ANDROID_BINDER_IPC=m' <<< "$cfg"; then
        echo module
    elif [[ -n $(dkms_leftovers) ]]; then
        echo dkms
    elif grep -qw binder /proc/filesystems || [[ -e /dev/binder && -e /dev/vndbinder ]]; then
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

ufw_active() { command -v ufw > /dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; }
firewalld_active() { systemctl is-active -q firewalld 2>/dev/null; }

# Prints the existing ufw rule (any action, any comment) for a omawaydroid rule spec, if there is one.
ufw_existing() {  # spec
    local spec=$1 prefix=ufw
    [[ $spec == route\ * ]] && { prefix="ufw route"; spec=${spec#route }; }
    sudo ufw show added | grep -E "^$prefix (allow|deny|reject|limit) $spec( comment .*)?$" || true
}

ufw_spec_cmd() {  # spec -> "route allow in on ..." or "allow in on ..."
    if [[ $1 == route\ * ]]; then echo "route allow ${1#route }"; else echo "allow $1"; fi
}

preinstalled_images() {
    local d
    for d in "${PREINSTALLED[@]}"; do
        [[ -e $d/system.img || -e $d/vendor.img ]] && echo "$d"
    done
    return 0
}

# --- checks ---------------------------------------------------------------------------

check_host() {
    say "Checking this machine"
    command -v pacman > /dev/null || die "omawaydroid supports Arch-based systems (Omarchy, Arch, EndeavourOS, CachyOS) for now"
    [[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported for now"

    if [[ -n ${WAYLAND_DISPLAY:-} ]]; then ok "Wayland session ($WAYLAND_DISPLAY)"
    else bad "no Wayland session: Waydroid needs one (from X11, run it inside 'cage' or 'weston')"; fi

    local kind leftovers
    kind=$(binder_kind)
    case $kind in
        builtin) ok "kernel $(uname -r) has binder built in" ;;
        module)  ok "kernel $(uname -r) ships binder as a module" ;;
        dkms)    warn "binder comes from a DKMS module; it can break on kernel updates (Omarchy 7.2.8-9+ and Arch linux/zen/lts include binder)" ;;
        none)    bad "kernel $(uname -r) has no binder driver: update (Omarchy: omarchy-update) or install linux-zen, then reboot" ;;
    esac
    leftovers=$(dkms_leftovers)
    if [[ $kind == builtin && -n $leftovers ]]; then
        bad "a leftover binder DKMS module collides with the built-in driver (EBUSY at boot, random freezes; omarchy#16625):"
        sed 's/^/         /' <<< "$leftovers"
        echo "         fix: sudo pacman -Rns binder_linux-dkms   (and remove binder_linux from /etc/modules-load.d), then reboot"
    fi

    local avail_kb free_kb
    avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    if (( avail_kb > 2 * 1024 * 1024 )); then ok "$((avail_kb / 1024)) MB memory available"
    else warn "only $((avail_kb / 1024)) MB memory available; Android needs about 2 GB"; fi
    free_kb=$(df -Pk /var/lib | awk 'NR == 2 {print $4}')
    if (( free_kb > 8 * 1024 * 1024 )); then ok "$((free_kb / 1024 / 1024)) GB free for images"
    else warn "only $((free_kb / 1024 / 1024)) GB free under /var/lib; images need about 6 GB plus 2 GB while installing"; fi

    local d
    for d in $(preinstalled_images); do
        warn "$d holds Waydroid images; they override any downloaded image and block updates"
    done
}

check_firewall() {
    if ufw_active; then
        local spec missing=0
        for spec in "${UFW_RULES[@]}"; do
            ufw_existing "$spec" | grep -qE '^ufw (route )?allow ' || missing=$((missing + 1))
        done
        if (( missing == 0 )); then ok "ufw allows Waydroid's network"
        else warn "ufw is active and blocks Waydroid's DHCP, DNS or forwarding ($missing rule(s) missing; Android gets no network); install adds them"; fi
    elif firewalld_active; then
        if [[ $(sudo firewall-cmd --get-zone-of-interface=waydroid0 2>/dev/null) == trusted ]]; then ok "firewalld trusts waydroid0"
        else warn "firewalld is active; Waydroid's bridge must be in the trusted zone; install adds it"; fi
    else
        ok "no ufw/firewalld"
    fi
}

check_waydroid() {
    if ! pacman -Q waydroid > /dev/null 2>&1; then info "Waydroid not installed"; return; fi
    ok "$(pacman -Q waydroid)"
    if python3 -I -c 'import gbinder' 2> /dev/null; then ok "python-gbinder imports"
    else bad "python-gbinder is broken (usually after a Python upgrade): sudo pacman -Syu python-gbinder"; fi
    if [[ ! -r $CFG ]]; then info "not initialized yet"; return; fi
    local sys ven sys_ota
    sys=$(cfg_get system_datetime) ven=$(cfg_get vendor_datetime) sys_ota=$(cfg_get system_ota)
    if [[ $sys_ota == file://* ]]; then
        bad "an earlier install stopped half-way (update channel points at a deleted folder): run install again"
    elif [[ $sys_ota == None ]]; then
        info "using preinstalled images (no updates)"
    elif [[ -z $sys || $sys == 0 ]]; then
        bad "no Android image installed yet: run install"
    else
        ok "images built $(date -d "@$sys" +%F) (system), $(date -d "@$ven" +%F) (vendor) from $sys_ota"
    fi
    if [[ $sys_ota == "$ATV"/* ]]; then
        if shim_is_ours && session_prefers_shim; then
            ok "app-menu entries open inside the Android window"
        else
            warn "Android 16/17 apps started from the app menu will not appear: run install again to add the launcher"
        fi
    fi
    if systemctl is-active -q waydroid-container; then ok "waydroid-container is running"; else info "waydroid-container is stopped"; fi
}

shim_is_ours() { [[ -f $SHIM && ! -L $SHIM ]] && grep -qxF "$SHIM_MARK" "$SHIM"; }

# App-menu entries run `waydroid` from the desktop session's PATH, not from this terminal's.
session_prefers_shim() {
    local path dir dirs
    path=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^PATH=//p')
    [[ -n $path ]] || path=$PATH
    IFS=: read -ra dirs <<< "$path"
    for dir in "${dirs[@]}"; do
        [[ $dir == "$(dirname "$SHIM")" ]] && return 0
        [[ $dir == /usr/bin || $dir == /bin ]] && return 1
    done
    return 1
}

install_shim() {
    if [[ -e $SHIM || -L $SHIM ]] && ! shim_is_ours; then
        warn "kept your own $SHIM, so Android 16/17 apps started from the app menu will not appear"
        return 0
    fi
    mkdir -p "$(dirname "$SHIM")"
    local tmp=$SHIM.tmp.$$
    cat > "$tmp" <<EOF
#!/bin/sh
$SHIM_MARK
# Installed by omawaydroid for Android 16/17 images, which only show apps inside the full Android
# window: open that window after launching an app. Everything else goes straight to Waydroid.
case "\$3" in ""|-*) exec /usr/bin/waydroid "\$@" ;; esac
if [ "\$1" = app ] && { [ "\$2" = launch ] || [ "\$2" = intent ]; }; then
    # From a cold start, open the window and wait for Android to finish booting first, or the
    # launch is lost behind the home screen. Give up after three minutes.
    if ! /usr/bin/waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'; then
        setsid /usr/bin/waydroid show-full-ui > /dev/null 2>&1 < /dev/null &
        end=\$((\$(date +%s) + 180))
        until [ "\$(timeout 10 /usr/bin/waydroid prop get sys.boot_completed 2>/dev/null)" = 1 ]; do
            if [ "\$(date +%s)" -ge "\$end" ]; then
                notify-send -a Waydroid "Android did not start" "Run omawaydroid.sh doctor to see why." 2>/dev/null
                exit 1
            fi
            sleep 1
        done
        sleep 3
    fi
    /usr/bin/waydroid "\$@" || exit \$?
    exec /usr/bin/waydroid show-full-ui
fi
exec /usr/bin/waydroid "\$@"
EOF
    chmod 755 "$tmp"
    mv -f "$tmp" "$SHIM"
    if session_prefers_shim; then ok "app-menu entries will open inside the Android window"
    else warn "$(dirname "$SHIM") is not ahead of /usr/bin in your desktop session's PATH, so Android 16/17 apps started from the app menu will not appear"; fi
}

remove_shim() {
    if shim_is_ours; then
        rm -f "$SHIM"
        ok "removed the Android 16/17 app launcher"
    fi
}

# Add or remove the lock-screen default; rebuild Android's properties only when the config changed.
lockscreen_default() {  # add|remove
    [[ -r $CFG ]] || return 0
    local rc=0
    sudo python3 -I -c '
import sys
path, action, key = sys.argv[1:4]
lines = open(path).read().split("\n")
def is_key(line):
    return line.split("=")[0].strip() == key
has = any(is_key(line) for line in lines)
if action == "add" and not has:
    if "[properties]" not in [line.strip() for line in lines]:
        while lines and lines[-1] == "":
            lines.pop()
        lines += ["", "[properties]", ""]
    i = [line.strip() for line in lines].index("[properties]")
    lines.insert(i + 1, key + " = true")
elif action == "remove" and has:
    lines = [line for line in lines if not is_key(line)]
else:
    sys.exit(3)
open(path, "w").write("\n".join(lines))' "$CFG" "$1" "$LOCK_PROP" || rc=$?
    if (( rc == 0 )); then sudo waydroid upgrade --offline > /dev/null 2>&1 || true; fi
}

# --- firewall -------------------------------------------------------------------------

# Add only the rules that are missing and remember them, so uninstall never touches rules the user made.
open_firewall() {
    mkdir -p "$STATE"
    if ufw_active; then
        local spec existing added=0
        for spec in "${UFW_RULES[@]}"; do
            existing=$(ufw_existing "$spec")
            if [[ -z $existing ]]; then
                # shellcheck disable=SC2046
                sudo ufw $(ufw_spec_cmd "$spec") comment "$TAG" > /dev/null
                echo "$spec" >> "$STATE/ufw-rules"
                added=$((added + 1))
            elif ! grep -qE '^ufw (route )?allow ' <<< "$existing"; then
                warn "kept your existing ufw rule '$existing'; Waydroid's network may not work"
            fi
        done
        ok "ufw: $added rule(s) added for waydroid0 only"
    elif firewalld_active; then
        local zone
        zone=$(sudo firewall-cmd --permanent --get-zone-of-interface=waydroid0 2>/dev/null || true)
        if [[ $zone == trusted ]]; then
            ok "firewalld already trusts waydroid0"
        elif [[ -n $zone ]]; then
            warn "waydroid0 is in firewalld zone '$zone'; move it to 'trusted' yourself if Android has no network"
        else
            sudo firewall-cmd --zone=trusted --add-interface=waydroid0 > /dev/null
            sudo firewall-cmd --permanent --zone=trusted --add-interface=waydroid0 > /dev/null
            touch "$STATE/firewalld-trusted"
            ok "firewalld: waydroid0 added to the trusted zone"
        fi
    fi
}

close_firewall() {
    if [[ -s $STATE/ufw-rules ]] && command -v ufw > /dev/null; then
        local spec specs
        mapfile -t specs < "$STATE/ufw-rules"
        # Deleting by rule spec works even while ufw is disabled.
        for spec in "${specs[@]}"; do
            # Route rules are removed with "ufw route delete allow ...", the others with "ufw delete allow ...".
            if [[ $spec == route\ * ]]; then
                # shellcheck disable=SC2086
                sudo ufw --force route delete allow ${spec#route } < /dev/null > /dev/null 2>&1 || true
            else
                # shellcheck disable=SC2086
                sudo ufw --force delete allow $spec < /dev/null > /dev/null 2>&1 || true
            fi
        done
        rm -f "$STATE/ufw-rules"
        ok "ufw: removed the rules omawaydroid added"
    fi
    if [[ -e $STATE/firewalld-trusted ]] && command -v firewall-cmd > /dev/null; then
        sudo firewall-cmd --zone=trusted --remove-interface=waydroid0 > /dev/null 2>&1 || true
        sudo firewall-cmd --permanent --zone=trusted --remove-interface=waydroid0 > /dev/null 2>&1 || true
        rm -f "$STATE/firewalld-trusted"
        ok "firewalld: removed waydroid0 from the trusted zone"
    fi
}

# --- images ---------------------------------------------------------------------------

sha_ok() { [[ -f $1 && $(sha256sum < "$1" | cut -d' ' -f1) == "$2" ]]; }

# Download one image zip into the cache from the fastest working SourceForge mirror, resuming
# partial files across mirrors and runs, and check its hash.
fetch() {  # url sha256 dest
    local url=$1 sum=$2 dest=$3 direct mirror
    if sha_ok "$dest" "$sum"; then ok "$(basename "$dest") already downloaded"; return 0; fi
    # A partial file that is not a zip (an error page) cannot be resumed.
    if [[ -s $dest && $(head -c 2 "$dest") != PK ]]; then rm -f "$dest"; fi
    direct=$(sed -E 's#^https://sourceforge\.net/projects/([^/]+)/files/(.*)/download$#https://downloads.sourceforge.net/project/\1/\2#' <<< "$url")
    local curl=(curl -fL --progress-bar --proto =https --proto-redir =https --retry 3 -C - -o "$dest") rc=0
    if [[ $direct != "$url" ]]; then
        for mirror in "${SF_MIRRORS[@]}"; do
            "${curl[@]}" --speed-limit "$MIN_BPS" --speed-time 30 -- "$direct?use_mirror=$mirror" && break
        done
    fi
    # Last attempt without a speed floor, so slow connections still finish.
    sha_ok "$dest" "$sum" || "${curl[@]}" -- "$url" || rc=$?
    sha_ok "$dest" "$sum" && return 0
    if [[ $url == "$A16_FIXED_URL" ]] && { (( rc == 22 )) || [[ -s $dest && $(head -c 2 "$dest") != PK ]]; }; then
        rm -f "$dest"
        die "the fixed Android 16 build cannot be downloaded from Google Drive right now; try again later or use --android 17"
    fi
    (( rc == 0 )) || die "the download of $(basename "$dest") was interrupted; run install again to resume it"
    rm -f "$dest"
    die "$(basename "$dest") did not match its checksum; run install again to download it fresh"
}

# Prints "url sha256 filename datetime" for the newest entry of a channel JSON file.
channel_entry() {
    python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))["response"][0]
print(r["url"], r["id"], r["filename"], r["datetime"])' "$1"
}

# Waydroid's own downloader cannot pick a mirror, so build a local copy of the OTA channel whose
# entries point at verified files on disk, let `waydroid init` consume it, then point the config
# back at the real channel so `waydroid upgrade` keeps working.
init_images() {  # system_channel vendor_channel system_type force [pin]
    local sys_ch=$1 ven_ch=$2 type=$3 force=$4 pin=${5:-}
    local -A rel=([system]=lineage/waydroid_x86_64/$type.json [vendor]=waydroid_x86_64/MAINLINE.json)
    local -A ch=([system]=$sys_ch [vendor]=$ven_ch)
    local -A url sum file stamp
    mkdir -p "$CACHE"
    WORK_DIR=$(mktemp -d "$CACHE/channel.XXXXXX")

    local part name
    for part in system vendor; do
        curl -fsSL --proto =https "${ch[$part]}/${rel[$part]}" -o "$WORK_DIR/$part.json" \
            || die "cannot read the $part channel ${ch[$part]}/${rel[$part]}"
        read -r "url[$part]" "sum[$part]" name "stamp[$part]" < <(channel_entry "$WORK_DIR/$part.json")
        # The channel is third-party data: never let it choose paths, options or hashes we cannot check.
        [[ $name =~ ^[A-Za-z0-9._+-]+\.zip$ && ${sum[$part]} =~ ^[0-9a-f]{64}$ &&
           ${url[$part]} == https://* && ${stamp[$part]} =~ ^[0-9]+$ ]] \
            || die "the $part channel returned an unexpected entry; refusing to use it"
        file[$part]=$CACHE/$name
    done

    # One zip holds both images, so both channel entries point at it.
    if [[ $pin == a16 ]] && (( stamp[system] < A16_FIXED_STAMP )); then
        for part in system vendor; do
            url[$part]=$A16_FIXED_URL sum[$part]=$A16_FIXED_SHA stamp[$part]=$A16_FIXED_STAMP
            file[$part]=$CACHE/$A16_FIXED_NAME
        done
    fi

    local cur_stamp
    cur_stamp=$(cfg_get system_datetime)
    if [[ $(cfg_get system_ota) == "$sys_ch/${rel[system]}" && ${cur_stamp:-0} -ge ${stamp[system]} ]]; then
        ok "Android images are already current"
        return 0
    fi

    for part in system vendor; do
        say "Downloading $(basename "${file[$part]}")"
        fetch "${url[$part]}" "${sum[$part]}" "${file[$part]}"
        mkdir -p "$WORK_DIR/$part/$(dirname "${rel[$part]}")"
        python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
r = d["response"] = d["response"][:1]
r[0].update(url="file://" + sys.argv[2], filename=sys.argv[2].rsplit("/", 1)[1],
            id=sys.argv[3], datetime=int(sys.argv[4]))
json.dump(d, open(sys.argv[5], "w"))' "$WORK_DIR/$part.json" "${file[$part]}" "${sum[$part]}" "${stamp[$part]}" \
            "$WORK_DIR/$part/${rel[$part]}"
    done

    say "Initializing Waydroid"
    local rc=0
    sudo waydroid init ${force:+-f} -c "file://$WORK_DIR/system" -v "file://$WORK_DIR/vendor" -r lineage -s "$type" || rc=$?
    # Point the config back at the real channel even if init failed half-way, then rebuild the props
    # that recorded the temporary file:// channel.
    if [[ -r $CFG ]]; then
        sudo sed -i -e "s#^system_ota = file://.*#system_ota = $sys_ch/${rel[system]}#" \
                    -e "s#^vendor_ota = file://.*#vendor_ota = $ven_ch/${rel[vendor]}#" "$CFG"
        sudo waydroid upgrade --offline > /dev/null 2>&1 || true
    fi
    (( rc == 0 )) || die "waydroid init failed (see above); run install again to retry"
    rm -f "${file[system]}" "${file[vendor]}"
    ok "updates will come from $sys_ch"
}

# --- commands -------------------------------------------------------------------------

cmd_install() {
    local android=13 type=GAPPS force=
    while (( $# )); do
        case $1 in
            --android) android=${2:-}; shift ;;
            --vanilla) type=VANILLA ;;
            --force)   force=1 ;;
            *) die "unknown option $1" ;;
        esac
        shift
    done
    [[ $android =~ ^(13|16|17)$ ]] || die "--android must be 13, 16 or 17"
    [[ $android == 16 && $type == VANILLA ]] && die "Android 16 is available with Google apps only for now; use --android 17 --vanilla"

    local sys_ch ven_ch
    case $android in
        13) sys_ch=https://ota.waydro.id/system ven_ch=https://ota.waydro.id/vendor ;;
        16) sys_ch=$ATV/a16-qpr2/system ven_ch=$ATV/a16-qpr2/vendor ;;
        17) sys_ch=$ATV/a17-qpr0/system ven_ch=$ATV/a17-qpr0/vendor ;;
    esac

    check_host
    (( FAILURES == 0 )) || die "fix the problems above, then run install again"
    [[ -z $(preinstalled_images) ]] || die "remove the preinstalled images listed above first; Waydroid would ignore the download"

    local current
    current=$(cfg_get system_ota)
    if [[ -n $current && $current != None && $current != file://* &&
          $current != "$sys_ch/lineage/waydroid_x86_64/$type.json" && -z $force ]]; then
        die "Waydroid is set up from $current. Switching channels keeps your Android data, and a different
       Android version may not boot on it. Run 'uninstall --purge' first for a clean switch, or add --force."
    fi
    (( android == 13 )) || info "Android $android images are built by WayDroid-ATV (https://github.com/WayDroid-ATV/waydroid-builds)"

    say "Installing Waydroid"
    sudo pacman -S --needed --noconfirm waydroid
    open_firewall
    local pin=
    if (( android == 16 )); then pin=a16; fi
    init_images "$sys_ch" "$ven_ch" "$type" "$force" "$pin"
    if (( android == 13 )); then
        remove_shim
        lockscreen_default remove
    else
        install_shim
        lockscreen_default add
    fi
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
    case ${1:-} in
        --purge) purge=1 ;;
        "") ;;
        *) die "unknown option $1" ;;
    esac
    say "Removing omawaydroid changes"
    waydroid session stop > /dev/null 2>&1 || true
    sudo systemctl disable --now waydroid-container > /dev/null 2>&1 || true
    close_firewall
    remove_shim
    (( purge )) || lockscreen_default remove
    rm -rf "$CACHE"
    if (( purge )); then
        if findmnt -rn -o TARGET | grep -q '^/var/lib/waydroid\(/\|$\)'; then
            die "Waydroid's images are still mounted; stop Waydroid (sudo waydroid container stop) and run uninstall again"
        fi
        if pacman -Q waydroid > /dev/null 2>&1; then
            sudo pacman -Rn --noconfirm waydroid || warn "could not remove the waydroid package"
        fi
        local data=${XDG_DATA_HOME:-$HOME/.local/share}
        sudo rm -rf --one-file-system /var/lib/waydroid "$data/waydroid"
        rm -f "$data"/applications/waydroid.*.desktop
        rm -rf "$STATE"
        ok "removed Waydroid and all Android data (its dependencies stay; see 'pacman -Qdt')"
    fi
}

case ${1:-} in
    install)   shift; cmd_install "$@" ;;
    doctor)    cmd_doctor ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    -v|--version) echo "omawaydroid $VERSION" ;;
    *) usage; exit 2 ;;
esac
