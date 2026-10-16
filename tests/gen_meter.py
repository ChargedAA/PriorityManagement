import numpy as np, wave, json, os

rng = np.random.default_rng(11)
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
    return np.sin(2 * np.pi * np.cumsum(f) / sr) * np.exp(-t * 11)


def snare(sr):
    t = np.arange(int(0.22 * sr)) / sr
    return rng.standard_normal(len(t)) * np.exp(-t * 22) * 0.55 + np.sin(2 * np.pi * 190 * t) * np.exp(-t * 28) * 0.35


def hat(sr):
    t = np.arange(int(0.06 * sr)) / sr
    return np.diff(rng.standard_normal(len(t) + 1)) * np.exp(-t * 90) * 0.22


def crash(sr):
    t = np.arange(int(1.2 * sr)) / sr
    return np.diff(rng.standard_normal(len(t) + 1)) * np.exp(-t * 3) * 0.35


def tone(sr, f, dur, attack=0.01, decay=3.0):
    t = np.arange(int(dur * sr)) / sr
    x = np.sin(2 * np.pi * f * t) + 0.4 * np.sin(2 * np.pi * 2 * f * t) + 0.2 * np.sin(2 * np.pi * 3 * f * t)
    return x * np.minimum(1, t / attack) * np.exp(-t * decay)


def chord(sr, freqs, dur, level, attack=0.03, decay=0.0):
    t = np.arange(int(dur * sr)) / sr
    x = sum(np.sin(2 * np.pi * f * t + k) for k, f in enumerate(freqs)) / len(freqs)
    return x * np.minimum(1, t / attack) * np.minimum(1, np.maximum(dur - t, 0) / 0.05) * np.exp(-t * decay) * level


def place(buf, ev, t, sr, gain=1.0):
    i = int(round(t * sr))
    if i < 0 or i >= len(buf):
        return
    n = min(len(ev), len(buf) - i)
    buf[i:i + n] += ev[:n] * gain


ROOTS = [55.0, 73.42, 65.41, 49.0]
CHORDS = [[220, 277.2, 329.6], [293.7, 370, 440], [261.6, 329.6, 392], [196, 246.9, 293.7]]


def finish(name, buf, sr, bpm, bpb, off, dur):
    peak = np.max(np.abs(buf))
    if peak > 0.95:
        buf = buf / peak * 0.95
    write_wav(os.path.join(OUT, name + ".wav"), buf, sr)
    spb = 60.0 / bpm
    beats = [round(off + k * spb, 4) for k in range(int((dur - off) / spb) + 1) if off + k * spb < dur]
    downs = [round(off + b * bpb * spb, 4) for b in range(int((dur - off) / (bpb * spb)) + 1) if off + b * bpb * spb < dur]
    json.dump({"bpm": bpm, "beats": beats, "downbeats": downs, "bpb": bpb}, open(os.path.join(OUT, name + ".json"), "w"))
    print("wrote", name)


def bars(dur, off, spb, bpb):
    b = 0
    while off + b * bpb * spb < dur:
        yield b, off + b * bpb * spb
        b += 1


# K: pop 4/4, 110 bpm. Kick 1 and 3, snare 2 and 4, bass note on 1, chord change every bar, crash every 4 bars
sr, dur, bpm, off = 44100, 44, 110, 0.43
spb = 60 / bpm
buf = np.zeros(int(dur * sr))
kk, ss, hh, cr = kick(sr), snare(sr), hat(sr), crash(sr)
for b, tb in bars(dur, off, spb, 4):
    for pos in (0, 2): place(buf, kk, tb + pos * spb, sr)
    for pos in (1, 3): place(buf, ss, tb + pos * spb, sr)
    for h in range(8): place(buf, hh, tb + h * 0.5 * spb, sr)
    place(buf, tone(sr, ROOTS[b % 4], 1.6 * spb, decay=2.5), tb, sr, 0.6)
    place(buf, tone(sr, ROOTS[b % 4], 1.0 * spb, decay=3.5), tb + 2 * spb, sr, 0.3)
    place(buf, chord(sr, CHORDS[b % 4], 4 * spb, 0.14), tb, sr)
    if b % 4 == 0: place(buf, cr, tb, sr, 0.5)
finish("K_pop44", buf, sr, bpm, 4, off, dur)

# L: waltz 3/4, 96 bpm. Bass note on 1, chord stabs on 2 and 3, chord change every bar
sr, dur, bpm, off = 44100, 44, 96, 0.31
spb = 60 / bpm
buf = np.zeros(int(dur * sr))
hh = hat(sr)
for b, tb in bars(dur, off, spb, 3):
    place(buf, tone(sr, ROOTS[b % 4], 1.4 * spb, decay=2.2), tb, sr, 0.8)
    for pos in (1, 2):
        place(buf, chord(sr, [f * 2 for f in CHORDS[b % 4]], 0.28 * spb, 0.3, attack=0.004, decay=6), tb + pos * spb, sr)
    for pos in range(3): place(buf, hh, tb + pos * spb, sr, 0.7)
    place(buf, chord(sr, CHORDS[b % 4], 3 * spb, 0.1), tb, sr)
finish("L_waltz34", buf, sr, bpm, 3, off, dur)

# M: house 128, equal kicks, only the chords mark the bar
sr, dur, bpm, off = 44100, 44, 128, 0.37
spb = 60 / bpm
buf = np.zeros(int(dur * sr))
kk, hh = kick(sr), hat(sr)
for b, tb in bars(dur, off, spb, 4):
    for pos in range(4):
        place(buf, kk, tb + pos * spb, sr)
        place(buf, hh, tb + (pos + 0.5) * spb, sr)
    place(buf, chord(sr, CHORDS[b % 4], 4 * spb, 0.22, attack=0.02), tb, sr)
finish("M_house_chords", buf, sr, bpm, 4, off, dur)

# N: hip-hop 90, kick on 1, 2.5 and 3.25, snare on 2 and 4, 808 note on 1
sr, dur, bpm, off = 48000, 44, 90, 0.21
spb = 60 / bpm
buf = np.zeros(int(dur * sr))
kk, ss, hh = kick(sr), snare(sr), hat(sr)
for b, tb in bars(dur, off, spb, 4):
    for pos in (0, 1.5, 2.25): place(buf, kk, tb + pos * spb, sr, 1.0 if pos == 0 else 0.8)
    for pos in (1, 3): place(buf, ss, tb + pos * spb, sr)
    for i in range(16): place(buf, hh, tb + (i * 0.25 + (0.06 if i % 2 else 0)) * spb, sr)
    place(buf, tone(sr, ROOTS[(b // 2) % 4], 1.8 * spb, decay=2.0), tb, sr, 0.5)
    place(buf, chord(sr, CHORDS[(b // 2) % 4], 4 * spb, 0.1), tb, sr)
finish("N_hiphop_down", buf, sr, bpm, 4, off, dur)
