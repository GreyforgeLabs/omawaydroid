# droidanvil

Waydroid that just works on Omarchy and Arch Linux.

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
| Android gets no IP address behind ufw (Omarchy's default firewall) | Allows DHCP, DNS and forwarding on `waydroid0` only, tagged `droidanvil` so uninstall can remove them; firewalld gets `waydroid0` in the trusted zone |
| Image downloads stall on a slow SourceForge mirror | Downloads from the fastest working mirror, resumes, verifies the channel's SHA-256, then hands the files to the stock `waydroid init`; `waydroid upgrade` keeps using the official channel |
| A leftover `binder_linux-dkms` freezes kernels that already have binder (omarchy#16625) | `doctor` detects it and prints the removal commands |
| Kernel without binder, broken `python-gbinder` after a Python upgrade, no Wayland session, low memory or disk | `doctor` explains each one and the fix |

## Commands

```
droidanvil.sh install [--android 13|16|17] [--vanilla]
droidanvil.sh doctor
droidanvil.sh uninstall [--purge]
```

- `--android 13` (default) uses the official Waydroid images.
- `--android 16` and `--android 17` use community images built by
  [WayDroid-ATV](https://github.com/WayDroid-ATV/waydroid-builds). They are experimental.
- `--vanilla` installs Android without Google apps.
- `uninstall` stops Waydroid and removes droidanvil's firewall rules; `--purge` also removes the package
  and all Android data.

droidanvil uses the stock Waydroid package from the Arch repositories and changes nothing inside it.

## Requirements

An x86_64 Arch-based system (Omarchy, Arch, EndeavourOS, CachyOS), a Wayland session, a kernel with
binder (Omarchy 7.2.8-9 or newer; Arch `linux`, `linux-zen`, `linux-lts`), about 2 GB of free memory
and 8 GB of disk.

## License

MIT
