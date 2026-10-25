//! Fixture trees for check tests: a throwaway directory laid out like `/`.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::model::{Finding, Status};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

pub struct Tree {
    dir: PathBuf,
}

impl Tree {
    /// Create a tree from `(absolute path, contents)` pairs. Paths ending in `.gz` are gzipped;
    /// paths ending in `/` become empty directories.
    pub fn new(files: &[(&str, &str)]) -> Tree {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("droidsmith-test-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let t = Tree { dir };
        for (p, body) in files {
            t.write(p, body);
        }
        t
    }

    pub fn write(&self, p: &str, body: &str) {
        let full = self.dir.join(p.trim_start_matches('/'));
        if p.ends_with('/') {
            fs::create_dir_all(&full).unwrap();
            return;
        }
        fs::create_dir_all(full.parent().unwrap()).unwrap();
        if p.ends_with(".gz") {
            let mut e = flate2::write::GzEncoder::new(
                fs::File::create(&full).unwrap(),
                flate2::Compression::fast(),
            );
            e.write_all(body.as_bytes()).unwrap();
            e.finish().unwrap();
        } else {
            fs::write(&full, body).unwrap();
        }
    }

    pub fn path(&self) -> &Path {
        &self.dir
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

pub fn status(findings: &[Finding], id: &str) -> Option<Status> {
    findings.iter().find(|f| f.id == id).map(|f| f.status)
}
