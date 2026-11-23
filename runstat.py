#!/usr/bin/env python3
"""
runstat.py - run the shell commands listed in a text file, one after another, and record
wall time, CPU time and memory for every command and for the whole run (with a time series).
Outputs are hash-checked (md5) only when you give hashes, or when you ask for an A-vs-B compare.

Linux only.  Requires: psutil  (matplotlib optional, for --plot)

COMMAND FILE
  * One command per line.  A line ending in an unescaped backslash continues on the next line.
    Otherwise `bash -n` decides: if the text so far is an incomplete command (open quote,
    `if` without `fi`, unfinished heredoc, ...) the next line is appended, exactly as a
    terminal would do.
  * Blank lines and lines starting with '#' are skipped.
  * Declare outputs with a directive line directly before the command (it is a comment for
    bash, so the file still runs as a plain script):

        #@ out a.clean.fq=9e107d9d372bb6826bd81d3542a419d6  a.json  sorted/*.bam
        fastp -i a.fq -o a.clean.fq \\
              -j a.json -w 8

    - path=md5  : output must exist and its md5 must equal the given value (path is literal).
    - path/glob : output must exist; it is hashed only in --compare mode (glob = shell-style
                  pattern, expanded AFTER the command finished, relative to the run directory).
    Every declared output that matches no file is an error (MISSING).

MODES
  runstat.py cmds.txt                     run once, verify the outputs that carry a hash
  runstat.py A.txt --compare B.txt        run A, then B (same file allowed), each in its own
                                          directory, and compare the outputs by md5.
                                          Commands are paired by order; their declared output
                                          names must be identical, and so must the files the
                                          patterns actually matched, otherwise it is an error.
                                          A/B directories hold symlinks to the entries of the
                                          current directory, so inputs resolve. Do not let a
                                          command overwrite a pre-existing input file.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

try:
    import psutil
except ImportError:  # pragma: no cover
    sys.exit("runstat.py needs psutil:  pip install psutil")

MB = 1 << 20
HEX32 = re.compile(r"^[0-9a-fA-F]{32}$")
TS_HEADER = ["t_s", "side", "cmd", "tree_cpu_pct", "tree_mem_mb", "procs", "threads",
             "sys_cpu_pct", "sys_mem_used_mb"]


# --------------------------------------------------------------------------- parsing
class Cmd:
    def __init__(self, idx, line, text, outs, syntax_error=""):
        self.idx, self.line, self.text, self.outs, self.syntax_error = idx, line, text, outs, syntax_error


def parse_directive(body, path, lineno):
    try:
        toks = shlex.split(body)
    except ValueError as e:
        sys.exit(f"{path}:{lineno}: bad #@ directive: {e}")
    if not toks or toks[0] != "out":
        sys.exit(f"{path}:{lineno}: unknown directive {body.strip()!r} (only '#@ out ...' exists)")
    outs = []
    for tok in toks[1:]:
        pat, sep, h = tok.rpartition("=")
        if sep and pat and HEX32.match(h):
            outs.append((pat, h.lower()))
        else:
            outs.append((tok, None))
    return outs


def odd_trailing_backslash(line):
    n = len(line) - len(line.rstrip("\\"))
    return n % 2 == 1


def check_complete(text):
    """-> ('ok'|'incomplete'|'error', message), using bash itself as the judge."""
    r = subprocess.run(["bash", "-n", "-c", text], capture_output=True, text=True)
    err = r.stderr.strip()
    if r.returncode == 0:
        if "here-document" in err and "end-of-file" in err:
            return "incomplete", err
        return "ok", ""
    if re.search(r"unexpected end of file|unexpected EOF", err):
        return "incomplete", err
    return "error", err


def parse_cmdfile(path):
    lines = Path(path).read_text().splitlines()
    cmds, pending, buf, start = [], [], [], 0
    for no, raw in enumerate(lines, 1):
        if not buf:
            s = raw.strip()
            if not s:
                continue
            if s.startswith("#@"):
                pending.extend(parse_directive(s[2:], path, no))
                continue
            if s.startswith("#"):
                continue
            start = no
        buf.append(raw)
        if odd_trailing_backslash(raw):
            continue
        state, msg = check_complete("\n".join(buf))
        if state == "incomplete":
            continue
        cmds.append(Cmd(len(cmds) + 1, start, "\n".join(buf), pending,
                        msg if state == "error" else ""))
        buf, pending = [], []
    if buf:
        cmds.append(Cmd(len(cmds) + 1, start, "\n".join(buf), pending,
                        f"incomplete command at end of file (started at line {start})"))
    return cmds


def preflight_compare(a, b):
    errs = []
    if len(a) != len(b):
        errs.append(f"A has {len(a)} commands but B has {len(b)}; they are paired by order")
        return errs
    for x, y in zip(a, b):
        pa, pb = sorted({p for p, _ in x.outs}), sorted({p for p, _ in y.outs})
        if pa != pb:
            errs.append(f"command {x.idx}: declared output names differ  A={pa}  B={pb}")
    return errs


# --------------------------------------------------------------------------- outputs
def md5_file(path, chunk=4 * MB):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def resolve_outputs(cwd, outs):
    """Match declared outputs to real files. Returns a list of entry dicts."""
    entries, by_path = [], {}
    base = glob.escape(str(cwd))
    for pat, exp in outs:
        hits = sorted({os.path.relpath(h, cwd)
                       for h in glob.glob(os.path.join(base, pat), recursive=True)
                       if os.path.isfile(h)})
        if not hits:
            entries.append(dict(path=pat, expected=exp, md5=None, status="MISSING"))
            continue
        if exp and len(hits) > 1:
            entries.append(dict(path=pat, expected=exp, md5=None, status="AMBIGUOUS"))
            continue
        for h in hits:
            if h in by_path:
                if exp:
                    by_path[h]["expected"] = exp
                continue
            e = dict(path=h, expected=exp, md5=None, status="FOUND")
            by_path[h] = e
            entries.append(e)
    return entries


def verify_entries(cwd, entries, hash_all):
    for e in entries:
        if e["status"] in ("MISSING", "AMBIGUOUS"):
            continue
        if e["expected"] or hash_all:
            e["md5"] = md5_file(os.path.join(cwd, e["path"]))
        if e["expected"]:
            e["status"] = "OK" if e["md5"] == e["expected"] else "MISMATCH"
        elif e["md5"]:
            e["status"] = "HASHED"


def command_status(exit_code, timed_out, files):
    if timed_out:
        return "TIMEOUT"
    if exit_code != 0:
        return f"EXIT_{exit_code}"
    st = {e["status"] for e in files}
    if st & {"MISSING", "AMBIGUOUS"}:
        return "MISSING_OUTPUT" if "MISSING" in st else "AMBIGUOUS_OUTPUT"
    if "MISMATCH" in st:
        return "HASH_MISMATCH"
    return "OK"


# --------------------------------------------------------------------------- sampler
class Sampler(threading.Thread):
    """Polls the command's process tree (bash + all descendants) every `interval` seconds."""

    def __init__(self, pid, idx, side, interval, pss, side_t0):
        super().__init__(daemon=True)
        self.pid, self.idx, self.side = pid, idx, side
        self.interval, self.pss, self.side_t0 = interval, pss, side_t0
        self._stop_evt = threading.Event()
        self._last_cpu = {}
        self.rows = []
        self.peak_mem = 0.0
        self.peak_procs = 0
        self.peak_threads = 0

    def stop(self):
        self._stop_evt.set()
        self.join()

    def _snapshot(self):
        try:
            root = psutil.Process(self.pid)
            procs = [root] + root.children(recursive=True)
        except psutil.Error:
            return None
        cpu_delta, mem, threads, alive = 0.0, 0, 0, 0
        for p in procs:
            try:
                with p.oneshot():
                    t = p.cpu_times()
                    cpu = t.user + t.system
                    m = p.memory_full_info().pss if self.pss else p.memory_info().rss
                    n = p.num_threads()
            except psutil.Error:
                continue
            cpu_delta += cpu - self._last_cpu.get(p.pid, 0.0)
            self._last_cpu[p.pid] = cpu
            mem += m
            threads += n
            alive += 1
        return (cpu_delta, mem, alive, threads) if alive else None

    def run(self):
        psutil.cpu_percent(None)
        t_prev, first = time.monotonic(), True
        while True:
            snap = self._snapshot()
            now = time.monotonic()
            if snap:
                cpu_delta, mem, procs, threads = snap
                dt = now - t_prev
                cpu_pct = 100.0 * cpu_delta / dt if (not first and dt > 0) else 0.0
                mem_mb = mem / MB
                self.rows.append([round(now - self.side_t0, 3), self.side, self.idx,
                                  round(cpu_pct, 1), round(mem_mb, 1), procs, threads,
                                  psutil.cpu_percent(None),
                                  round(psutil.virtual_memory().used / MB)])
                self.peak_mem = max(self.peak_mem, mem_mb)
                self.peak_procs = max(self.peak_procs, procs)
                self.peak_threads = max(self.peak_threads, threads)
            t_prev, first = now, False
            if self._stop_evt.wait(self.interval):
                break


