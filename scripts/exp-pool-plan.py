"""Pool planning for issue #9 (runs on a GitHub runner or, at nice 19, on the VM: it only reads text).

usage:
  exp-pool-plan.py wave DAG_TSV AVAILABLE_TXT N J SEED OUT_DIR
      Pick N modules that are not available but whose project imports all are (the "ready frontier"),
      deepest first, split them over J jobs by sha256(name) mod J, and pick a seeded spot-check sample
      (about 5%, at least 3, always including the deepest module of every job). Writes
      OUT_DIR/slice-<j>.txt, OUT_DIR/spot.txt, OUT_DIR/plan.json and prints a summary.
  exp-pool-plan.py deep DAG_TSV AVAILABLE_TXT OUT_DIR
      For the deep-module test: OUT_DIR/redo.txt = the 5 deepest available modules plus the 3 with the
      largest import closure (to delete and rebuild, byte-comparable with the VM); OUT_DIR/deep.txt =
      up to 2 modules of depth >= 80 whose closure has the fewest unbuilt modules (union <= 900).
  exp-pool-plan.py region DAG_TSV AVAILABLE_TXT INDEX_TSV J CAP S SEED HORIZON_H RATE OUT_DIR
      The pool planner used for real waves. The VM builds in DFS post-order from Main (checked against
      its log: 6,218 modules built, all within the first 6,252 positions of that order). Its position is
      estimated from INDEX (highest DFS position of a checkpointed module + RATE/min since the last
      shard), and the pool only takes modules at least HORIZON_H hours of VM work beyond it, so the VM
      cannot reach them before the next merge. Modules are taken in DFS order and assigned greedily so
      that every job's set is closed (each unbuilt import of a module is in the same job): no module is
      built twice. CAP modules per job, J jobs; S spot-check lists (about 5%, at least one per job,
      always the deepest module of each job).
DAG_TSV comes from exp-dag.py: module, depth, project imports.
"""
import hashlib, json, os, random, sys

def load(dag_tsv, avail_txt):
    dag = {}
    for l in open(dag_tsv):
        m, d, ims = l.rstrip('\n').split('\t')
        dag[m] = (int(d), ims.split())
    avail = set(x.strip() for x in open(avail_txt) if x.strip())
    return dag, avail

def closure(dag, m):
    seen, st = set(), [m]
    while st:
        for i in dag[st.pop()][1]:
            if i not in seen:
                seen.add(i); st.append(i)
    return seen

def h(s): return hashlib.sha256(s.encode()).hexdigest()

def wave(dag, avail, n, j, seed, out):
    ready = [m for m, (d, ims) in dag.items() if m not in avail and all(i in avail for i in ims)]
    ready.sort(key=lambda m: (-dag[m][0], h(m)))
    pick = ready[:n]
    slices = [[] for _ in range(j)]
    for m in pick:
        slices[int(h(m), 16) % j].append(m)
    rng = random.Random(seed)
    spot = set(max(s, key=lambda m: dag[m][0]) for s in slices if s)
    k = max(3, round(0.05 * len(pick)))
    rest = sorted(set(pick) - spot)
    spot |= set(rng.sample(rest, max(0, min(len(rest), k - len(spot)))))
    os.makedirs(out, exist_ok=True)
    for i, s in enumerate(slices):
        open(os.path.join(out, f'slice-{i}.txt'), 'w').write(''.join(x + '\n' for x in sorted(s)))
    open(os.path.join(out, 'spot.txt'), 'w').write(''.join(x + '\n' for x in sorted(spot)))
    plan = {'ready_frontier': len(ready), 'picked': len(pick), 'jobs': j, 'seed': seed,
            'slice_sizes': [len(s) for s in slices], 'spot': sorted(spot),
            'depths': {'min': min(dag[m][0] for m in pick), 'max': max(dag[m][0] for m in pick)}}
    json.dump(plan, open(os.path.join(out, 'plan.json'), 'w'), indent=1)
    print(json.dumps({k: v for k, v in plan.items() if k != 'spot'}), f"spot={len(spot)}")

def deep(dag, avail, out):
    av = [m for m in avail if m in dag]
    deepest = sorted(av, key=lambda m: (-dag[m][0], h(m)))[:5]
    heavy = sorted((m for m in av if m not in deepest), key=lambda m: (-len(closure(dag, m)), h(m)))[:3]
    redo = deepest + heavy
    cand = []
    for m, (d, _) in dag.items():
        if d >= 80:
            # unbuilt part of the closure only: the available set is closed under imports, so stop there
            miss, st, ok = set(), [m], True
            while st and ok:
                for i in dag[st.pop()][1]:
                    if i not in avail and i not in miss:
                        miss.add(i); st.append(i)
                        if len(miss) > 900:
                            ok = False; break
            if ok:
                cand.append((len(miss), d, m, miss))
    cand.sort()
    chosen, union = [], set()
    for miss_n, d, m, miss in cand:
        if len(union | miss) <= 900 and len(chosen) < 2:
            chosen.append(m); union |= miss
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'redo.txt'), 'w').write(''.join(x + '\n' for x in redo))
    open(os.path.join(out, 'deep.txt'), 'w').write(''.join(x + '\n' for x in chosen))
    for m in redo:
        print(f"redo {m} depth={dag[m][0]} closure={len(closure(dag, m))}")
    for m in chosen:
        c = closure(dag, m)
        print(f"deep {m} depth={dag[m][0]} closure={len(c)} unbuilt_in_closure={len(c - avail)}")
    print(f"deep targets: {len(chosen)}, unbuilt modules to build first: {len(union)}; candidates with <=900 unbuilt: {len(cand)}")

