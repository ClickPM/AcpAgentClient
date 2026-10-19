//! 进程面板（R10，画板 54）：本应用进程树的内存采样与归属（规格表 B）。非 ACP 消息、仅用于渲染。
//!
//! - 只看本应用 PID 的子孙树：已脱离进程树的孤儿不计入、看不到；
//! - 归属顺序：终端（`pty` 拉起的根 PID 及其子孙）→ agent 根 PID 及其子孙 → 其余子孙记 `other`，宿主进程本身记 `app`；
//! - PID 复用：子进程的 `start_time` 早于父进程的边不算父子；agent 子树里早于 agent 拉起时刻的进程不归给它。

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use serde_json::{Value, json};
use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System};

use crate::core::{lock, now_ms};

/// 口径：Windows 取专用内存（PrivateUsage），其它平台取常驻内存（RSS）。
#[cfg(windows)]
pub const METRIC: &str = "private";
#[cfg(not(windows))]
pub const METRIC: &str = "resident";

/// `start_time` 只到秒、agent 拉起时刻是毫秒：比对时给 2 s 余量，免得把刚拉起的根进程误判成复用。
const START_SLACK_SECS: u64 = 2;

/// 进程表里的一行（与 `sysinfo` 解耦，便于纯函数测试）。`start_time` 为 Unix 秒，0 = 拿不到。
#[derive(Debug, Clone)]
pub struct ProcInfo {
    pub pid: u32,
    pub parent: Option<u32>,
    pub name: String,
    pub bytes: u64,
    pub start_time: u64,
}

/// 一个活跃 agent 连接：根 PID、拉起时刻（Unix 毫秒）、它名下的终端 id。
#[derive(Debug, Clone)]
pub struct AgentProbe {
    pub agent_id: String,
    pub root_pid: Option<u32>,
    pub started_at: Option<i64>,
    pub terminal_ids: Vec<String>,
}

/// 一个未退出的终端（`TerminalManager::ids_with_pid`）。
#[derive(Debug, Clone)]
pub struct TerminalProbe {
    pub terminal_id: String,
    pub source: pty::TerminalSource,
    pub pid: Option<u32>,
}

/// 后一个进程是否可能是前一个的子进程：任一方 `start_time` 未知时不判复用。
fn started_after(child: u64, parent: u64) -> bool {
    child == 0 || parent == 0 || child >= parent
}

struct Tree<'a> {
    procs: HashMap<u32, &'a ProcInfo>,
    children: HashMap<u32, Vec<u32>>,
    in_tree: HashSet<u32>,
    claimed: HashSet<u32>,
}

impl<'a> Tree<'a> {
    fn new(table: &'a [ProcInfo], app_pid: u32) -> Self {
        let procs: HashMap<u32, &ProcInfo> = table.iter().map(|p| (p.pid, p)).collect();
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        for p in table {
            let Some(parent) = p.parent.and_then(|pp| procs.get(&pp)) else {
                continue;
            };
            if parent.pid != p.pid && started_after(p.start_time, parent.start_time) {
                children.entry(parent.pid).or_default().push(p.pid);
            }
        }
        for list in children.values_mut() {
            list.sort_unstable();
        }
        let mut tree = Self {
            procs,
            children,
            in_tree: HashSet::new(),
            claimed: HashSet::new(),
        };
        if tree.procs.contains_key(&app_pid) {
            let mut stack = vec![app_pid];
            while let Some(pid) = stack.pop() {
                if tree.in_tree.insert(pid) {
                    stack.extend(tree.children.get(&pid).into_iter().flatten().copied());
                }
            }
        }
        tree.claimed.insert(app_pid);
        tree
    }

    fn bytes(&self, pid: u32) -> u64 {
        self.procs.get(&pid).map_or(0, |p| p.bytes)
    }

    /// 从 `root` 起先序认领子树（跳过树外、已认领、早于 `min_start` 的节点及其子孙）：`(pid, depth)`。
    fn claim(&mut self, root: u32, min_start: Option<u64>) -> Vec<(u32, u32)> {
        let mut out = Vec::new();
        let mut stack = vec![(root, 0u32)];
        while let Some((pid, depth)) = stack.pop() {
            if !self.in_tree.contains(&pid) || self.claimed.contains(&pid) {
                continue;
            }
            let start = self.procs.get(&pid).map_or(0, |p| p.start_time);
            if start != 0 && min_start.is_some_and(|min| start < min) {
                continue;
            }
            self.claimed.insert(pid);
            out.push((pid, depth));
            if let Some(kids) = self.children.get(&pid) {
                stack.extend(kids.iter().rev().map(|&k| (k, depth + 1)));
            }
        }
        out
    }

