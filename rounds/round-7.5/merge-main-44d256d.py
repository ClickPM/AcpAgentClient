# 备用：把 main 的 44d256d（Thread → Session 收敛）合进本分支时的解冲突脚本（2026-09-20 已跑通一次后按所有者指示撤回，等裁定再用）。
# 用法：在分支根 `git merge --no-ff --no-commit main` 出冲突后 `python rounds/round-7.5/merge-main-44d256d.py`，再 analyze / validate / 重出 main 基线比对。
"""Resolve the merge of main (Thread -> Session convergence, 44d256d) into the R7.5 branch.
Code files: take ours (:2) and replay main's renames. BACKLOG: ours lines with main's wording + main's new entries.
ROUNDS.md: keep both rows. Run from the worktree root."""
import io
import re
import subprocess

RENAMES = [
    # code identifiers (main 44d256d)
    ("thread_header.dart", "session_header.dart"),
    ("ThreadHeader", "SessionHeader"),
    ("threadHeader:", "sessionHeader:"),
    ("threadTitle", "sessionTitle"),
    ("threadMenuAnchor", "sessionMenuAnchor"),
    ("NewThreadEmpty", "NewSessionEmpty"),
    ("_openThreadMenu", "_openSessionMenu"),
    ("onThreads:", "onSessions:"),
    ("_addThread", "_addSession"),
    ("acp-thread:", "acp-session:"),
    ("'New $agentDisplayName Thread'", "'New $agentDisplayName Session'"),
    ("New Zed Agent Thread", "New Zed Agent Session"),
    ("New Codex Thread", "New Codex Session"),
    ("New codex Thread", "New codex Session"),
    ("`+` 的 Threads", "`+` 的 Sessions"),
    # UI wording in comments / reasons
    ("线程头", "会话头"),
    ("线程区", "会话区"),
    ("线程标题", "会话标题"),
]


def rename(s):
    for a, b in RENAMES:
        s = s.replace(a, b)
    return s


def ours(path):
    return subprocess.run(["git", "show", f":2:{path}"], capture_output=True, check=True).stdout.decode("utf-8")


def theirs(path):
    return subprocess.run(["git", "show", f":3:{path}"], capture_output=True, check=True).stdout.decode("utf-8")


def write(path, s):
    io.open(path, "w", encoding="utf-8", newline="").write(s)


# ---- code files in conflict: ours + renames
for p in ["lib/app/workbench_controller.dart", "lib/app/workbench_screen.dart", "lib/app/headless_run.dart",
          "test/app/workbench_wiring_test.dart"]:
    s = rename(ours(p))
    assert "<<<<<<<" not in s
    write(p, s)
    print("resolved", p)

# ---- my other lib/app files (no conflict, but carry the old wording): apply the same renames
for p in ["lib/app/thread_controller.dart", "lib/app/turn_controller.dart", "lib/app/shell_state.dart",
          "lib/app/workspace_state.dart", "lib/app/agents_state.dart", "lib/app/auth_state.dart",
          "lib/app/composer_state.dart", "lib/app/session_index.dart", "lib/app/guarded.dart"]:
    s = io.open(p, encoding="utf-8", newline="").read()
    s2 = rename(s)
    if s2 != s:
        write(p, s2)
        print("renamed in", p)

# ---- ROUNDS.md: keep both table rows (main's Thread → Session row, then ours)
p = "ROUNDS.md"
s = io.open(p, encoding="utf-8", newline="").read()
m = re.search(r"<<<<<<< HEAD\n(.*?)=======\n(.*?)>>>>>>> main\n", s, re.S)
assert m, "ROUNDS conflict block not found"
mine, main_side = m.group(1), m.group(2)
s = s[:m.start()] + main_side + mine + s[m.end():]
assert "<<<<<<<" not in s
write(p, s)
print("resolved ROUNDS.md (both rows)")

# ---- BACKLOG.md: ours lines with main's wording + main's new entries
p = "rounds/BACKLOG.md"
s = io.open(p, encoding="utf-8", newline="").read()
m = re.search(r"<<<<<<< HEAD\n(.*?)=======\n(.*?)>>>>>>> main\n", s, re.S)
assert m, "BACKLOG conflict block not found"
mine_lines = [rename(l) for l in m.group(1).split("\n") if l != ""]
main_lines = [l for l in m.group(2).split("\n") if l != ""]
extra = [t for t in main_lines if not any(o == t or o.startswith(t.rstrip()) or o.startswith(t.split(" (2026")[0]) for o in mine_lines)]
block = "\n".join(mine_lines + extra) + "\n"
s = s[:m.start()] + block + s[m.end():]
assert "<<<<<<<" not in s
write(p, s)
print("resolved BACKLOG.md: kept", len(mine_lines), "ours +", len(extra), "new from main")
for t in extra:
    print("   +", t[:90])
