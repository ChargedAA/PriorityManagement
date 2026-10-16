import json, os, subprocess, sys, glob
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
BIN = "/tmp/beattest"


ENERGY = []


def run(case):
    out = subprocess.run([BIN, os.path.join(DATA, case + ".wav")], capture_output=True, text=True, timeout=300).stdout
    beats, drops, sections, lost = [], [], [], []
    ENERGY.clear()
    for line in out.splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "BEAT":
            beats.append((float(p[1]), float(p[2]), int(p[3]), int(p[4]) if len(p) > 4 else -1, int(p[5]) if len(p) > 5 else 0))
        elif p[0] == "DROP":
            drops.append(float(p[1]))
        elif p[0] == "SECTION":
            sections.append(float(p[1]))
        elif p[0] == "LOST":
            lost.append(float(p[1]))
        elif p[0] == "ENERGY":
            ENERGY.append((float(p[1]), float(p[2]), float(p[3])))
    return beats, drops, sections, lost


def nearest_err(t, truth):
    i = np.searchsorted(truth, t)
    c = []
    if i > 0: c.append(t - truth[i - 1])
    if i < len(truth): c.append(t - truth[i])
    return min(c, key=abs)


def report(case):
    meta = json.load(open(os.path.join(DATA, case + ".json")))
    beats, drops, sections, lost = run(case)
    truth = np.array(meta["beats"])
    print(f"== {case}  (true bpm {meta['bpm']})")
    if not beats:
        print("   no beats emitted", "| drops", drops, "| sections", sections, "| lost", lost)
        return
    first = beats[0][0]
    bpms = [60.0 / b[1] for b in beats]
    print(f"   first beat at {first:.2f}s, {len(beats)} beats, median bpm {np.median(bpms):.1f}, lost at {lost}")
    if len(truth):
        errs = np.array([nearest_err(b[0], truth) for b in beats]) * 1000
        late = errs[len(errs) // 5:]
        print(f"   phase error ms: median {np.median(late):+.1f}, p90 abs {np.percentile(np.abs(late), 90):.1f}, within 40ms: {np.mean(np.abs(late) < 40) * 100:.0f}%")
    if "drops" in meta or drops:
        print("   drops:", [round(d, 2) for d in drops], "expected", meta.get("drops"))
    if sections or "sections" in meta:
        print("   sections:", [round(d, 2) for d in sections], "expected", meta.get("sections"))
    if "change" in meta:
        ch = meta["change"]
        after = [b for b in beats if b[0] > ch + 1]
        if after:
            print(f"   first beats after change at {after[0][0]:.2f}s, bpm {60.0 / after[0][1]:.1f}; late median bpm {np.median([60.0 / b[1] for b in beats if b[0] > ch + 8] or [0]):.1f}")
    if ENERGY:
        def win(a, b, k):
            v = [e[k] for e in ENERGY if a <= e[0] < b]
            return (min(v), float(np.mean(v)), max(v)) if v else (0, 0, 0)
        if case == "E_drop":
            g, bd, late, post = win(6, 15, 1), win(16.5, 19, 1), win(21, 24, 1), win(26, 38, 1)
            r_early, r_late, r_post = win(16, 18, 2), win(20, 24, 2), win(27, 38, 2)
            print(f"   intensity groove {g[1]:.2f} | breakdown {bd[1]:.2f} | late breakdown {late[1]:.2f} | after drop {post[1]:.2f}")
            print(f"   riser: early max {r_early[2]:.2f} | 20-24s max {r_late[2]:.2f} | after drop max {r_post[2]:.2f}")
            act = [e[0] for e in ENERGY if e[2] > 0.1]
            print(f"   riser above 0.1 from {min(act) if act else None} to {max(act) if act else None} (true riser 16 to 24)")
        else:
            i = win(8, 1000, 1); r = win(0, 1000, 2)
            print(f"   intensity after 8s: min {i[0]:.2f} mean {i[1]:.2f} max {i[2]:.2f} | riser max {r[2]:.2f}")
    if "downbeats" in meta:
        db = np.array(meta["downbeats"])
        known = [b for b in beats if b[4] > 0]
        if not known:
            print(f"   meter: never became known (true {meta['bpb']}/4)")
        else:
            mt = int(np.bincount([b[4] for b in known]).argmax())
            pred = [b[0] for b in known if b[3] == 0]
            hit = sum(1 for t in pred if abs(nearest_err(t, db)) * 1000 < 40)
            true_after = db[db > known[0][0] + 0.5]
            got = sum(1 for d in true_after if any(abs(t - d) < 0.04 for t in pred))
            print(f"   meter {mt} (true {meta['bpb']}), known from {known[0][0]:.1f}s, {len(known)}/{len(beats)} beats; "
                  f"downbeat precision {hit}/{len(pred)}, recall {got}/{len(true_after)}")
    if "silence" in meta:
        s0, s1 = meta["silence"]
        post = [b[0] for b in beats if b[0] > s1]
        print(f"   after silence ({s0}-{s1}): first beat at {post[0] if post else None}")


if __name__ == "__main__":
    cases = sys.argv[1:] or sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(DATA, "*.json")))
    for c in cases:
        report(c)