    /// 终端：认领它的子树，回 `(pid, name, bytes)`；进程不在本应用树里时 `(pid 或 0, "", 0)`。
    fn claim_terminal(&mut self, pid: Option<u32>) -> (u32, String, u64) {
        let Some(pid) = pid else {
            return (0, String::new(), 0);
        };
        let claimed = self.claim(pid, None);
        if claimed.is_empty() {
            return (pid, String::new(), 0);
        }
        let name = self
            .procs
            .get(&pid)
            .map(|p| p.name.clone())
            .unwrap_or_default();
        (pid, name, claimed.iter().map(|&(p, _)| self.bytes(p)).sum())
    }
}

/// 纯函数：进程表 + 活跃 agent + 未退出终端 → `process_snapshot` JSON（docs/design.md § 3）。
pub fn attribute(
    table: &[ProcInfo],
    app_pid: u32,
    agents: &[AgentProbe],
    terminals: &[TerminalProbe],
    metric: &str,
    taken_at: i64,
) -> Value {
    let mut tree = Tree::new(table, app_pid);
    let app_bytes = if tree.in_tree.contains(&app_pid) {
        tree.bytes(app_pid)
    } else {
        0
    };

    let owner: HashMap<&str, usize> = agents
        .iter()
        .enumerate()
        .flat_map(|(i, a)| a.terminal_ids.iter().map(move |t| (t.as_str(), i)))
        .collect();
    let mut agent_terms: Vec<Vec<Value>> = vec![Vec::new(); agents.len()];
    let mut agent_term_bytes = vec![0u64; agents.len()];
    let (mut seg_items, mut seg_bytes) = (Vec::new(), 0u64);
    for t in terminals {
        let (pid, name, bytes) = tree.claim_terminal(t.pid);
        match owner.get(t.terminal_id.as_str()) {
            Some(&i) => {
                agent_term_bytes[i] += bytes;
                agent_terms[i].push(
                    json!({"terminalId": t.terminal_id, "pid": pid, "name": name, "bytes": bytes}),
                );
            }
            None => {
                seg_bytes += bytes;
                seg_items.push(json!({
                    "terminalId": t.terminal_id, "source": t.source.as_str(), "pid": pid, "name": name, "bytes": bytes,
                }));
            }
        }
    }

    let mut agents_bytes = 0u64;
    let mut agent_items = Vec::with_capacity(agents.len());
    for (i, a) in agents.iter().enumerate() {
        let min_start = a
            .started_at
            .map(|ms| (ms.max(0) as u64 / 1000).saturating_sub(START_SLACK_SECS));
        let claimed = a
            .root_pid
            .map(|root| tree.claim(root, min_start))
            .unwrap_or_default();
        let mut proc_bytes = 0u64;
        let processes: Vec<Value> = claimed
            .iter()
            .map(|&(pid, depth)| {
                let p = tree.procs[&pid];
                proc_bytes += p.bytes;
                json!({"pid": pid, "parentPid": p.parent.unwrap_or(0), "name": p.name, "bytes": p.bytes, "depth": depth})
            })
            .collect();
        let bytes = proc_bytes + agent_term_bytes[i];
        agents_bytes += bytes;
        agent_items.push(json!({
            "agentId": a.agent_id, "rootPid": a.root_pid.unwrap_or(0), "bytes": bytes, "startedAt": a.started_at,
            "processes": processes, "terminals": std::mem::take(&mut agent_terms[i]),
        }));
    }

    let other: u64 = tree
        .in_tree
        .iter()
        .filter(|p| !tree.claimed.contains(p))
        .map(|&p| tree.bytes(p))
        .sum();
    json!({
        "metric": metric,
        "takenAt": taken_at,
        "app": {"pid": app_pid, "bytes": app_bytes},
        "agents": agent_items,
        "terminals": {"count": seg_items.len(), "bytes": seg_bytes, "items": seg_items},
        "other": {"bytes": other},
        "total": app_bytes + agents_bytes + seg_bytes + other,
    })
}

