#!/usr/bin/env python3
"""Run a command and report its wall time and peak memory, split into anonymous
(heap: what must fit in RAM or swap) and file-backed (mmapped .olean pages, which
the kernel can drop and re-read) memory, summed over the whole process tree.

  scripts/measure-peak.py [--interval S] [--out FILE.tsv] -- CMD ARGS...

Prints one line to stderr at the end and exits with the command's exit code.
Used by scripts/run-verification.sh and for the measurements in issue #1.
"""
import os, subprocess, sys, time

def tree(root):
    kids = {}
    for p in os.listdir('/proc'):
        if not p.isdigit():
            continue
        try:
            with open(f'/proc/{p}/stat') as f:
                ppid = int(f.read().rsplit(')', 1)[1].split()[1])
            kids.setdefault(ppid, []).append(int(p))
        except OSError:
            pass
    out, todo = [], [root]
    while todo:
        p = todo.pop(); out.append(p); todo.extend(kids.get(p, []))
    return out

def sample(pids):
    anon = filer = 0
    for p in pids:
        try:
            with open(f'/proc/{p}/status') as f:
                for line in f:
                    if line.startswith('RssAnon:'):
                        anon += int(line.split()[1])
                    elif line.startswith('RssFile:'):
                        filer += int(line.split()[1])
        except OSError:
            pass
    swap = 0
    with open('/proc/meminfo') as f:
        mi = {l.split(':')[0]: int(l.split()[1]) for l in f}
    swap = mi.get('SwapTotal', 0) - mi.get('SwapFree', 0)
    return anon, filer, swap, mi.get('MemAvailable', 0)

def main():
    a = sys.argv[1:]
    interval, out = 0.5, None
    while a and a[0] != '--':
        if a[0] == '--interval': interval = float(a[1]); a = a[2:]
        elif a[0] == '--out': out = a[1]; a = a[2:]
        else: sys.exit('usage: measure-peak.py [--interval S] [--out F] -- CMD...')
    cmd = a[1:]
    t0 = time.time()
    p = subprocess.Popen(cmd)
    pa = pf = ps = 0
    fh = open(out, 'a') if out else None
    n = 0
    while p.poll() is None:
        an, fi, sw, av = sample(tree(p.pid))
        pa, pf, ps = max(pa, an), max(pf, fi), max(ps, sw)
        if fh and n % max(1, int(10 / interval)) == 0:
            fh.write(f'{time.time()-t0:.0f}\t{an//1024}\t{fi//1024}\t{sw//1024}\t{av//1024}\n'); fh.flush()
        n += 1
        time.sleep(interval)
    dt = time.time() - t0
    sys.stderr.write(f'measure-peak: rc={p.returncode} wall={dt:.1f}s peak_anon={pa/1048576:.2f}GiB '
                     f'peak_file={pf/1048576:.2f}GiB peak_swap_used={ps/1048576:.2f}GiB cmd={" ".join(cmd)[:120]}\n')
    sys.exit(p.returncode)

if __name__ == '__main__':
    main()
