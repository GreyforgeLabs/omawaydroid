mod checks;
mod host;
mod model;
#[cfg(test)]
mod testutil;

use clap::{Parser, Subcommand};
use model::{Report, Status};

#[derive(Parser)]
#[command(
    name = "droidsmith",
    version,
    about = "Make Waydroid just work on your Linux desktop"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Diagnose why Waydroid will not install, start, render or reach the network. Read-only.
    Doctor {
        /// Machine-readable output (stable schema; finding ids never change).
        #[arg(long)]
        json: bool,
        /// Only run these areas (repeatable), e.g. --only binder --only firewall.
        #[arg(long)]
        only: Vec<String>,
        /// Show passing and skipped checks too.
        #[arg(long, short)]
        verbose: bool,
    },
    /// List check areas.
    Checks,
}

fn main() {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Checks => {
            for (area, _) in checks::CHECKS {
                println!("{area}");
            }
        }
        Cmd::Doctor {
            json,
            only,
            verbose,
        } => {
            let host = host::Host::real();
            let report = Report::new(checks::run_all(&host, &only));
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&report).expect("report serializes")
                );
            } else {
                print_human(&report, verbose);
            }
            std::process::exit(report.exit_code());
        }
    }
}

fn print_human(report: &Report, verbose: bool) {
    let mut shown = 0;
    for f in &report.findings {
        if !verbose && matches!(f.status, Status::Pass | Status::Skip) {
            continue;
        }
        shown += 1;
        println!("[{}] {}  ({})", f.status.label(), f.title, f.id);
        if !f.detail.is_empty() {
            for line in f.detail.lines() {
                println!("    {line}");
            }
        }
        for e in &f.evidence {
            println!("    · {e}");
        }
        if let Some(fix) = &f.fix {
            println!(
                "    fix: {}{}",
                fix.summary,
                if fix.needs_root { " (needs root)" } else { "" }
            );
            for c in &fix.commands {
                println!("      $ {c}");
            }
        }
        for r in &f.refs {
            println!("    see: {r}");
        }
        println!();
    }
    let counts = |s: Status| report.findings.iter().filter(|f| f.status == s).count();
    if shown == 0 {
        println!("No problems found.");
    }
    println!(
        "droidsmith {}: {} fail, {} warn, {} info, {} pass, {} skipped",
        report.version,
        counts(Status::Fail),
        counts(Status::Warn),
        counts(Status::Info),
        counts(Status::Pass),
        counts(Status::Skip)
    );
}