/// 复用一个 `sysinfo::System`：每次只刷新进程表与内存，不全量重建。阻塞调用，异步侧放 `spawn_blocking`。
pub struct ProcessSampler {
    system: Mutex<System>,
}

impl Default for ProcessSampler {
    fn default() -> Self {
        Self::new()
    }
}

impl ProcessSampler {
    pub fn new() -> Self {
        Self {
            system: Mutex::new(System::new()),
        }
    }

    /// 刷新进程表，按规格表 B 归属后返回 `process_snapshot` JSON。
    pub fn snapshot(&self, agents: &[AgentProbe], terminals: &[TerminalProbe]) -> Value {
        let table = {
            let mut system = lock(&self.system);
            system.refresh_processes_specifics(
                ProcessesToUpdate::All,
                true,
                ProcessRefreshKind::nothing().with_memory(),
            );
            system
                .processes()
                .values()
                // Linux 下线程也列成进程，与所属进程共享内存，计入会重复。
                .filter(|p| p.thread_kind().is_none())
                .map(|p| ProcInfo {
                    pid: p.pid().as_u32(),
                    parent: p.parent().map(|pp| pp.as_u32()),
                    name: p.name().to_string_lossy().into_owned(),
                    bytes: metric_bytes(p),
                    start_time: p.start_time(),
                })
                .collect::<Vec<_>>()
        };
        attribute(
            &table,
            std::process::id(),
            agents,
            terminals,
            METRIC,
            now_ms(),
        )
    }
}

#[cfg(windows)]
fn metric_bytes(p: &sysinfo::Process) -> u64 {
    p.virtual_memory()
}

#[cfg(not(windows))]
fn metric_bytes(p: &sysinfo::Process) -> u64 {
    p.memory()
}

#[cfg(test)]
mod tests {
    use super::*;
    use pty::TerminalSource;

    const APP: u32 = 100;
    const T0: u64 = 1_000_000;

    fn p(pid: u32, parent: u32, name: &str, bytes: u64, start_time: u64) -> ProcInfo {
        ProcInfo {
            pid,
            parent: Some(parent),
            name: name.into(),
            bytes,
            start_time,
        }
    }

    fn base() -> Vec<ProcInfo> {
        vec![
            p(APP, 1, "acp_agent_client.exe", 1000, T0),
            p(1, 0, "System", 7, 1),
        ]
    }

    fn agent(id: &str, root: u32, started_s: u64, terms: &[&str]) -> AgentProbe {
        AgentProbe {
            agent_id: id.into(),
            root_pid: Some(root),
            started_at: Some((started_s * 1000) as i64),
            terminal_ids: terms.iter().map(|t| t.to_string()).collect(),
        }
    }

    fn term(id: &str, source: TerminalSource, pid: Option<u32>) -> TerminalProbe {
        TerminalProbe {
            terminal_id: id.into(),
            source,
            pid,
        }
    }

    fn n(v: &Value) -> u64 {
        v.as_u64().expect("number")
    }

    /// total = app + agents + terminals + other。
    fn assert_total(v: &Value) {
        let agents: u64 = v["agents"]
            .as_array()
            .expect("agents")
            .iter()
            .map(|a| n(&a["bytes"]))
            .sum();
        let sum =
            n(&v["app"]["bytes"]) + agents + n(&v["terminals"]["bytes"]) + n(&v["other"]["bytes"]);
        assert_eq!(n(&v["total"]), sum);
    }