# --------------------------------------------------------------------------- running
def run_one(side, cmd, cwd, logdir, args, side_t0, hash_all, ts_fh):
    rec = dict(side=side, idx=cmd.idx, line=cmd.line, cmd=cmd.text, exit_code=None,
               timed_out=False, start_s=round(time.monotonic() - side_t0, 3),
               wall_s=0.0, user_s=0.0, sys_s=0.0, cpu_s=0.0, cores_avg=0.0,
               peak_mem_mb=0.0, max_proc_rss_mb=0.0, peak_procs=0, peak_threads=0,
               samples=0, files=[], status="OK")
    if cmd.syntax_error:
        rec.update(status="SYNTAX_ERROR", error=cmd.syntax_error)
        return rec, []

    argv = ["bash"] + (["-o", "pipefail"] if args.pipefail else []) + ["-c", cmd.text]
    with open(logdir / f"{cmd.idx:03d}.out", "wb") as fo, open(logdir / f"{cmd.idx:03d}.err", "wb") as fe:
        t0 = time.monotonic()
        p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=fo, stderr=fe,
                             start_new_session=True)
        sampler = Sampler(p.pid, cmd.idx, side, args.interval, args.pss, side_t0)
        sampler.start()
        timer = None
        if args.timeout:
            def _kill():
                rec["timed_out"] = True
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            timer = threading.Timer(args.timeout, _kill)
            timer.start()
        _, status, ru = os.wait4(p.pid, 0)       # rusage = all threads + all waited descendants
        wall = time.monotonic() - t0
        if timer:
            timer.cancel()
        sampler.stop()
    code = os.waitstatus_to_exitcode(status)
    p.returncode = code

    cpu = ru.ru_utime + ru.ru_stime
    peak = sampler.peak_mem
    if not args.pss:
        peak = max(peak, ru.ru_maxrss / 1024)
    elif not sampler.rows:
        peak = ru.ru_maxrss / 1024
    rec.update(exit_code=code, wall_s=round(wall, 3), user_s=round(ru.ru_utime, 3),
               sys_s=round(ru.ru_stime, 3), cpu_s=round(cpu, 3),
               cores_avg=round(cpu / wall, 2) if wall > 0 else 0.0,
               peak_mem_mb=round(peak, 1), max_proc_rss_mb=round(ru.ru_maxrss / 1024, 1),
               peak_procs=sampler.peak_procs, peak_threads=sampler.peak_threads,
               samples=len(sampler.rows))

    if cmd.outs:
        rec["files"] = resolve_outputs(cwd, cmd.outs)
        verify_entries(cwd, rec["files"], hash_all)
    rec["status"] = command_status(code, rec["timed_out"], rec["files"])
    return rec, sampler.rows


