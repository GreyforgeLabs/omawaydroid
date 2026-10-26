# droidanvil

Waydroid that just works on Omarchy and Arch Linux.

droidanvil builds on the work of the [Waydroid](https://github.com/waydroid/waydroid) project and
[WayDroid-ATV](https://github.com/WayDroid-ATV/waydroid-builds) to add the fixes and patches needed to
run Android 13, 16 and 17 with Waydroid on a stable Omarchy machine.

One command installs Waydroid, opens the firewall for it, downloads the Android images from a fast
mirror and starts the container. A `doctor` command checks the things that most often stop Waydroid on
Arch-based desktops.

```sh
curl -fsSLO https://raw.githubusercontent.com/GreyforgeLabs/droidanvil/main/droidanvil.sh
bash droidanvil.sh install
waydroid show-full-ui
```

## What it fixes

| Problem | What droidanvil does |
|---|---|
| Android gets no IP address behind ufw (Omarchy's default firewall) | Adds only the missing DHCP, DNS and forwarding rules for `waydroid0`, never changes rules you made, and removes only its own on uninstall; firewalld gets `waydroid0` in the trusted zone |
| Image downloads stall on a slow SourceForge mirror | Downloads from the fastest working mirror, resumes, verifies the channel's SHA-256, then hands the files to the stock `waydroid init`; `waydroid upgrade` keeps using the official channel |
| A leftover `binder_linux-dkms` freezes kernels that already have binder (omarchy#16625) | `doctor` detects it and prints the removal commands |
| Android 16 and 17 open no window for apps started from the app menu | Adds a launcher wrapper that opens them in the Android window |
| Kernel without binder, broken `python-gbinder` after a Python upgrade, no Wayland session, low memory or disk | `doctor` explains each one and the fix |

## Commands

```
droidanvil.sh install [--android 13|16|17] [--vanilla] [--force]
droidanvil.sh doctor
droidanvil.sh uninstall [--purge]
```

- `--android 13` (default) uses the official Waydroid images.
- `--android 16` and `--android 17` install Android 16 or 17, built by
  [WayDroid-ATV](https://github.com/WayDroid-ATV/waydroid-builds). droidanvil sets them up to behave
  like Android 13 does:
  - Android 16 comes from the builder's fixed 2026-08-03 build (checksum-pinned) until the Android 16
    update channel publishes something newer; `waydroid upgrade` then moves to it.
  - Apps opened from your app menu appear in the Android window: droidanvil adds a small `waydroid`
    wrapper in `~/.local/bin` that opens the window after launching an app. Everything else passes
    straight through to Waydroid.
  - Android starts at the home screen instead of a lock screen.
  - The first start shows Google's setup screens; finish them once and apps open normally.
  - Android 16 is available with Google apps only.
- `--vanilla` installs Android without Google apps.
- `--force` switches an existing install to a different channel. Android data is kept, and a different
  Android version may not boot on it; `uninstall --purge` first gives a clean switch.
- `uninstall` stops Waydroid and removes only the firewall rules droidanvil added (recorded in
  `~/.local/state/droidanvil`); `--purge` also removes the package and all Android data.

Image downloads are cached in `~/.cache/droidanvil` and resume if interrupted. Set `DROIDANVIL_MIN_BPS`
to change the speed below which a mirror is abandoned (default 100000 bytes per second).

droidanvil uses the stock Waydroid package from the Arch repositories and changes nothing inside it.

## Requirements

An x86_64 Arch-based system (Omarchy, Arch, EndeavourOS, CachyOS), a Wayland session, a kernel with
binder (Omarchy 7.2.8-9 or newer; Arch `linux`, `linux-zen`, `linux-lts`), about 2 GB of free memory
and 8 GB of disk.

## Credits

- [Waydroid](https://github.com/waydroid/waydroid): the container runtime and the official Android 13 images.
- [WayDroid-ATV](https://github.com/WayDroid-ATV/waydroid-builds): the Android 16 and 17 images.
- [Omarchy](https://github.com/omacom/omarchy): the kernel with binder built in.

## License

MIT