    #[test]
    fn agent_owns_multi_level_subtree() {
        let mut t = base();
        t.extend([
            p(200, APP, "cmd.exe", 10, T0 + 5),
            p(201, 200, "node.exe", 100, T0 + 6),
            p(202, 201, "node.exe", 50, T0 + 7),
            p(203, 202, "rg.exe", 5, T0 + 8),
            p(300, APP, "git.exe", 3, T0 + 9),
        ]);
        let v = attribute(
            &t,
            APP,
            &[agent("claude-acp", 200, T0 + 5, &[])],
            &[],
            "private",
            42,
        );
        assert_eq!(v["metric"], "private");
        assert_eq!(v["takenAt"], 42);
        assert_eq!(v["app"], json!({"pid": APP, "bytes": 1000}));
        let a = &v["agents"][0];
        assert_eq!(a["agentId"], "claude-acp");
        assert_eq!(a["rootPid"], 200);
        assert_eq!(a["bytes"], 165);
        assert_eq!(a["startedAt"], (T0 + 5) * 1000);
        let procs = a["processes"].as_array().expect("processes");
        let shape: Vec<(u64, u64, u64)> = procs
            .iter()
            .map(|p| (n(&p["pid"]), n(&p["parentPid"]), n(&p["depth"])))
            .collect();
        assert_eq!(
            shape,
            vec![
                (200, APP as u64, 0),
                (201, 200, 1),
                (202, 201, 2),
                (203, 202, 3)
            ]
        );
        assert_eq!(procs[0]["name"], "cmd.exe");
        assert_eq!(v["other"]["bytes"], 3);
        assert_eq!(v["terminals"], json!({"count": 0, "bytes": 0, "items": []}));
        assert_eq!(v["total"], 1168);
        assert_total(&v);
    }

    #[test]
    fn agent_terminal_counts_toward_its_agent() {
        let mut t = base();
        t.extend([
            p(200, APP, "node.exe", 100, T0 + 5),
            p(400, APP, "pwsh.exe", 40, T0 + 20),
            p(401, 400, "cargo.exe", 60, T0 + 21),
        ]);
        let agents = [agent("pi-acp", 200, T0 + 5, &["term_3"])];
        let terms = [term("term_3", TerminalSource::Agent, Some(400))];
        let v = attribute(&t, APP, &agents, &terms, "private", 0);
        let a = &v["agents"][0];
        assert_eq!(a["bytes"], 200);
        assert_eq!(a["processes"].as_array().expect("processes").len(), 1);
        assert_eq!(
            a["terminals"],
            json!([{"terminalId": "term_3", "pid": 400, "name": "pwsh.exe", "bytes": 100}])
        );
        assert_eq!(v["terminals"]["count"], 0);
        assert_eq!(v["other"]["bytes"], 0);
        assert_total(&v);
    }

    #[test]
    fn local_and_auth_terminals_form_terminal_segment() {
        let mut t = base();
        t.extend([
            p(500, APP, "pwsh.exe", 30, T0 + 1),
            p(501, 500, "vim.exe", 20, T0 + 2),
            p(600, APP, "claude.exe", 70, T0 + 3),
        ]);
        let terms = [
            term("term_1", TerminalSource::Local, Some(500)),
            term("term_2", TerminalSource::Auth, Some(600)),
            term("term_9", TerminalSource::Local, None),
        ];
        let v = attribute(&t, APP, &[], &terms, "resident", 0);
        let seg = &v["terminals"];
        assert_eq!(seg["count"], 3);
        assert_eq!(seg["bytes"], 120);
        assert_eq!(
            seg["items"][0],
            json!({"terminalId": "term_1", "source": "local", "pid": 500, "name": "pwsh.exe", "bytes": 50})
        );
        assert_eq!(seg["items"][1]["source"], "auth");
        assert_eq!(seg["items"][1]["bytes"], 70);
        assert_eq!(
            seg["items"][2],
            json!({"terminalId": "term_9", "source": "local", "pid": 0, "name": "", "bytes": 0})
        );
        assert_eq!(v["agents"], json!([]));
        assert_total(&v);
    }

    #[test]
    fn agent_terminal_without_active_owner_goes_to_terminal_segment() {
        let mut t = base();
        t.push(p(400, APP, "bash", 40, T0 + 20));
        let terms = [term("term_5", TerminalSource::Agent, Some(400))];
        let v = attribute(&t, APP, &[], &terms, "private", 0);
        assert_eq!(v["terminals"]["items"][0]["source"], "agent");
        assert_eq!(v["terminals"]["bytes"], 40);
        assert_total(&v);
    }

    #[test]
    fn short_lived_descendants_go_to_other() {
        let mut t = base();
        t.extend([
            p(700, APP, "git.exe", 8, T0 + 1),
            p(701, 700, "git-remote-https.exe", 4, T0 + 2),
        ]);
        let v = attribute(&t, APP, &[], &[], "private", 0);
        assert_eq!(v["other"]["bytes"], 12);
        assert_eq!(v["total"], 1012);
        assert_total(&v);
    }

