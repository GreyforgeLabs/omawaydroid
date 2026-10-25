//! Kernel binder support: which driver the running kernel offers, whether a stale DKMS module
//! fights the built-in one, and whether binderfs can hand Waydroid its three device nodes.

use crate::host::{Host, parse_kconfig};
use crate::model::{Finding, Status};

const DKMS_MODULE: &str = "binder_linux";
const DKMS_PACKAGES: &[&str] = &["binder_linux-dkms", "anbox-modules-dkms"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Driver {
    BuiltinRust,
    BuiltinC,
    ModuleC,
    /// Only an out-of-tree module (binder_linux, usually from DKMS) is present.
    OutOfTree,
    None,
    /// No kernel config readable and no other signal.
    Unknown,
}

struct Facts {
    release: String,
    kconfig_found: bool,
    rust: bool,
    c_builtin: bool,
    c_module: bool,
    static_devices: String,
    binderfs: bool,
    module_loaded: bool,
    dkms_files: Vec<String>,
    dkms_packages: Vec<String>,
    autoload: Vec<String>,
    cmdline_devices: Option<String>,
}

fn gather(host: &Host) -> Facts {
    let release = host
        .read("/proc/sys/kernel/osrelease")
        .unwrap_or_default()
        .trim()
        .to_string();
    let kconfig_text = host
        .read_gz("/proc/config.gz")
        .or_else(|| host.read(&format!("/usr/lib/modules/{release}/build/.config")))
        .or_else(|| host.read(&format!("/boot/config-{release}")));
    let kconfig = kconfig_text
        .as_deref()
        .map(parse_kconfig)
        .unwrap_or_default();
    let opt = |k: &str| kconfig.get(k).map(String::as_str);

    let binderfs = host
        .read("/proc/filesystems")
        .map(|t| {
            t.lines()
                .any(|l| l.split_whitespace().last() == Some("binder"))
        })
        .unwrap_or(false);
    let module_loaded = host
        .read("/proc/modules")
        .map(|t| {
            t.lines()
                .any(|l| l.split_whitespace().next() == Some(DKMS_MODULE))
        })
        .unwrap_or(false);

    let mut dkms_files = Vec::new();
    for kdir in host.list("/usr/lib/modules") {
        let dir = format!("/usr/lib/modules/{kdir}/updates/dkms");
        for f in host.list(&dir) {
            if f.starts_with(&format!("{DKMS_MODULE}.ko")) {
                dkms_files.push(format!("{dir}/{f}"));
            }
        }
    }
    if host.exists(&format!("/var/lib/dkms/{DKMS_MODULE}")) {
        dkms_files.push(format!("/var/lib/dkms/{DKMS_MODULE}"));
    }

    let dkms_packages = DKMS_PACKAGES
        .iter()
        .filter(|p| host.run("pacman", &["-Q", p]).is_some_and(|o| o.ok()))
        .map(|p| p.to_string())
        .collect();

    let mut autoload = Vec::new();
    for dir in [
        "/etc/modules-load.d",
        "/usr/lib/modules-load.d",
        "/etc/modprobe.d",
    ] {
        for f in host.list(dir) {
            let path = format!("{dir}/{f}");
            if host.read(&path).is_some_and(|t| {
                t.lines()
                    .any(|l| !l.trim_start().starts_with('#') && l.contains(DKMS_MODULE))
            }) {
                autoload.push(path);
            }
        }
    }

    let cmdline_devices = host.read("/proc/cmdline").and_then(|c| {
        c.split_whitespace()
            .find(|w| {
                w.starts_with("rust_binder.rust_devices=")
                    || w.starts_with("binder.devices=")
                    || w.starts_with("binder_linux.devices=")
            })
            .map(|w| w.to_string())
    });

    Facts {
        release,
        kconfig_found: kconfig_text.is_some(),
        rust: opt("CONFIG_ANDROID_BINDER_IPC_RUST") == Some("y"),
        c_builtin: opt("CONFIG_ANDROID_BINDER_IPC") == Some("y"),
        c_module: opt("CONFIG_ANDROID_BINDER_IPC") == Some("m"),
        static_devices: opt("CONFIG_ANDROID_BINDER_DEVICES")
            .unwrap_or("")
            .to_string(),
        binderfs,
        module_loaded,
        dkms_files,
        dkms_packages,
        autoload,
        cmdline_devices,
    }
}

fn driver(f: &Facts) -> Driver {
    if f.rust {
        Driver::BuiltinRust
    } else if f.c_builtin {
        Driver::BuiltinC
    } else if f.c_module {
        Driver::ModuleC
    } else if f.module_loaded || !f.dkms_files.is_empty() {
        Driver::OutOfTree
    } else if f.kconfig_found {
        Driver::None
    } else if f.binderfs {
        // No config to read, but the filesystem is registered, so something provides binder.
        Driver::BuiltinC
    } else {
        Driver::Unknown
    }
}

pub fn check(host: &Host) -> Vec<Finding> {
    let f = gather(host);
    let drv = driver(&f);
    let mut out = Vec::new();

    let support = match drv {
        Driver::BuiltinRust => Finding::new("binder.kernel", Status::Pass, "Kernel has the built-in Rust binder driver")
            .detail("Waydroid mounts binderfs and creates anbox-binder / anbox-hwbinder / anbox-vndbinder itself; no module is needed."),
        Driver::BuiltinC => Finding::new("binder.kernel", Status::Pass, "Kernel has the built-in binder driver"),
        Driver::ModuleC => Finding::new("binder.kernel", Status::Pass, "Kernel ships binder as a module")
            .detail("Waydroid loads it with modprobe when the container starts."),
        Driver::OutOfTree => Finding::new("binder.kernel", Status::Info, "Binder comes from an out-of-tree (DKMS) module")
            .detail("This works until a kernel update breaks the DKMS build. Kernels that ship binder themselves are less fragile: \
                     Arch linux / linux-zen / linux-lts and linux-omarchy >= 7.2.8-9 all include the Rust binder driver."),
        Driver::None => Finding::new("binder.kernel", Status::Fail, "This kernel has no binder driver; Waydroid cannot start")
            .detail(format!("Kernel {} was built without CONFIG_ANDROID_BINDER_IPC or CONFIG_ANDROID_BINDER_IPC_RUST, \
                             and no binder_linux module is installed.", f.release))
            .fix(
                "Switch to a kernel with binder. On Omarchy update to linux-omarchy 7.2.8-9 or newer; on Arch, linux, linux-zen and linux-lts include it (linux-hardened does not).",
                &["omarchy-update  # Omarchy", "sudo pacman -S linux-zen  # Arch: or linux / linux-lts, then reboot into it"],
                true,
            )
            .reference("https://github.com/omacom/omarchy/issues/12149")
            .reference("https://wiki.archlinux.org/title/Waydroid#Kernel_modules"),
        Driver::Unknown => Finding::new("binder.kernel", Status::Warn, "Could not determine whether the kernel supports binder")
            .detail("Neither /proc/config.gz nor the kernel's .config could be read, and binderfs is not registered."),
    };
    out.push(support.evidence(format!("kernel {}", f.release)));

    // A stale binder_linux next to a built-in driver: both try to register binderfs. On
    // linux-omarchy 7.2.8-9 that is EBUSY at every boot followed by random freezes.
    let builtin = matches!(drv, Driver::BuiltinRust | Driver::BuiltinC);
    let stale = !f.dkms_packages.is_empty()
        || !f.dkms_files.is_empty()
        || !f.autoload.is_empty()
        || f.module_loaded;
    if builtin && stale {
        let mut cmds: Vec<String> = Vec::new();
        if !f.dkms_packages.is_empty() {
            cmds.push(format!("sudo pacman -Rns {}", f.dkms_packages.join(" ")));
        }
        for a in &f.autoload {
            cmds.push(format!("sudo sed -i '/{DKMS_MODULE}/d' {a}"));
        }
        cmds.push("reboot".into());
        let refs: Vec<&str> = cmds.iter().map(String::as_str).collect();
        let mut finding = Finding::new(
            "binder.dkms-collision",
            Status::Fail,
            "A leftover binder DKMS module collides with the kernel's built-in binder",
        )
        .detail("Two binder drivers fight over binderfs. Reported effects: EBUSY at every boot, kernel memory corruption, random freezes. \
                 The kernel's own driver is enough; remove the DKMS module.")
        .fix("Remove the DKMS module and its autoload entries, then reboot", &refs, true)
        .reference("https://github.com/omacom/omarchy/issues/16625");
        for p in &f.dkms_packages {
            finding = finding.evidence(format!("package installed: {p}"));
        }
        for p in f.dkms_files.iter().chain(&f.autoload) {
            finding = finding.evidence(format!("found {p}"));
        }
        if f.module_loaded {
            finding =
                finding.evidence(format!("{DKMS_MODULE} is loaded right now (/proc/modules)"));
        }
        out.push(finding);
    } else if builtin {
        out.push(Finding::new(
            "binder.dkms-collision",
            Status::Pass,
            "No stale binder DKMS module",
        ));
    }

    // Device nodes: binderfs (Waydroid allocates its own) or static devices named by the kernel.
    if f.binderfs {
        let mut ok = Finding::new("binder.binderfs", Status::Pass, "binderfs is available")
            .evidence("/proc/filesystems lists binder");
        if let Some(c) = &f.cmdline_devices {
            ok = ok.evidence(format!("kernel command line: {c}"));
        }
        out.push(ok);
    } else if !f.static_devices.is_empty() {
        out.push(
            Finding::new(
                "binder.binderfs",
                Status::Pass,
                "Kernel creates static binder devices",
            )
            .evidence(format!(
                "CONFIG_ANDROID_BINDER_DEVICES={}",
                f.static_devices
            )),
        );
    } else if matches!(drv, Driver::BuiltinRust | Driver::BuiltinC) {
        out.push(
            Finding::new("binder.binderfs", Status::Fail, "Binder is built in but binderfs is not registered")
                .detail("Waydroid needs binderfs to create its device nodes when the kernel defines no static devices.")
                .evidence("/proc/filesystems has no binder entry")
                .evidence("CONFIG_ANDROID_BINDER_DEVICES is empty"),
        );
    } else if drv == Driver::ModuleC || drv == Driver::OutOfTree {
        out.push(Finding::new(
            "binder.binderfs",
            Status::Skip,
            "binderfs appears once the binder module is loaded",
        ));
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::FakeRunner;
    use crate::testutil::{Tree, status};
    use std::path::Path;

    const RUST_CFG: &str = "# CONFIG_ANDROID_BINDER_IPC is not set\nCONFIG_ANDROID_BINDER_IPC_RUST=y\nCONFIG_ANDROID_BINDER_DEVICES=\"\"\n";

    #[test]
    fn omarchy_rust_binder_clean() {
        let d = Tree::new(&[
            ("/proc/sys/kernel/osrelease", "7.2.8-9-omarchy\n"),
            ("/proc/config.gz", RUST_CFG),
            ("/proc/filesystems", "nodev\tsysfs\nnodev\tbinder\n"),
            ("/proc/modules", "amdgpu 1 0 - Live 0x0\n"),
        ]);
        let host = Host::fixture(d.path(), FakeRunner::default());
        let f = check(&host);
        assert_eq!(status(&f, "binder.kernel"), Some(Status::Pass));
        assert_eq!(status(&f, "binder.dkms-collision"), Some(Status::Pass));
        assert_eq!(status(&f, "binder.binderfs"), Some(Status::Pass));
    }

    #[test]
    fn omarchy_16625_dkms_collision() {
        let d = Tree::new(&[
            ("/proc/sys/kernel/osrelease", "7.2.8-9-omarchy\n"),
            ("/proc/config.gz", RUST_CFG),
            ("/proc/filesystems", "nodev\tbinder\n"),
            (
                "/usr/lib/modules/7.2.8-9-omarchy/updates/dkms/binder_linux.ko.zst",
                "",
            ),
            ("/etc/modules-load.d/binder.conf", "binder_linux\n"),
        ]);
        let runner =
            FakeRunner::default().with("pacman -Q binder_linux-dkms", 0, "binder_linux-dkms 1-1\n");
        let host = Host::fixture(d.path(), runner);
        let f = check(&host);
        let c = f.iter().find(|x| x.id == "binder.dkms-collision").unwrap();
        assert_eq!(c.status, Status::Fail);
        let cmds = &c.fix.as_ref().unwrap().commands;
        assert!(cmds[0].contains("pacman -Rns binder_linux-dkms"));
        assert!(
            cmds.iter()
                .any(|x| x.contains("/etc/modules-load.d/binder.conf"))
        );
    }

    #[test]
    fn kernel_without_binder_fails() {
        let d = Tree::new(&[
            ("/proc/sys/kernel/osrelease", "7.2.5-3-omarchy\n"),
            (
                "/proc/config.gz",
                "# CONFIG_ANDROID_BINDER_IPC is not set\n# CONFIG_ANDROID_BINDER_IPC_RUST is not set\n",
            ),
            ("/proc/filesystems", "nodev\tsysfs\n"),
        ]);
        let host = Host::fixture(d.path(), FakeRunner::default());
        let f = check(&host);
        assert_eq!(status(&f, "binder.kernel"), Some(Status::Fail));
        assert_eq!(status(&f, "binder.dkms-collision"), None);
    }

    #[test]
    fn dkms_only_is_info() {
        let d = Tree::new(&[
            ("/proc/sys/kernel/osrelease", "6.6.1-1-lts\n"),
            (
                "/proc/config.gz",
                "# CONFIG_ANDROID_BINDER_IPC is not set\n",
            ),
            ("/proc/filesystems", "nodev\tbinder\n"),
            ("/proc/modules", "binder_linux 1 0 - Live 0x0\n"),
        ]);
        let host = Host::fixture(d.path(), FakeRunner::default());
        let f = check(&host);
        assert_eq!(status(&f, "binder.kernel"), Some(Status::Info));
        assert_eq!(status(&f, "binder.dkms-collision"), None);
    }

    #[test]
    fn real_path_mapping_is_rooted() {
        let host = Host::fixture("/nonexistent-root", FakeRunner::default());
        assert_eq!(
            host.path("/proc/cmdline"),
            Path::new("/nonexistent-root/proc/cmdline")
        );
    }
}
