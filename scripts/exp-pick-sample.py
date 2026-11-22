"""Pick a determinism sample for issue #9: shallow leaves of the restored module set.

usage: python3 -I exp-pick-sample.py SRC_DIR RESTORED_MODULES_TXT N > sample.txt
A leaf is a restored module that no other restored module imports, so deleting its outputs and
rebuilding it touches nothing else. Only modules whose project imports are all restored qualify.
Depth = longest chain of project imports (computed over all project sources). Lowest depth first,
ties broken by sha256 of the name (deterministic).
"""
import hashlib, os, re, sys
from functools import lru_cache

src, restored_txt, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
restored = set(l.strip() for l in open(restored_txt) if l.strip())
IMP = re.compile(r'^\s*(?:public\s+|private\s+)?(?:meta\s+)?import\s+(?:all\s+)?(.+)$')

def imports(mod):
    path = os.path.join(src, *mod.split('.')) + '.lean'
    out = []
    try:
        with open(path, encoding='utf-8') as f:
            for i, line in enumerate(f):
                if i > 400: break
                m = IMP.match(line)
                if m:
                    out += [t for t in m.group(1).split() if not t.startswith('--')]
    except FileNotFoundError:
        return None
    return out

def is_project(mod):
    return os.path.exists(os.path.join(src, *mod.split('.')) + '.lean')

sys.setrecursionlimit(100000)
@lru_cache(maxsize=None)
def depth(mod):
    ps = [i for i in (imports(mod) or []) if is_project(i)]
    return 1 + max((depth(p) for p in ps), default=0)

imported_by_restored = set()
proj_imps = {}
for m in restored:
    ims = imports(m)
    if ims is None:
        continue
    proj_imps[m] = [i for i in ims if is_project(i)]
    imported_by_restored.update(proj_imps[m])

leaves = [m for m in proj_imps if m not in imported_by_restored and all(i in restored for i in proj_imps[m])]
leaves.sort(key=lambda m: (depth(m), hashlib.sha256(m.encode()).hexdigest()))
pick = leaves[:n]
ds = [depth(m) for m in pick]
print(f"sample: {len(pick)} of {len(leaves)} eligible leaves (restored modules: {len(restored)}, with source: {len(proj_imps)}); "
      f"depth min {min(ds) if ds else '-'} max {max(ds) if ds else '-'}; "
      f"max restored depth {max((depth(m) for m in proj_imps), default=0)}", file=sys.stderr)
for m in pick:
    print(m)