def run_side(side, cmds, cwd, logdir, args, hash_all, ts_fh):
    logdir.mkdir(parents=True, exist_ok=True)
    side_t0 = time.monotonic()
    recs, rows = [], []
    for n, cmd in enumerate(cmds, 1):
        print(f"[{side} {n}/{len(cmds)}] line {cmd.line}: {short(cmd.text, 70)}",
              file=sys.stderr, flush=True)
        rec, r = run_one(side, cmd, cwd, logdir, args, side_t0, hash_all, ts_fh)
        recs.append(rec)
        rows.extend(r)
        for row in r:
            ts_fh.write("\t".join(map(str, row)) + "\n")
        ts_fh.flush()
        if rec["status"] != "OK":
            print(f"    -> {rec['status']}", file=sys.stderr, flush=True)
            if args.stop_on_error:
                print("    stopping (--stop-on-error)", file=sys.stderr)
                break
    return recs, rows, time.monotonic() - side_t0


def make_sandbox(root, base, outdir):
    root.mkdir(parents=True, exist_ok=True)
    rel = os.path.relpath(outdir, base)
    skip = rel.split(os.sep)[0] if not rel.startswith("..") else None
    for name in os.listdir(base):
        if name == skip:
            continue
        os.symlink(os.path.join(base, name), root / name)


