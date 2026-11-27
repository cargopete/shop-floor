//! needs-me: list only what needs a human across some GitHub repos.
//!
//! It shells out to `gh` (so it uses whatever auth `gh` already has) and
//! sorts open PRs and issues into three piles:
//!
//! - decide: issues or PRs labelled `needs-decision`
//! - red:    PRs with a failing check or a merge conflict, and issues
//!   labelled `worker-failed` (a run that ended without a PR)
//! - merge:  PRs whose checks all passed, not drafts, nobody asked for changes
//!
//! Everything else (drafts, running checks, `worker-running`) is left alone,
//! because it doesn't need you yet.
//!
//! Follow-ups (open issues labelled `followup`, and open `- [ ]` entries in
//! a `.followups.md` at the root of the repo you're in) are backlog, not
//! something waiting on you: they get a count per repo under the list, and
//! `--followups` lists them. They never change the exit code of a normal run.

use serde_json::{json, Value};
use std::process::{Command, ExitCode};

const DECISION_LABEL: &str = "needs-decision";
const RUNNING_LABEL: &str = "worker-running";
const FAILED_LABEL: &str = "worker-failed";
const FOLLOWUP_LABEL: &str = "followup";
const FOLLOWUPS_FILE: &str = ".followups.md";
/// Most follow-up issues fetched per repo; a count at the cap shows as `N+`.
const FOLLOWUP_LIMIT: usize = 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
    Decide,
    Red,
    Merge,
    Followup,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Decide => "decide",
            Kind::Red => "red",
            Kind::Merge => "merge",
            Kind::Followup => "followup",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Item {
    kind: Kind,
    repo: String,
    number: u64,
    is_pr: bool,
    title: String,
    url: String,
    created: String,
    why: String,
}

