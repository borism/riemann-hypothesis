"""Before a merge (issue #9): are all imports of the modules to be merged available? Read-only.

usage: python3 -I rh-pool-closure-check.py DAG_TSV BUILD_TREE MANIFEST...
DAG_TSV from exp-dag.py over the sources of the live commit (for example /home/user/wt-gh/src, same src).
BUILD_TREE: the live .lake/build (only file names are read). MANIFEST: the batch manifests to be merged.
Prints every project import of a to-be-merged module that is neither in the tree nor in the manifests,
and exits 1 if there is any. Lake would build such a module itself, and the merged dependents stay
valid only if its bytes come out identical.
"""
import os, sys
dag_tsv, tree = sys.argv[1], sys.argv[2]
dag = {}
for l in open(dag_tsv):
    m, d, ims = l.rstrip('\n').split('\t'); dag[m] = ims.split()
def mod(p):
    return p[len('./lib/lean/'):-len('.olean')].replace('/', '.')
have = set()
root = os.path.join(tree, 'lib', 'lean')
for dp, _, fs in os.walk(root):
    for f in fs:
        if f.endswith('.olean'):
            have.add(os.path.relpath(os.path.join(dp, f[:-6]), root).replace(os.sep, '.'))
merged = set()
for man in sys.argv[3:]:
    for l in open(man, encoding='utf-8'):
        p = l.split('\t', 1)[0]
        if p.startswith('./lib/lean/') and p.endswith('.olean'):
            merged.add(mod(p))
avail = have | merged
missing = {}
for m in merged:
    for i in dag.get(m, []):
        if i not in avail:
            missing.setdefault(i, []).append(m)
print(f"modules in the tree: {len(have)}; to merge: {len(merged)}; unresolved imports: {len(missing)}")
for i, ds in sorted(missing.items()):
    print(f"  {i}  (imported by {len(ds)}, e.g. {ds[0]})")
sys.exit(1 if missing else 0)