# --------------------------------------------------------------------------- compare
def compare_sides(recs_a, recs_b):
    """-> (comparisons, per-command status dict)"""
    by_b = {r["idx"]: r for r in recs_b}
    comps, cmd_status = [], {}
    for a in recs_a:
        b = by_b.get(a["idx"])
        if b is None:
            continue
        bad = {"MISSING", "AMBIGUOUS"}
        if not a["files"] and not b["files"]:
            cmd_status[a["idx"]] = "-"
            continue
        if any(e["status"] in bad for e in a["files"] + b["files"]):
            cmd_status[a["idx"]] = "UNRESOLVED"
            continue
        ma = {e["path"]: e["md5"] for e in a["files"]}
        mb = {e["path"]: e["md5"] for e in b["files"]}
        if set(ma) != set(mb):
            cmd_status[a["idx"]] = "NAME_MISMATCH"
            comps.append(dict(idx=a["idx"], path=f"A:{sorted(ma)} B:{sorted(mb)}",
                              md5_A=None, md5_B=None, status="NAME_MISMATCH"))
            continue
        worst = "SAME"
        for path in sorted(ma):
            st = "SAME" if ma[path] == mb[path] else "DIFF"
            if st == "DIFF":
                worst = "DIFF"
            comps.append(dict(idx=a["idx"], path=path, md5_A=ma[path], md5_B=mb[path], status=st))
        cmd_status[a["idx"]] = worst
    return comps, cmd_status


# --------------------------------------------------------------------------- reporting
def short(text, n):
    one = " ".join(text.split())
    return one if len(one) <= n else one[: n - 1] + "…"


def vsum(rec):
    if not rec["files"]:
        return "-"
    c = Counter(e["status"] for e in rec["files"])
    return ",".join(f"{k}:{v}" for k, v in c.items())


def side_totals(recs, rows, elapsed):
    wall = sum(r["wall_s"] for r in recs)
    cpu = sum(r["cpu_s"] for r in recs)
    files = Counter(e["status"] for r in recs for e in r["files"])
    return dict(
        commands=len(recs), failed=sum(r["status"] != "OK" for r in recs),
        wall_s=round(wall, 2), elapsed_s=round(elapsed, 2), cpu_s=round(cpu, 2),
        cores_avg=round(cpu / wall, 2) if wall else 0.0,
        peak_mem_mb=max([r["peak_mem_mb"] for r in recs] or [0]),
        peak_procs=max([r["peak_procs"] for r in recs] or [0]),
        peak_threads=max([r["peak_threads"] for r in recs] or [0]),
        sys_cpu_peak_pct=max([x[7] for x in rows] or [0]),
        sys_mem_peak_mb=max([x[8] for x in rows] or [0]),
        files=dict(files))