def dfs_order(dag):
    order, seen, st = [], set(), [('Main', 0)]
    while st:
        n, k = st.pop()
        if k == 0:
            if n in seen:
                continue
            seen.add(n)
        ims = dag[n][1]
        if k < len(ims):
            st.append((n, k + 1))
            if ims[k] not in seen:
                st.append((ims[k], 0))
        else:
            order.append(n)
    return order

def region(dag, avail, index_tsv, j, cap, s, seed, horizon_h, rate, out):
    import datetime
    order = dfs_order(dag); pos = {m: i for i, m in enumerate(order)}
    rows = [l.rstrip('\n').split('\t') for l in open(index_tsv)][1:]
    last = datetime.datetime.strptime(rows[-1][1], '%Y%m%dT%H%M%SZ').replace(tzinfo=datetime.timezone.utc)
    lag_min = (datetime.datetime.now(datetime.timezone.utc) - last).total_seconds() / 60
    idx_mods = set(x.strip() for x in open(os.path.join(out, 'index-modules.txt')))
    p_idx = max(pos[m] for m in idx_mods if m in pos)
    p_vm = int(p_idx + rate * lag_min)
    p0 = int(p_vm + rate * 60 * horizon_h)
    job, load = {}, [0] * j
    for m in order[p0:]:
        if m in avail:
            continue
        js, bad = set(), False
        for i in dag[m][1]:
            if i in avail:
                continue
            if i not in job:
                bad = True; break
            js.add(job[i])
        if bad or len(js) > 1:
            continue
        k = js.pop() if js else min(range(j), key=lambda x: load[x])
        if load[k] >= cap:
            continue
        job[m] = k; load[k] += 1
        if sum(load) >= j * cap:
            break
    slices = [[] for _ in range(j)]
    for m, k in job.items():
        slices[k].append(m)
    rng = random.Random(seed)
    spot = []
    for sl in slices:
        if not sl:
            continue
        deep = max(sl, key=lambda m: (dag[m][0], h(m)))
        rest = sorted(set(sl) - {deep})
        spot += [deep] + rng.sample(rest, max(0, min(len(rest), round(0.05 * len(sl)) - 1)))
    os.makedirs(out, exist_ok=True)
    for i, sl in enumerate(slices):
        open(os.path.join(out, f'slice-{i}.txt'), 'w').write(''.join(x + '\n' for x in sorted(sl)))
    spot.sort(key=h)
    for i in range(s):
        open(os.path.join(out, f'spot-{i}.txt'), 'w').write(''.join(x + '\n' for x in sorted(spot[i::s])))
    open(os.path.join(out, 'spot.txt'), 'w').write(''.join(x + '\n' for x in sorted(spot)))
    plan = {'dfs_pos_index_max': p_idx, 'index_lag_min': round(lag_min), 'vm_pos_est': p_vm, 'region_start': p0,
            'horizon_h': horizon_h, 'rate_per_min': rate, 'jobs': j, 'cap': cap, 'spot_jobs': s, 'seed': seed,
            'picked': len(job), 'slice_sizes': load, 'spot': len(spot),
            'dfs_span': [min(pos[m] for m in job), max(pos[m] for m in job)] if job else None,
            'depths': [min(dag[m][0] for m in job), max(dag[m][0] for m in job)] if job else None}
    if job:
        ahead = min(pos[m] for m in job) - p_vm
        now = datetime.datetime.now(datetime.timezone.utc)
        plan['planned_utc'] = now.strftime('%Y-%m-%dT%H:%MZ')
        plan['vm_hours_ahead'] = round(ahead / rate / 60, 1)
        # the VM reaches this wave's first module (in its DFS order) at about this time; merge before it
        plan['merge_by_utc'] = (now + datetime.timedelta(minutes=ahead / rate)).strftime('%Y-%m-%dT%H:%MZ')
    json.dump(plan, open(os.path.join(out, 'plan.json'), 'w'), indent=1)
    print(json.dumps(plan))

if __name__ == '__main__':
    mode = sys.argv[1]
    dag, avail = load(sys.argv[2], sys.argv[3])
    if mode == 'wave':
        wave(dag, avail, int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), sys.argv[7])
    elif mode == 'region':
        a = sys.argv
        region(dag, avail, a[4], int(a[5]), int(a[6]), int(a[7]), int(a[8]), float(a[9]), float(a[10]), a[11])
    elif mode == 'deep':
        deep(dag, avail, sys.argv[4])
