# R7.5：把 main@7c9c592（Thread → Session 收敛 44d256d、画板 07 深色模式 1420556、v1.2.0 7c9c592）合进本分支时的解冲突脚本
# （2026-09-20，所有者指示「在本分支把 main 合进来解冲突」）。
# 用法：在分支根 `git merge --no-ff --no-commit main` 出冲突后 `python rounds/round-7.5/merge-main-7c9c592.py`，
# 再 analyze / validate / 以 main 重出三份无头基线比对 / 第 3 轮审查。
#
# 解法：main 对组合根 / screen / headless / wiring 测试的改动全是改名与文案（threadTitle → sessionTitle 等，见 RENAMES），
# 深色模式那轮对 screen 的四处改动（appearance_prefs 与侧栏主题按钮）git 已自动合上、不在冲突块里。
# 所以每个冲突块取本分支这一侧再重放 main 的改名；改名同时施加到本轮拆出的九个文件与本轮改过的测试
# （搬走的代码在 main 那边改了名，git 合不到新文件上）。ROUNDS.md 两行都留；BACKLOG 以本分支行为准换 main 的措辞，
# 再补 main 新增的条目。
import io
import re
import subprocess

RENAMES = [
    # 44d256d：代码符号
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
    ("New <agent> Thread", "New <agent> Session"),
    ("New … Thread", "New … Session"),
    ("`+` 的 Threads", "`+` 的 Sessions"),
    # 44d256d：注释与文案
    ("线程头", "会话头"),
    ("线程区", "会话区"),
    ("线程标题", "会话标题"),
    # 画板 07 深色模式：font_prefs.dart → appearance_prefs.dart，FontPrefsController → AppearanceController（FontPrefs 模型类没改名）
    ("import 'font_prefs.dart';", "import 'appearance_prefs.dart';"),
    ("FontPrefsController", "AppearanceController"),
]

CONFLICT_CODE = [
    "lib/app/workbench_controller.dart",
    "lib/app/workbench_screen.dart",
    "lib/app/headless_run.dart",
    "test/app/workbench_wiring_test.dart",
]
# 本轮拆出的九个文件 + 本轮改过引用路径的测试（都不在冲突里，但带着 main 改掉的旧名）
MINE = [
    "lib/app/guarded.dart", "lib/app/shell_state.dart", "lib/app/workspace_state.dart", "lib/app/session_index.dart",
    "lib/app/agents_state.dart", "lib/app/auth_state.dart", "lib/app/composer_state.dart", "lib/app/turn_controller.dart",
    "lib/app/thread_controller.dart",
]
MARK = re.compile(r"^(<<<<<<< |=======|>>>>>>> )", re.M)


def rename(s):
    for a, b in RENAMES:
        s = s.replace(a, b)
    return s


def read(p):
    return io.open(p, encoding="utf-8", newline="").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="").write(s)


def resolve_blocks(s, pick):
    """把每个冲突块换成 pick(ours_lines, theirs_lines) 返回的行。"""
    out, i, lines, n = [], 0, s.split("\n"), 0
    while i < len(lines):
        if lines[i].startswith("<<<<<<< "):
            j = i
            while not lines[j].startswith("======="):
                j += 1
            k = j
            while not lines[k].startswith(">>>>>>> "):
                k += 1
            out.extend(pick(lines[i + 1:j], lines[j + 1:k]))
            n += 1
            i = k + 1
        else:
            out.append(lines[i])
            i += 1
    return "\n".join(out), n


def changed_tests():
    base = subprocess.run(["git", "merge-base", "HEAD", "MERGE_HEAD"], capture_output=True, check=True).stdout.decode().strip()
    names = subprocess.run(["git", "diff", "--name-only", base, "HEAD", "--", "test"], capture_output=True, check=True).stdout.decode().split()
    # main 把 thread_header_popover_test 改名成 session_header_popover_test，git 已把本分支的改动合到新名字上
    return [n.replace("thread_header_popover_test.dart", "session_header_popover_test.dart") for n in names]


# ---- 冲突的代码文件：每块取本分支侧，整文件重放改名
for p in CONFLICT_CODE:
    s, n = resolve_blocks(read(p), lambda ours, theirs: [rename(l) for l in ours])
    s = rename(s)
    assert not MARK.search(s), p
    write(p, s)
    print(f"resolved {p}: {n} blocks (ours + renames)")

# ---- 本轮的新文件与改过的测试：只重放改名
for p in MINE + [t for t in changed_tests() if t not in CONFLICT_CODE]:
    try:
        s = read(p)
    except FileNotFoundError:
        print("skip (gone):", p)
        continue
    s2 = rename(s)
    if s2 != s:
        write(p, s2)
        print("renamed in", p)

# ---- ROUNDS.md：两行都留（main 的「Thread → Session 收敛」行在前，本轮的行在后）
p = "ROUNDS.md"
s, n = resolve_blocks(read(p), lambda ours, theirs: theirs + [rename(l) for l in ours])
assert n == 1 and not MARK.search(s), p
write(p, s)
print("resolved ROUNDS.md: both rows kept")

# ---- BACKLOG.md：本分支的行换 main 的措辞，再补 main 新增的条目；两边对不上的行打印出来人看
p = "rounds/BACKLOG.md"
SUFFIX = re.compile(r" → \*\*R7\.5 拆分后的新家\*\*：.*?\(2026-09-20\)$|" r" → \*\*已完成（R7\.5，2026-09-20）\*\*：.*$")


def pick_backlog(ours, theirs):
    mine = [rename(l) for l in ours if l != ""]
    main = [l for l in theirs if l != ""]
    base_of = {SUFFIX.sub("", l).replace("- [x] ", "- [ ] ", 1): l for l in mine}
    extra = [t for t in main if t not in base_of]
    unmatched = [m for b, m in base_of.items() if b not in main and not m.startswith("- [ ] R7.5 ")]
    print(f"BACKLOG: kept {len(mine)} ours, +{len(extra)} new from main, {len(unmatched)} ours without a main twin")
    for t in extra:
        print("   + main:", t[:100])
    for m in unmatched:
        print("   ? ours (no twin on main, check wording):", m[:100])
    return mine + extra


s, n = resolve_blocks(read(p), pick_backlog)
assert n == 1 and not MARK.search(s), p
write(p, s)
print("resolved rounds/BACKLOG.md")