def fmt_table(headers, rows, left=()):
    w = [max(len(str(h)), *(len(str(r[i])) for r in rows)) if rows else len(str(h))
         for i, h in enumerate(headers)]
    def line(cells):
        return "  ".join(str(c).ljust(w[i]) if (i in left) else str(c).rjust(w[i])
                         for i, c in enumerate(cells))
    return "\n".join([line(headers), "  ".join("-" * x for x in w)] + [line(r) for r in rows])


def totals_line(side, t):
    return (f"{side}: {t['commands']} commands, {t['failed']} not OK | wall {t['wall_s']}s "
            f"(elapsed {t['elapsed_s']}s) | cpu {t['cpu_s']}s | avg cores {t['cores_avg']} | "
            f"peak mem {t['peak_mem_mb']} MB | peak procs {t['peak_procs']}, threads {t['peak_threads']} | "
            f"system peak cpu {t['sys_cpu_peak_pct']}%, mem used {t['sys_mem_peak_mb']} MB")


def build_summary(args, recs, totals, comps, cmp_status, outdir):
    mem_label = "PSS" if args.pss else "RSS"
    out = []
    bar = "=" * 30
    mode = f"compare ({args.cmdfile} vs {args.compare})" if args.compare else f"single ({args.cmdfile})"
    out += [f"{bar} runstat summary {bar}",
            f"mode: {mode} | memory: {mem_label} summed over process tree | sampling: {args.interval}s",
            f"output dir: {outdir}", ""]
    if not args.compare:
        rows = [[r["idx"], r["line"], "-" if r["exit_code"] is None else r["exit_code"], r["wall_s"],
                 r["cpu_s"], r["cores_avg"], r["peak_mem_mb"], r["peak_procs"], r["peak_threads"],
                 vsum(r), r["status"], short(r["cmd"], 40)] for r in recs["A"]]
        out.append(fmt_table(["#", "line", "exit", "wall_s", "cpu_s", "cores", f"mem_MB({mem_label})",
                              "procs", "thr", "files", "status", "command"], rows, left=(9, 10, 11)))
    else:
        by_b = {r["idx"]: r for r in recs["B"]}
        rows = []
        for a in recs["A"]:
            b = by_b.get(a["idx"])
            if not b:
                continue
            ratio = f"{b['wall_s'] / a['wall_s']:.2f}" if a["wall_s"] else "-"
            st = "OK" if a["status"] == b["status"] == "OK" else f"A:{a['status']} B:{b['status']}"
            rows.append([a["idx"], f"{a['exit_code']}/{b['exit_code']}", a["wall_s"], b["wall_s"], ratio,
                         a["cpu_s"], b["cpu_s"], a["cores_avg"], b["cores_avg"],
                         a["peak_mem_mb"], b["peak_mem_mb"], cmp_status.get(a["idx"], "-"), st,
                         short(a["cmd"], 34)])
        out.append(fmt_table(["#", "exit A/B", "wall A", "wall B", "B/A", "cpu A", "cpu B", "cores A",
                              "cores B", f"mem A({mem_label})", f"mem B({mem_label})", "compare", "status",
                              "command"], rows, left=(11, 12, 13)))
    out += ["", "TOTALS"]
    for side, t in totals.items():
        out.append("  " + totals_line(side, t))

    out.append("")
    out.append("VERIFICATION")
    for side, t in totals.items():
        f = t["files"]
        out.append(f"  {side}: declared outputs {sum(f.values())} -> " +
                   (", ".join(f"{k} {v}" for k, v in sorted(f.items())) or "none"))
    if args.compare:
        c = Counter(cmp_status.values())
        out.append("  A vs B (per command): " + (", ".join(f"{k} {v}" for k, v in sorted(c.items())) or "none"))

    problems = []
    for side, rs in recs.items():
        for r in rs:
            if r["status"] == "OK":
                continue
            msg = f"  {side} #{r['idx']} (line {r['line']}): {r['status']}  {short(r['cmd'], 60)}"
            problems.append(msg)
            if r.get("error"):
                problems.append(f"      {r['error']}")
            for e in r["files"]:
                if e["status"] in ("MISMATCH", "MISSING", "AMBIGUOUS"):
                    problems.append(f"      {e['status']} {e['path']}"
                                    + (f"  expected {e['expected']} got {e['md5']}"
                                       if e["status"] == "MISMATCH" else ""))
    for c in comps:
        if c["status"] in ("DIFF", "NAME_MISMATCH"):
            problems.append(f"  compare #{c['idx']}: {c['status']}  {c['path']}"
                            + (f"\n      A {c['md5_A']}\n      B {c['md5_B']}" if c["status"] == "DIFF" else ""))
    if problems:
        out += ["", "PROBLEMS"] + problems
    ok = not problems
    out += ["", f"RESULT: {'ALL OK' if ok else 'PROBLEMS FOUND'}   (stderr/stdout of each command: "
                f"{outdir}/logs/)"]
    return "\n".join(out), ok


