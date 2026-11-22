"""Static import DAG of the project for issue #9 (pool planning). Reads only the `import` header lines.

usage: python3 -I exp-dag.py SRC_DIR DAG_TSV
Writes DAG_TSV: module, depth, project imports (space separated). Depth = longest chain of project
imports (a module with only Mathlib/core imports has depth 1). Light: one pass over the headers.
"""
import os, re, sys

src, out = sys.argv[1], sys.argv[2]
IMP = re.compile(r'^\s*(?:public\s+|private\s+)?(?:meta\s+)?import\s+(?:all\s+)?(.+)$')
mods = {}
for root, _, files in os.walk(src):
    for fn in files:
        if not fn.endswith('.lean'):
            continue
        p = os.path.join(root, fn)
        mod = os.path.relpath(p, src)[:-5].replace(os.sep, '.')
        ims = []
        with open(p, encoding='utf-8', errors='replace') as f:
            for i, line in enumerate(f):
                if i > 400:
                    break
                m = IMP.match(line)
                if m:
                    ims += [t for t in m.group(1).split() if not t.startswith('--')]
                elif line.strip() and not line.lstrip().startswith(('--', '/-', 'module', 'prelude')) and ims:
                    break
        mods[mod] = ims
proj = {m: [i for i in ims if i in mods] for m, ims in mods.items()}
depth = {}
for m in proj:                      # iterative longest-path
    if m in depth:
        continue
    stack = [(m, 0)]
    while stack:
        n, k = stack.pop()
        if n in depth:
            continue
        ps = proj[n]
        if k < len(ps):
            stack.append((n, k + 1))
            if ps[k] not in depth:
                stack.append((ps[k], 0))
        else:
            depth[n] = 1 + max((depth[p] for p in ps), default=0)
with open(out, 'w') as f:
    for m in sorted(proj):
        f.write(f"{m}\t{depth[m]}\t{' '.join(proj[m])}\n")
print(len(proj), 'modules; max depth', max(depth.values()), file=sys.stderr)
