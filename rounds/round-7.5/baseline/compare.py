"""R7.5 headless report equivalence: compare two report JSONs step by step, ignoring volatile fields.

usage: python compare.py <a.json> <b.json> [--show]
exit 0 = equivalent, 1 = differences (printed).

Calibrated 2026-09-20 on two baseline runs (f62520f): the only raw differences were `elapsedMs`,
the `taskkill` block (pids in value and message) and fake-agent's random `sess_<uuid>` (R6 `--sessions`).
`fetchedAt` is the registry cache timestamp; the background network refresh may rewrite it mid-run.
"""
import json
import re
import sys

VOLATILE_KEYS = {"elapsedMs", "taskkill", "fetchedAt"}
ID_PATTERNS = [
    re.compile(r"sess_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
    re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
]


def canon(value, ids):
    if isinstance(value, dict):
        return {k: canon(v, ids) for k, v in sorted(value.items()) if k not in VOLATILE_KEYS}
    if isinstance(value, list):
        return [canon(v, ids) for v in value]
    if isinstance(value, str):
        def sub(m):
            tok = m.group(0)
            if tok not in ids:
                ids[tok] = f"<uuid{len(ids) + 1}>"
            return ids[tok]
        for p in ID_PATTERNS:
            value = p.sub(sub, value)
        return value
    return value


def diff(a, b, path, out):
    if type(a) is not type(b):
        out.append(f"{path}: type {type(a).__name__} != {type(b).__name__}: {a!r} != {b!r}")
        return
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a:
                out.append(f"{path}.{k}: missing in A")
            elif k not in b:
                out.append(f"{path}.{k}: missing in B")
            else:
                diff(a[k], b[k], f"{path}.{k}", out)
    elif isinstance(a, list):
        if len(a) != len(b):
            out.append(f"{path}: length {len(a)} != {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{path}[{i}]", out)
    elif a != b:
        sa, sb = repr(a), repr(b)
        if len(sa) > 160:
            sa = sa[:160] + "..."
        if len(sb) > 160:
            sb = sb[:160] + "..."
        out.append(f"{path}: {sa} != {sb}")


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    show = "--show" in sys.argv
    with open(args[0], encoding="utf-8") as f:
        a = json.load(f)
    with open(args[1], encoding="utf-8") as f:
        b = json.load(f)
    ca = canon(a, {})
    cb = canon(b, {})
    out = []
    diff(ca, cb, "$", out)
    if show:
        print(json.dumps(ca, ensure_ascii=False, indent=1)[:4000])
    if out:
        print(f"DIFF {args[0]} vs {args[1]}: {len(out)} differences")
        for line in out:
            print("  " + line)
        sys.exit(1)
    print(f"EQUIVALENT {args[0]} vs {args[1]}")


if __name__ == "__main__":
    main()