def write_reports(outdir, args, recs, totals, comps, cmp_status, summary):
    cols = ["side", "idx", "line", "exit_code", "status", "wall_s", "user_s", "sys_s", "cpu_s",
            "cores_avg", "peak_mem_mb", "max_proc_rss_mb", "peak_procs", "peak_threads", "samples", "cmd"]
    with open(outdir / "report.tsv", "w") as fh:
        fh.write("\t".join(cols) + "\n")
        for rs in recs.values():
            for r in rs:
                fh.write("\t".join(str(r[c]).replace("\n", " ⏎ ").replace("\t", " ") for c in cols) + "\n")
    with open(outdir / "verify.tsv", "w") as fh:
        fh.write("side\tcmd\tpath\texpected_md5\tmd5\tstatus\n")
        for rs in recs.values():
            for r in rs:
                for e in r["files"]:
                    fh.write(f"{r['side']}\t{r['idx']}\t{e['path']}\t{e['expected'] or ''}\t"
                             f"{e['md5'] or ''}\t{e['status']}\n")
        for c in comps:
            fh.write(f"A_vs_B\t{c['idx']}\t{c['path']}\t{c['md5_A'] or ''}\t{c['md5_B'] or ''}\t{c['status']}\n")
    with open(outdir / "report.json", "w") as fh:
        json.dump(dict(args=vars(args), commands=recs, totals=totals, comparisons=comps,
                       compare_status=cmp_status), fh, indent=2)
    (outdir / "summary.txt").write_text(summary + "\n")


