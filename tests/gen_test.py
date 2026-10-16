import numpy as np, wave, json, os

rng = np.random.default_rng(7)
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
os.makedirs(OUT, exist_ok=True)


def write_wav(path, x, sr):
    x = np.clip(x, -1, 1)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes((x * 32767).astype("<i2").tobytes())


def kick(sr):
    t = np.arange(int(0.28 * sr)) / sr
    f = 48 + 110 * np.exp(-t * 28)
    ph = 2 * np.pi * np.cumsum(f) / sr
    return np.sin(ph) * np.exp(-t * 11)


def snare(sr):
    t = np.arange(int(0.22 * sr)) / sr
    return rng.standard_normal(len(t)) * np.exp(-t * 22) * 0.55 + np.sin(2 * np.pi * 190 * t) * np.exp(-t * 28) * 0.35


def hat(sr):
    t = np.arange(int(0.06 * sr)) / sr
    return np.diff(rng.standard_normal(len(t) + 1)) * np.exp(-t * 90) * 0.22


def pad(sr, dur, level=0.12):
    t = np.arange(int(dur * sr)) / sr
    x = sum(np.sin(2 * np.pi * f * t + i) for i, f in enumerate([220, 277.18, 329.63, 440])) / 4
    return x * (0.8 + 0.2 * np.sin(2 * np.pi * 0.13 * t)) * level


def place(buf, ev, t, sr, gain=1.0):
    i = int(round(t * sr))
    if i < 0 or i >= len(buf):
        return
    n = min(len(ev), len(buf) - i)
    buf[i:i + n] += ev[:n] * gain


PATTERNS = {
    # beat position within a 4 beat bar -> instrument
    "house": [(b, "k") for b in (0, 1, 2, 3)] + [(b, "s") for b in (1, 3)] + [(b + 0.5, "h") for b in (0, 1, 2, 3)],
    "hiphop": [(0, "k"), (1.5, "k"), (2.25, "k"), (1, "s"), (3, "s")] + [(i * 0.25 + (0.06 if i % 2 else 0), "h") for i in range(16)],
    "dnb": [(0, "k"), (2.5, "k"), (1, "s"), (3, "s")] + [(i * 0.5, "h") for i in range(8)],
}


def groove(buf, sr, bpm, t0, t1, pattern, start_offset, gain=1.0):
    """Draw a groove into buf between t0 and t1. Beat grid is start_offset + k*60/bpm."""
    kk, ss, hh = kick(sr), snare(sr), hat(sr)
    spb = 60.0 / bpm
    bar = 0
    while True:
        bar_t = start_offset + bar * 4 * spb
        if bar_t > t1:
            break
        for pos, ins in PATTERNS[pattern]:
            t = bar_t + pos * spb
            if t0 <= t < t1:
                place(buf, {"k": kk, "s": ss, "h": hh}[ins], t, sr, gain * (1.0 if ins != "h" else 1.0))
        bar += 1
    truth = []
    k = 0
    while True:
        t = start_offset + k * spb
        if t >= t1:
            break
        if t >= t0:
            truth.append(round(t, 4))
        k += 1
    return truth


def finish(name, buf, sr, meta):
    peak = np.max(np.abs(buf))
    if peak > 0.95:
        buf = buf / peak * 0.95
    write_wav(os.path.join(OUT, name + ".wav"), buf, sr)
    with open(os.path.join(OUT, name + ".json"), "w") as f:
        json.dump(meta, f)
    print("wrote", name)


def base(sr, dur, padlevel=0.12):
    buf = np.zeros(int(dur * sr))
    buf += pad(sr, dur, padlevel)
    return buf


# A: house 128, 44.1k
sr = 44100; dur = 40
buf = base(sr, dur); truth = groove(buf, sr, 128, 0, dur, "house", 0.37)
finish("A_house128", buf.copy(), sr, {"bpm": 128, "beats": truth})
# D: same, very quiet (level independence)
finish("D_house128_quiet", buf * 0.02, sr, {"bpm": 128, "beats": truth})

# B: hiphop 90, 48k
sr = 48000; dur = 40
buf = base(sr, dur); truth = groove(buf, sr, 90, 0, dur, "hiphop", 0.21)
finish("B_hiphop90", buf, sr, {"bpm": 90, "beats": truth})

# C: dnb 174
sr = 44100; dur = 40
buf = base(sr, dur); truth = groove(buf, sr, 174, 0, dur, "dnb", 0.11)
finish("C_dnb174", buf, sr, {"bpm": 174, "beats": truth})

# E: drop. groove 0-16, breakdown 16-24, groove 24-44 (louder)
sr = 44100; dur = 44
buf = base(sr, dur)
truth = groove(buf, sr, 128, 0, 16, "house", 0.5)
t = np.arange(int(8 * sr)) / sr
riser = rng.standard_normal(len(t)) * (t / 8) ** 2 * 0.12
i0 = int(16 * sr); buf[i0:i0 + len(riser)] += riser
buf[i0:i0 + len(t)] += pad(sr, 8, 0.2)
truth += groove(buf, sr, 128, 24, dur, "house", 0.5, gain=1.25)
finish("E_drop", buf, sr, {"bpm": 128, "beats": truth, "drops": [24.0], "sections": [16.0, 24.0]})

# F: tempo change 100 -> 140 at 20 s
sr = 44100; dur = 42
buf = base(sr, dur)
truth = groove(buf, sr, 100, 0, 20, "house", 0.3)
truth += groove(buf, sr, 140, 20, dur, "house", 20.0)
finish("F_tempochange", buf, sr, {"bpm": 100, "beats": truth, "change": 20.0, "bpm2": 140})

# G: silence gap 18-22 s
sr = 44100; dur = 40
buf = base(sr, dur); truth = groove(buf, sr, 128, 0, dur, "house", 0.37)
buf[int(18 * sr):int(22 * sr)] = 0
truth = [t for t in truth if not (18 <= t < 22)]
finish("G_silence", buf, sr, {"bpm": 128, "beats": truth, "silence": [18.0, 22.0]})

# H: ambient, no drums at all
sr = 44100; dur = 30
buf = base(sr, dur, 0.2)
buf += rng.standard_normal(len(buf)) * 0.01
finish("H_ambient", buf, sr, {"bpm": 0, "beats": []})