impl Item {
    fn to_json(&self) -> Value {
        json!({
            "kind": self.kind.as_str(),
            "repo": self.repo,
            "number": self.number,
            "type": if self.is_pr { "pr" } else { "issue" },
            "title": self.title,
            "url": self.url,
            "created_at": self.created,
            "why": self.why,
        })
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Checks {
    Passed,
    Failed(String),
    Pending,
    None,
}

fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

fn has_label(v: &Value, name: &str) -> bool {
    v.get("labels")
        .and_then(Value::as_array)
        .is_some_and(|ls| ls.iter().any(|l| s(l, "name").eq_ignore_ascii_case(name)))
}

/// Summarise `statusCheckRollup` (a mix of CheckRun and StatusContext entries).
fn checks(pr: &Value) -> Checks {
    let Some(list) = pr.get("statusCheckRollup").and_then(Value::as_array) else {
        return Checks::None;
    };
    if list.is_empty() {
        return Checks::None;
    }
    let mut pending = false;
    for c in list {
        let name = if s(c, "name").is_empty() {
            s(c, "context")
        } else {
            s(c, "name")
        };
        // CheckRun: status + conclusion. StatusContext: state.
        let outcome = if c.get("state").is_some() {
            s(c, "state")
        } else {
            s(c, "conclusion")
        };
        match outcome.to_ascii_uppercase().as_str() {
            "SUCCESS" | "NEUTRAL" | "SKIPPED" => {}
            "FAILURE" | "ERROR" | "CANCELLED" | "TIMED_OUT" | "ACTION_REQUIRED"
            | "STARTUP_FAILURE" | "STALE" => return Checks::Failed(name.to_string()),
            _ => pending = true, // PENDING, EXPECTED, or a CheckRun that hasn't concluded
        }
    }
    if pending {
        Checks::Pending
    } else {
        Checks::Passed
    }
}

fn classify_pr(repo: &str, pr: &Value) -> Option<Item> {
    if pr.get("isDraft").and_then(Value::as_bool).unwrap_or(false) {
        return None;
    }
    let (kind, why) = if has_label(pr, DECISION_LABEL) {
        (Kind::Decide, format!("labelled {DECISION_LABEL}"))
    } else if has_label(pr, RUNNING_LABEL) {
        return None;
    } else if s(pr, "mergeable") == "CONFLICTING" {
        (Kind::Red, "merge conflict".to_string())
    } else {
        match checks(pr) {
            Checks::Failed(name) => (Kind::Red, format!("check failed: {name}")),
            Checks::Pending => return None,
            Checks::Passed | Checks::None if s(pr, "reviewDecision") == "CHANGES_REQUESTED" => {
                return None
            }
            Checks::Passed => (Kind::Merge, "all checks passed".to_string()),
            Checks::None => (Kind::Merge, "no checks configured".to_string()),
        }
    };
    // GitHub works out mergeability lazily, so right after the base branch
    // moves it says UNKNOWN. Don't let that pass for "no conflicts".
    let why = if kind == Kind::Merge && s(pr, "mergeable") == "UNKNOWN" {
        format!("{why}; GitHub hasn't finished checking for conflicts")
    } else {
        why
    };
    Some(Item {
        kind,
        repo: repo.to_string(),
        number: pr.get("number").and_then(Value::as_u64).unwrap_or(0),
        is_pr: true,
        title: s(pr, "title").to_string(),
        url: s(pr, "url").to_string(),
        created: s(pr, "createdAt").to_string(),
        why,
    })
}

fn classify_issue(repo: &str, issue: &Value) -> Item {
    let (kind, label) = if has_label(issue, DECISION_LABEL) {
        (Kind::Decide, DECISION_LABEL)
    } else {
        (Kind::Red, FAILED_LABEL)
    };
    Item {
        kind,
        repo: repo.to_string(),
        number: issue.get("number").and_then(Value::as_u64).unwrap_or(0),
        is_pr: false,
        title: s(issue, "title").to_string(),
        url: s(issue, "url").to_string(),
        created: s(issue, "createdAt").to_string(),
        why: format!("labelled {label}"),
    }
}

/// Decisions first, then red PRs, then merges; oldest first within each pile.
fn sort(items: &mut [Item]) {
    items.sort_by(|a, b| {
        (a.kind, &a.created, &a.repo, a.number).cmp(&(b.kind, &b.created, &b.repo, b.number))
    });
}

fn gh(args: &[&str]) -> Result<Value, String> {
    let out = Command::new("gh")
        .args(args)
        .output()
        .map_err(|e| format!("could not run gh ({e}); install it from https://cli.github.com"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    serde_json::from_slice(&out.stdout)
        .map_err(|e| format!("gh returned something that isn't JSON: {e}"))
}

fn list_prs(repo: &str) -> Result<Value, String> {
    gh(&[
        "pr",
        "list",
        "-R",
        repo,
        "--state",
        "open",
        "--limit",
        "200",
        "--json",
        "number,title,url,isDraft,labels,mergeable,reviewDecision,statusCheckRollup,createdAt",
    ])
}

fn any_unknown_mergeable(prs: &Value) -> bool {
    prs.as_array()
        .into_iter()
        .flatten()
        .any(|pr| s(pr, "mergeable") == "UNKNOWN")
}

fn collect(repo: &str) -> Result<Vec<Item>, String> {
    let mut items = Vec::new();
    let mut prs = list_prs(repo)?;
    // Asking is what makes GitHub compute it; one short retry usually settles it.
    if any_unknown_mergeable(&prs) {
        std::thread::sleep(std::time::Duration::from_secs(3));
        prs = list_prs(repo)?;
    }
    for pr in prs.as_array().into_iter().flatten() {
        items.extend(classify_pr(repo, pr));
    }
    // One query per label, because gh ANDs repeated --label flags.
    let mut seen = std::collections::HashSet::new();
    for label in [DECISION_LABEL, FAILED_LABEL] {
        let issues = gh(&[
            "issue",
            "list",
            "-R",
            repo,
            "--state",
            "open",
            "--label",
            label,
            "--limit",
            "200",
            "--json",
            "number,title,url,createdAt,labels",
        ])?;
        for issue in issues.as_array().into_iter().flatten() {
            if seen.insert(issue.get("number").and_then(Value::as_u64)) {
                items.push(classify_issue(repo, issue));
            }
        }
    }
    Ok(items)
}

fn list_followups(repo: &str) -> Result<Vec<Item>, String> {
    let issues = gh(&[
        "issue",
        "list",
        "-R",
        repo,
        "--state",
        "open",
        "--label",
        FOLLOWUP_LABEL,
        "--limit",
        &FOLLOWUP_LIMIT.to_string(),
        "--json",
        "number,title,url,createdAt",
    ])?;
    Ok(issues
        .as_array()
        .into_iter()
        .flatten()
        .map(|i| followup_item(repo, i))
        .collect())
}

fn followup_item(repo: &str, issue: &Value) -> Item {
    Item {
        kind: Kind::Followup,
        repo: repo.to_string(),
        number: issue.get("number").and_then(Value::as_u64).unwrap_or(0),
        is_pr: false,
        title: s(issue, "title").to_string(),
        url: s(issue, "url").to_string(),
        created: s(issue, "createdAt").to_string(),
        why: format!("labelled {FOLLOWUP_LABEL}"),
    }
}

/// Titles of the open entries (`- [ ] title`) in a `.followups.md`.
fn open_followups_in(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|l| {
            l.strip_prefix("- [ ] ")
                .or_else(|| l.strip_prefix("* [ ] "))
        })
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
        .collect()
}

/// The `.followups.md` at the root of the git repo you're in (or the current
/// directory outside git), if there is one.
fn local_followups_file() -> Option<std::path::PathBuf> {
    let root = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|r| !r.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::current_dir().ok())?;
    let path = root.join(FOLLOWUPS_FILE);
    path.is_file().then_some(path)
}

fn backlog_line(place: &str, n: usize) -> String {
    let what = if n == 1 { "follow-up" } else { "follow-ups" };
    let plus = if n >= FOLLOWUP_LIMIT { "+" } else { "" };
    format!("backlog: {n}{plus} open {what} in {place} (needs-me --followups)")
}

fn line(i: &Item) -> String {
    let tag = if i.is_pr { "PR" } else { "issue" };
    format!(
        "{:<6} {}#{} {}  ({}, {})\n       {}",
        i.kind.as_str(),
        i.repo,
        i.number,
        i.title,
        tag,
        i.why,
        i.url
    )
}

const USAGE: &str = "usage: needs-me [--json] [--next] [--followups] [owner/repo ...]

Lists only what needs you across the given repos (or $NEEDS_ME_REPOS,
space- or comma-separated, or the repo you're in):

  decide  issues and PRs labelled needs-decision
  red     PRs with a failing check or a merge conflict, and issues
          labelled worker-failed
  merge   green PRs waiting for someone to merge them

  --json       print a JSON array instead of text
  --next       print only the single oldest, most important item
  --followups  list the follow-up backlog instead: open issues labelled
               followup, plus open entries in .followups.md at the root
               of the repo you're in

Without --followups, the text output ends with a count of open
follow-ups per repo. They're backlog, so they don't change the exit code.

Uses your existing gh login. Exits 0 when nothing needs you (or, with
--followups, when there are none), 1 when something does, 2 on errors.";

fn main() -> ExitCode {
    let mut json_out = false;
    let mut next = false;
    let mut followups = false;
    let mut repos: Vec<String> = Vec::new();
    for a in std::env::args().skip(1) {
        match a.as_str() {
            "--json" => json_out = true,
            "--next" => next = true,
            "--followups" => followups = true,
            "-h" | "--help" => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            "-V" | "--version" => {
                println!("needs-me {}", env!("CARGO_PKG_VERSION"));
                return ExitCode::SUCCESS;
            }
            f if f.starts_with('-') => {
                eprintln!("needs-me: unknown flag {f}\n\n{USAGE}");
                return ExitCode::from(2);
            }
            r => repos.push(r.to_string()),
        }
    }
    if repos.is_empty() {
        if let Ok(env) = std::env::var("NEEDS_ME_REPOS") {
            repos = env
                .split(|c: char| c == ',' || c.is_whitespace())
                .filter(|r| !r.is_empty())
                .map(str::to_string)
                .collect();
        }
    }
    if repos.is_empty() {
        // Fall back to the repo you're standing in, as gh sees it.
        match gh(&["repo", "view", "--json", "nameWithOwner"]) {
            Ok(v) if !s(&v, "nameWithOwner").is_empty() => {
                repos.push(s(&v, "nameWithOwner").to_string())
            }
            // --followups can still read .followups.md, which is where
            // file-followup.sh writes when there's no GitHub remote.
            _ if followups && local_followups_file().is_some() => {}
            _ => {
                eprintln!("needs-me: no repos given and not in a GitHub repo\n\n{USAGE}");
                return ExitCode::from(2);
            }
        }
    }
    if let Some(bad) = repos
        .iter()
        .find(|r| r.split('/').count() != 2 || r.split('/').any(str::is_empty))
    {
        eprintln!("needs-me: '{bad}' isn't owner/repo");
        return ExitCode::from(2);
    }

    if followups {
        return run_followups(&repos, json_out, next);
    }

    let mut items = Vec::new();
    let mut failed = false;
    let mut ok_repos = Vec::new();
    for repo in &repos {
        match collect(repo) {
            Ok(mut found) => {
                items.append(&mut found);
                ok_repos.push(repo.clone());
            }
            Err(e) => {
                eprintln!("needs-me: {repo}: {e}");
                failed = true;
            }
        }
    }
    sort(&mut items);
    if next {
        items.truncate(1);
    }

    if json_out {
        let arr: Vec<Value> = items.iter().map(Item::to_json).collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&Value::Array(arr)).unwrap_or_default()
        );
    } else {
        if items.is_empty() {
            if !failed {
                println!("nothing needs you.");
            }
        } else {
            for i in &items {
                println!("{}", line(i));
            }
        }
        if !next {
            print_backlog(&ok_repos);
        }
    }

    if failed {
        ExitCode::from(2)
    } else if items.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

/// One count line per repo (and the local file) with open follow-ups. A
/// failure here only warns: the backlog is never what the run is about.
fn print_backlog(repos: &[String]) {
    let mut lines = Vec::new();
    for repo in repos {
        match list_followups(repo) {
            Ok(f) if !f.is_empty() => lines.push(backlog_line(repo, f.len())),
            Ok(_) => {}
            Err(e) => eprintln!("needs-me: {repo}: couldn't count follow-ups: {e}"),
        }
    }
    if let Some(path) = local_followups_file() {
        if let Ok(text) = std::fs::read_to_string(&path) {
            let n = open_followups_in(&text).len();
            if n > 0 {
                lines.push(backlog_line(&path.display().to_string(), n));
            }
        }
    }
    if !lines.is_empty() {
        println!();
        for l in lines {
            println!("{l}");
        }
    }
}

fn run_followups(repos: &[String], json_out: bool, next: bool) -> ExitCode {
    let mut items = Vec::new();
    let mut failed = false;
    for repo in repos {
        match list_followups(repo) {
            Ok(mut f) => items.append(&mut f),
            Err(e) => {
                eprintln!("needs-me: {repo}: {e}");
                failed = true;
            }
        }
    }
    sort(&mut items);
    let local: Vec<(String, String)> = local_followups_file()
        .and_then(|p| {
            let text = std::fs::read_to_string(&p).ok()?;
            let place = p.display().to_string();
            Some(
                open_followups_in(&text)
                    .into_iter()
                    .map(|t| (place.clone(), t))
                    .collect(),
            )
        })
        .unwrap_or_default();

    let mut out: Vec<Value> = items.iter().map(Item::to_json).collect();
    out.extend(local.iter().map(
        |(file, title)| json!({"kind": "followup", "type": "file", "file": file, "title": title}),
    ));
    if next {
        out.truncate(1);
    }

    if json_out {
        println!(
            "{}",
            serde_json::to_string_pretty(&Value::Array(out.clone())).unwrap_or_default()
        );
    } else if out.is_empty() {
        if !failed {
            println!("no open follow-ups.");
        }
    } else {
        let shown = out.len();
        for i in items.iter().take(shown) {
            println!(
                "followup {}#{} {}\n         {}",
                i.repo, i.number, i.title, i.url
            );
        }
        for (file, title) in local.iter().take(shown.saturating_sub(items.len())) {
            println!("followup {file}: {title}");
        }
    }

    if failed {
        ExitCode::from(2)
    } else if out.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pr(extra: Value) -> Value {
        let mut base = json!({
            "number": 7, "title": "t", "url": "u", "isDraft": false, "labels": [],
            "mergeable": "MERGEABLE", "reviewDecision": "", "createdAt": "2026-01-01T00:00:00Z",
            "statusCheckRollup": [
                {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS"}
            ]
        });
        for (k, v) in extra.as_object().unwrap() {
            base[k] = v.clone();
        }
        base
    }

    fn kind(v: Value) -> Option<Kind> {
        classify_pr("o/r", &v).map(|i| i.kind)
    }

    #[test]
    fn green_pr_is_ready_to_merge() {
        assert_eq!(kind(pr(json!({}))), Some(Kind::Merge));
    }

    #[test]
    fn pr_without_checks_is_ready_to_merge() {
        assert_eq!(
            kind(pr(json!({"statusCheckRollup": []}))),
            Some(Kind::Merge)
        );
    }

    #[test]
    fn failed_check_is_red_and_named() {
        let p = pr(json!({"statusCheckRollup": [
            {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS"},
            {"__typename": "CheckRun", "name": "clippy", "status": "COMPLETED", "conclusion": "FAILURE"}
        ]}));
        let item = classify_pr("o/r", &p).unwrap();
        assert_eq!(item.kind, Kind::Red);
        assert_eq!(item.why, "check failed: clippy");
    }

    #[test]
    fn failed_status_context_is_red() {
        let p = pr(json!({"statusCheckRollup": [
            {"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR"}
        ]}));
        assert_eq!(kind(p), Some(Kind::Red));
    }

    #[test]
    fn unknown_mergeability_is_flagged_not_trusted() {
        let item = classify_pr("o/r", &pr(json!({"mergeable": "UNKNOWN"}))).unwrap();
        assert_eq!(item.kind, Kind::Merge);
        assert!(item.why.contains("hasn't finished checking for conflicts"));
        assert!(any_unknown_mergeable(
            &json!([{"mergeable": "MERGEABLE"}, {"mergeable": "UNKNOWN"}])
        ));
        assert!(!any_unknown_mergeable(&json!([{"mergeable": "MERGEABLE"}])));
    }

    #[test]
    fn conflict_is_red() {
        assert_eq!(
            kind(pr(json!({"mergeable": "CONFLICTING"}))),
            Some(Kind::Red)
        );
    }

    #[test]
    fn running_checks_drafts_and_running_workers_are_skipped() {
        let running = pr(json!({"statusCheckRollup": [
            {"__typename": "CheckRun", "name": "test", "status": "IN_PROGRESS", "conclusion": ""}
        ]}));
        assert_eq!(kind(running), None);
        assert_eq!(kind(pr(json!({"isDraft": true}))), None);
        assert_eq!(
            kind(pr(json!({"labels": [{"name": "worker-running"}]}))),
            None
        );
    }

    #[test]
    fn changes_requested_stays_with_the_worker() {
        assert_eq!(
            kind(pr(json!({"reviewDecision": "CHANGES_REQUESTED"}))),
            None
        );
    }

    #[test]
    fn decision_label_wins_over_everything() {
        let p = pr(
            json!({"isDraft": false, "mergeable": "CONFLICTING", "labels": [{"name": "Needs-Decision"}]}),
        );
        assert_eq!(kind(p), Some(Kind::Decide));
    }

    #[test]
    fn issue_piles_follow_their_label() {
        let decide =
            json!({"number": 1, "labels": [{"name": "needs-decision"}, {"name": "worker-failed"}]});
        let failed = json!({"number": 2, "labels": [{"name": "worker-failed"}]});
        assert_eq!(classify_issue("o/r", &decide).kind, Kind::Decide);
        assert_eq!(classify_issue("o/r", &failed).kind, Kind::Red);
        assert_eq!(classify_issue("o/r", &failed).why, "labelled worker-failed");
    }

    #[test]
    fn followups_file_counts_only_open_entries() {
        let text = "# Follow-ups\n\n- [ ] Parser drops trailing comma\n  - where: `src/p.rs:12`\n- [x] Done one\n* [ ] Star bullet works too\n- [ ]   \n  - [ ] indented detail isn't an entry\n";
        assert_eq!(
            open_followups_in(text),
            vec!["Parser drops trailing comma", "Star bullet works too"]
        );
        assert!(open_followups_in("").is_empty());
    }

    #[test]
    fn followup_issues_are_their_own_pile() {
        let i = followup_item(
            "o/r",
            &json!({"number": 9, "title": "t", "url": "u", "createdAt": "2026-01-01"}),
        );
        assert_eq!(i.kind, Kind::Followup);
        assert_eq!(i.to_json()["kind"], "followup");
        assert!(Kind::Merge < Kind::Followup);
        assert_eq!(
            backlog_line("o/r", 1),
            "backlog: 1 open follow-up in o/r (needs-me --followups)"
        );
        assert_eq!(
            backlog_line("o/r", 3),
            "backlog: 3 open follow-ups in o/r (needs-me --followups)"
        );
        assert!(backlog_line("o/r", FOLLOWUP_LIMIT).contains(&format!("{FOLLOWUP_LIMIT}+ open")));
    }

    #[test]
    fn sorted_by_pile_then_age() {
        let mk = |kind, created: &str, n| Item {
            kind,
            repo: "o/r".into(),
            number: n,
            is_pr: true,
            title: String::new(),
            url: String::new(),
            created: created.into(),
            why: String::new(),
        };
        let mut v = vec![
            mk(Kind::Merge, "2026-01-01", 1),
            mk(Kind::Decide, "2026-03-01", 2),
            mk(Kind::Red, "2026-02-01", 3),
            mk(Kind::Decide, "2026-02-01", 4),
        ];
        sort(&mut v);
        let order: Vec<u64> = v.iter().map(|i| i.number).collect();
        assert_eq!(order, vec![4, 2, 3, 1]);
    }
}