def plot_timeseries(outdir, rows_by_side, recs):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed, skipping --plot", file=sys.stderr)
        return
    sides = [s for s in rows_by_side if rows_by_side[s]]
    if not sides:
        return
    fig, axes = plt.subplots(2, len(sides), figsize=(7 * len(sides), 6), squeeze=False, sharex="col")
    for j, side in enumerate(sides):
        rows = rows_by_side[side]
        t = [r[0] for r in rows]
        axes[0][j].plot(t, [r[3] for r in rows], lw=1.2, label="process tree")
        axes[0][j].plot(t, [r[7] for r in rows], lw=0.8, alpha=0.6, label="system total")
        axes[1][j].plot(t, [r[4] for r in rows], lw=1.2)
        axes[0][j].set_title(f"side {side}")
        axes[0][j].set_ylabel("CPU %  (100 = 1 core)")
        axes[1][j].set_ylabel("memory of tree (MB)")
        axes[1][j].set_xlabel("seconds since start")
        axes[0][j].legend(loc="upper right", fontsize=8)
        for r in recs[side]:
            for ax in (axes[0][j], axes[1][j]):
                ax.axvspan(r["start_s"], r["start_s"] + r["wall_s"], alpha=0.08 if r["idx"] % 2 else 0.0,
                           color="tab:blue")
            axes[0][j].text(r["start_s"], axes[0][j].get_ylim()[1], f"#{r['idx']}", fontsize=7, va="top")
    fig.tight_layout()
    fig.savefig(outdir / "timeseries.png", dpi=130)


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmdfile", help="text file with the commands (side A)")
    ap.add_argument("--compare", metavar="CMDFILE_B",
                    help="second command file; run after A and compare outputs by md5 (may equal CMDFILE)")
    ap.add_argument("--outdir", help="where to put logs/reports (default: runstat_<timestamp>)")
    ap.add_argument("--interval", type=float, default=0.5, help="sampling interval in seconds (default 0.5)")
    ap.add_argument("--pss", action="store_true",
                    help="measure memory as PSS (shared pages split fairly) instead of summed RSS; slower")
    ap.add_argument("--pipefail", action="store_true", help="run each command with 'bash -o pipefail'")
    ap.add_argument("--timeout", type=float, metavar="SEC", help="kill a command (whole process group) after SEC seconds")
    ap.add_argument("--stop-on-error", action="store_true", help="stop at the first command that is not OK")
    ap.add_argument("--plot", action="store_true", help="write timeseries.png (needs matplotlib)")
    args = ap.parse_args()

    if not sys.platform.startswith("linux"):
        sys.exit("runstat.py supports Linux only")
    if args.pss and not hasattr(psutil.Process().memory_full_info(), "pss"):
        sys.exit("--pss needs /proc/<pid>/smaps_rollup (Linux)")

    base = os.getcwd()
    outdir = Path(args.outdir or f"runstat_{datetime.now():%Y%m%d_%H%M%S}").resolve()
    outdir.mkdir(parents=True, exist_ok=True)

    cmds = {"A": parse_cmdfile(args.cmdfile)}
    if args.compare:
        cmds["B"] = parse_cmdfile(args.compare)
        errs = preflight_compare(cmds["A"], cmds["B"])
        if errs:
            sys.exit("ERROR (compare mode): output names must be the same on both sides:\n  " + "\n  ".join(errs))
    if not cmds["A"]:
        sys.exit(f"no commands found in {args.cmdfile}")
    for side, cs in cmds.items():
        for c in cs:
            if c.syntax_error:
                print(f"warning: {side} command at line {c.line} has a syntax problem: {c.syntax_error}",
                      file=sys.stderr)

    cwds = {"A": base}
    if args.compare:
        for side in ("A", "B"):
            make_sandbox(outdir / side, base, outdir)
            cwds[side] = str(outdir / side)

    recs, rows_by_side, totals = {}, {}, {}
    with open(outdir / "timeseries.tsv", "w") as ts_fh:
        ts_fh.write("\t".join(TS_HEADER) + "\n")
        for side, cs in cmds.items():
            recs[side], rows_by_side[side], elapsed = run_side(
                side, cs, cwds[side], outdir / "logs" / side, args, bool(args.compare), ts_fh)
            totals[side] = side_totals(recs[side], rows_by_side[side], elapsed)
            if args.stop_on_error and any(r["status"] != "OK" for r in recs[side]):
                break

    comps, cmp_status = ([], {})
    if args.compare and "B" in recs:
        comps, cmp_status = compare_sides(recs["A"], recs["B"])

    summary, ok = build_summary(args, recs, totals, comps, cmp_status, outdir)
    write_reports(outdir, args, recs, totals, comps, cmp_status, summary)
    if args.plot:
        plot_timeseries(outdir, rows_by_side, recs)
    print()
    print(summary)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
