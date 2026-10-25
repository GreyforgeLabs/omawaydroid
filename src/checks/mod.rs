//! Doctor checks. Each module exposes `pub fn check(host: &Host) -> Vec<Finding>` and must be
//! read-only: no writes, no mounts, no modprobe, no network, nothing that needs a TTY.

use crate::host::Host;
use crate::model::Finding;

pub mod kernel;

pub type CheckFn = fn(&Host) -> Vec<Finding>;

/// Registry in display order. `area` is the prefix every finding id in that module uses.
pub const CHECKS: &[(&str, CheckFn)] = &[("binder", kernel::check)];

pub fn run_all(host: &Host, only: &[String]) -> Vec<Finding> {
    CHECKS
        .iter()
        .filter(|(area, _)| only.is_empty() || only.iter().any(|o| o == area))
        .flat_map(|(_, f)| f(host))
        .collect()
}
