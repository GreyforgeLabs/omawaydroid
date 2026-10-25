use serde::Serialize;

/// Outcome of one finding. Ordered by severity so the worst can be taken with `max`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    /// Check could not run (missing permission, not applicable, Waydroid not installed yet).
    Skip,
    Pass,
    Info,
    Warn,
    Fail,
}

impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Status::Skip => "SKIP",
            Status::Pass => "PASS",
            Status::Info => "INFO",
            Status::Warn => "WARN",
            Status::Fail => "FAIL",
        }
    }
}

/// A concrete remedy. `doctor` only prints it; `fix` may apply it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Fix {
    pub summary: String,
    /// Shell commands, in order, exactly as a user would type them.
    pub commands: Vec<String>,
    pub needs_root: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Finding {
    /// Stable machine id, `area.name` (e.g. `binder.dkms-collision`). Never renamed once shipped.
    pub id: String,
    pub status: Status,
    pub title: String,
    pub detail: String,
    /// Observed facts that led to the verdict (paths, values, command output).
    pub evidence: Vec<String>,
    pub fix: Option<Fix>,
    /// Upstream issues or docs that describe the problem.
    pub refs: Vec<String>,
}

impl Finding {
    pub fn new(id: &str, status: Status, title: impl Into<String>) -> Self {
        Finding {
            id: id.to_string(),
            status,
            title: title.into(),
            detail: String::new(),
            evidence: Vec::new(),
            fix: None,
            refs: Vec::new(),
        }
    }

    pub fn detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = detail.into();
        self
    }

    pub fn evidence(mut self, line: impl Into<String>) -> Self {
        self.evidence.push(line.into());
        self
    }

    pub fn fix(mut self, summary: impl Into<String>, commands: &[&str], needs_root: bool) -> Self {
        self.fix = Some(Fix {
            summary: summary.into(),
            commands: commands.iter().map(|c| c.to_string()).collect(),
            needs_root,
        });
        self
    }

    pub fn reference(mut self, r: impl Into<String>) -> Self {
        self.refs.push(r.into());
        self
    }
}

#[derive(Debug, Serialize)]
pub struct Report {
    pub tool: &'static str,
    pub version: &'static str,
    pub worst: Status,
    pub findings: Vec<Finding>,
}

impl Report {
    pub fn new(findings: Vec<Finding>) -> Self {
        let worst = findings
            .iter()
            .map(|f| f.status)
            .max()
            .unwrap_or(Status::Pass);
        Report {
            tool: "droidsmith",
            version: env!("CARGO_PKG_VERSION"),
            worst,
            findings,
        }
    }

    /// 0 = healthy, 1 = warnings, 2 = failures.
    pub fn exit_code(&self) -> i32 {
        match self.worst {
            Status::Fail => 2,
            Status::Warn => 1,
            _ => 0,
        }
    }
}