    #[test]
    fn orphans_and_foreign_processes_are_not_counted() {
        let mut t = base();
        t.extend([
            // 根进程已退出：父 PID 999 不存在。
            p(800, 999, "node.exe", 500, T0 + 3),
            // 别的进程的子孙。
            p(900, 1, "explorer.exe", 900, T0 - 50),
        ]);
        let v = attribute(
            &t,
            APP,
            &[agent("gone", 800, T0 + 3, &[])],
            &[],
            "private",
            0,
        );
        assert_eq!(v["total"], 1000);
        let a = &v["agents"][0];
        assert_eq!(a["bytes"], 0);
        assert_eq!(a["rootPid"], 800);
        assert_eq!(a["processes"], json!([]));
        assert_total(&v);
    }

    #[test]
    fn reused_pid_is_filtered_by_start_time() {
        let mut t = base();
        t.extend([
            // 挂在本应用下、但早于本应用启动：父 PID 被复用了，不是子进程。
            p(110, APP, "stale.exe", 300, T0 - 100),
            // agent 记录的根 PID 200 已被一个更早的本应用子进程占用（早于 agent 拉起时刻）。
            p(200, APP, "git.exe", 9, T0 + 1),
        ]);
        let v = attribute(
            &t,
            APP,
            &[agent("claude-acp", 200, T0 + 60, &[])],
            &[],
            "private",
            0,
        );
        let a = &v["agents"][0];
        assert_eq!(a["bytes"], 0);
        assert_eq!(a["processes"], json!([]));
        assert_eq!(v["other"]["bytes"], 9);
        assert_eq!(v["total"], 1009);
        assert_total(&v);
    }

    #[test]
    fn root_started_within_slack_still_belongs_to_agent() {
        let mut t = base();
        // start_time 只到秒：比记录的拉起时刻早 1 s 仍归给 agent。
        t.push(p(200, APP, "node.exe", 77, T0 + 9));
        let v = attribute(&t, APP, &[agent("a", 200, T0 + 10, &[])], &[], "private", 0);
        assert_eq!(v["agents"][0]["bytes"], 77);
        assert_total(&v);
    }

    #[test]
    fn missing_app_process_yields_zeroes() {
        let v = attribute(
            &[],
            APP,
            &[],
            &[term("term_1", TerminalSource::Local, Some(5))],
            "private",
            0,
        );
        assert_eq!(v["app"]["bytes"], 0);
        assert_eq!(v["terminals"]["items"][0]["bytes"], 0);
        assert_eq!(v["total"], 0);
    }

    /// 真进程：拉一个常驻子进程，它应出现在本进程子树里、按 agent 归属且 bytes > 0。
    #[test]
    fn real_child_process_is_attributed() {
        #[cfg(windows)]
        let mut cmd = std::process::Command::new("ping");
        #[cfg(windows)]
        cmd.args(["-n", "30", "127.0.0.1"]);
        #[cfg(not(windows))]
        let mut cmd = std::process::Command::new("sleep");
        #[cfg(not(windows))]
        cmd.arg("30");
        let started_at = now_ms();
        let mut child = cmd
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn child");
        let pid = child.id();
        let probe = AgentProbe {
            agent_id: "real".into(),
            root_pid: Some(pid),
            started_at: Some(started_at),
            terminal_ids: Vec::new(),
        };
        let v = ProcessSampler::new().snapshot(&[probe], &[]);
        let _ = child.kill();
        let _ = child.wait();

        assert_eq!(v["metric"], METRIC);
        assert_eq!(v["app"]["pid"], std::process::id());
        assert!(n(&v["app"]["bytes"]) > 0, "app bytes: {v}");
        let a = &v["agents"][0];
        let root = &a["processes"][0];
        assert_eq!(root["pid"], pid, "snapshot: {v}");
        assert_eq!(root["parentPid"], std::process::id());
        assert_eq!(root["depth"], 0);
        assert!(n(&root["bytes"]) > 0, "child bytes: {v}");
        assert!(n(&a["bytes"]) > 0);
        assert_total(&v);
    }
}
