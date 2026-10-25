//! Everything a check may observe about the machine goes through `Host`, so every check
//! can be tested against a fixture tree and canned command output instead of the real box.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CmdOut {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl CmdOut {
    pub fn ok(&self) -> bool {
        self.code == 0
    }
}

pub trait Runner {
    /// Run `prog args...` without a shell. `None` when the program is missing or cannot start.
    fn run(&self, prog: &str, args: &[&str]) -> Option<CmdOut>;
}

pub struct RealRunner;

impl Runner for RealRunner {
    fn run(&self, prog: &str, args: &[&str]) -> Option<CmdOut> {
        let out = Command::new(prog)
            .args(args)
            .env("LC_ALL", "C")
            .stdin(std::process::Stdio::null())
            .output()
            .ok()?;
        Some(CmdOut {
            code: out.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        })
    }
}

/// Canned command output for tests, keyed by the full command line (`prog arg1 arg2`).
#[derive(Default)]
pub struct FakeRunner {
    pub outputs: HashMap<String, CmdOut>,
}

impl FakeRunner {
    pub fn with(mut self, cmdline: &str, code: i32, stdout: &str) -> Self {
        self.outputs.insert(
            cmdline.to_string(),
            CmdOut {
                code,
                stdout: stdout.to_string(),
                stderr: String::new(),
            },
        );
        self
    }
}

impl Runner for FakeRunner {
    fn run(&self, prog: &str, args: &[&str]) -> Option<CmdOut> {
        let mut key = prog.to_string();
        for a in args {
            key.push(' ');
            key.push_str(a);
        }
        self.outputs.get(&key).cloned()
    }
}

pub struct Host {
    /// Prefix for every absolute path read (`/` on a real machine, a fixture dir in tests).
    pub root: PathBuf,
    pub env: HashMap<String, String>,
    pub uid: u32,
    pub runner: Box<dyn Runner>,
}

impl Host {
    pub fn real() -> Self {
        Host {
            root: PathBuf::from("/"),
            env: std::env::vars().collect(),
            uid: unsafe_free_uid(),
            runner: Box::new(RealRunner),
        }
    }

    pub fn fixture(root: impl Into<PathBuf>, runner: FakeRunner) -> Self {
        Host {
            root: root.into(),
            env: HashMap::new(),
            uid: 1000,
            runner: Box::new(runner),
        }
    }

    /// Map an absolute host path into the (possibly fixture) root.
    pub fn path(&self, abs: &str) -> PathBuf {
        self.root.join(abs.trim_start_matches('/'))
    }

    pub fn exists(&self, abs: &str) -> bool {
        // symlink_metadata: a dangling /dev/binder symlink still counts as "present but broken"
        // for callers that check it separately; plain existence follows links.
        self.path(abs).exists()
    }

    pub fn read(&self, abs: &str) -> Option<String> {
        fs::read_to_string(self.path(abs)).ok()
    }

    /// Read a gzip file such as /proc/config.gz.
    pub fn read_gz(&self, abs: &str) -> Option<String> {
        let f = fs::File::open(self.path(abs)).ok()?;
        let mut s = String::new();
        flate2::read::GzDecoder::new(f)
            .read_to_string(&mut s)
            .ok()?;
        Some(s)
    }

    pub fn list(&self, abs: &str) -> Vec<String> {
        let mut v: Vec<String> = fs::read_dir(self.path(abs))
            .map(|rd| {
                rd.filter_map(|e| e.ok())
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        v.sort();
        v
    }

    /// Device id of the filesystem holding `abs`, walking up to the nearest existing ancestor.
    pub fn dev_of(&self, abs: &str) -> Option<u64> {
        let mut p = self.path(abs);
        loop {
            if let Ok(m) = fs::metadata(&p) {
                return Some(m.dev());
            }
            if !p.pop() || p == Path::new("") {
                return None;
            }
        }
    }

    pub fn env(&self, key: &str) -> Option<&str> {
        self.env
            .get(key)
            .map(|s| s.as_str())
            .filter(|s| !s.is_empty())
    }

    pub fn run(&self, prog: &str, args: &[&str]) -> Option<CmdOut> {
        self.runner.run(prog, args)
    }

    /// The invoking user's home directory (honours SUDO_USER when run as root via sudo).
    pub fn home(&self) -> Option<String> {
        if self.uid == 0 {
            if let Some(user) = self.env("SUDO_USER") {
                let passwd = self.read("/etc/passwd")?;
                return passwd
                    .lines()
                    .map(|l| l.split(':').collect::<Vec<_>>())
                    .find(|f| f.len() > 5 && f[0] == user)
                    .map(|f| f[5].to_string());
            }
        }
        self.env("HOME").map(|s| s.to_string())
    }
}

fn unsafe_free_uid() -> u32 {
    // /proc/self/status avoids a libc dependency for getuid().
    fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Uid:"))
                .and_then(|l| l.split_whitespace().nth(1).and_then(|v| v.parse().ok()))
        })
        .unwrap_or(u32::MAX)
}

/// Parse a kernel config (`CONFIG_X=y` / `# CONFIG_X is not set`) into a map. Unset options are absent.
pub fn parse_kconfig(text: &str) -> HashMap<String, String> {
    text.lines()
        .filter(|l| l.starts_with("CONFIG_"))
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.to_string(), v.trim_matches('"').to_string()))
        .collect()
}

/// Minimal INI reader for waydroid.cfg / waydroid_base.prop style files: section -> key -> value.
pub fn parse_ini(text: &str) -> HashMap<String, HashMap<String, String>> {
    let mut out: HashMap<String, HashMap<String, String>> = HashMap::new();
    let mut section = String::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            section = line[1..line.len() - 1].trim().to_string();
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            out.entry(section.clone())
                .or_default()
                .insert(k.trim().to_string(), v.trim().to_string());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kconfig_parses_set_and_skips_unset() {
        let m = parse_kconfig(
            "# CONFIG_ANDROID_BINDER_IPC is not set\nCONFIG_ANDROID_BINDER_IPC_RUST=y\nCONFIG_ANDROID_BINDER_DEVICES=\"\"\n",
        );
        assert_eq!(
            m.get("CONFIG_ANDROID_BINDER_IPC_RUST").map(String::as_str),
            Some("y")
        );
        assert_eq!(
            m.get("CONFIG_ANDROID_BINDER_DEVICES").map(String::as_str),
            Some("")
        );
        assert!(!m.contains_key("CONFIG_ANDROID_BINDER_IPC"));
    }

    #[test]
    fn ini_sections() {
        let m = parse_ini("[waydroid]\nbinder = anbox-binder\n[properties]\nro.x=1\n");
        assert_eq!(m["waydroid"]["binder"], "anbox-binder");
        assert_eq!(m["properties"]["ro.x"], "1");
    }
}
