"""给宣传片和使用视频合成配乐和音效（numpy 合成，不用外部素材）。
用法：python3 audio.py promo out.wav     # 66 秒宣传片（Windows 上用 python）
      python3 audio.py usage out.wav <时长秒> <事件json>   # 使用视频：柔和铺底 + App 自带提示音
"""
import json
import subprocess
import sys
import numpy as np

SR = 48000


def env_adsr(n, a, r):
    e = np.ones(n)
    na, nr = int(a * SR), int(r * SR)
    if na: e[:na] = np.linspace(0, 1, na)
    if nr: e[-nr:] *= np.linspace(1, 0, nr)
    return e


def lowpass(x, cutoff):
    # 一阶低通，跑两遍更柔
    a = np.exp(-2 * np.pi * cutoff / SR)
    from scipy.signal import lfilter  # noqa
    return lfilter([1 - a], [1, -a], lfilter([1 - a], [1, -a], x))


def lp(x, cutoff):
    try:
        return lowpass(x, cutoff)
    except ImportError:
        # 没有 scipy：用 FFT 做低通
        X = np.fft.rfft(x)
        f = np.fft.rfftfreq(len(x), 1 / SR)
        X *= 1 / (1 + (f / cutoff) ** 4)
        return np.fft.irfft(X, len(x))


def note(f, dur, amp=0.2, a=1.5, r=2.0, det=0.004, bright=1800):
    n = int(dur * SR)
    t = np.arange(n) / SR
    s = np.zeros(n)
    for d in (-det, 0, det):
        ff = f * (1 + d)
        # 柔和的锯齿（前几次谐波）
        for k in range(1, 7):
            s += np.sin(2 * np.pi * ff * k * t + k * 0.3) / k * (0.75 ** k)
    s = lp(s, bright)
    return s * env_adsr(n, a, r) * amp / 3


def hz(m):
    return 440 * 2 ** ((m - 69) / 12)


def place(buf, x, at, gain=1.0):
    i = int(at * SR)
    if i >= len(buf): return
    j = min(len(buf), i + len(x))
    buf[i:j] += x[: j - i] * gain


def load_caf(path, rate=SR):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 'f32le', '-ac', '1', '-ar', str(rate), '-'], capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


import os
SOUNDS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ios', 'NightEscort', 'Resources', 'Sounds') + os.sep


def rain(n, amp):
    rng = np.random.default_rng(3)
    x = rng.standard_normal(n)
    x = lp(x, 5000) - lp(x, 600)
    # 偶尔的雨滴
    drops = np.zeros(n)
    for i in rng.integers(0, n, n // 3000):
        L = 400
        if i + L < n: drops[i:i + L] += rng.standard_normal(L) * np.exp(-np.arange(L) / 60) * 0.6
    return (x * 0.5 + lp(drops, 4000)) * amp


def whoosh(dur=1.2, amp=0.25):
    n = int(dur * SR)
    rng = np.random.default_rng(9)
    x = rng.standard_normal(n)
    cut = np.linspace(300, 4000, n)
    out = np.zeros(n)
    # 分段低通近似扫频
    seg = n // 12
    for s in range(12):
        a, b = s * seg, min(n, (s + 1) * seg)
        out[a:b] = lp(x[a:b], cut[a])
    e = np.sin(np.linspace(0, np.pi, n)) ** 2
    return out * e * amp


def thump(amp=0.5):
    n = int(0.35 * SR)
    t = np.arange(n) / SR
    f = 55 * np.exp(-t * 6) + 38
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9) * amp


def chord(buf, at, dur, notes, amp=0.16, bright=1600, a=1.2, r=1.8):
    for m in notes:
        place(buf, note(hz(m), dur, amp, a=a, r=r, bright=bright), at)


def promo(out):
    D = 66.0
    n = int(D * SR)
    L = np.zeros(n)
    # 雨：街景段落更大，地图/演播室段落小
    rn = rain(n, 0.05)
    mask = np.ones(n) * 0.35
    for a, b in [(0, 20), (26.5, 39), (48, 51.6), (55, 61)]:
        mask[int(a * SR):int(b * SR)] = 1.0
    mask = lp(mask, 2)
    L += rn * mask
    # 和声：Dm - Bb - F - C（平静）→ Dm 低音持续（紧张）→ F - C - Bb - F（到家）
    calm = [(0, 6, [50, 57, 62, 65]), (6, 6, [46, 53, 58, 62]), (12, 8, [41, 53, 57, 60]), (20, 6.5, [48, 55, 60, 64]), (26.5, 5.5, [50, 57, 62, 65])]
    for at, d, ns in calm:
        chord(L, at, d + 1.5, ns, amp=0.11)
    # 紧张：低音 D + 不协和的 Eb，心跳越来越快
    chord(L, 32, 23.5, [38, 50], amp=0.13, bright=700, a=2.5, r=2)
    chord(L, 36, 19, [63], amp=0.05, bright=1200, a=3, r=2)
    t = 33.0
    gap = 0.95
    while t < 54.5:
        place(L, thump(0.45), t)
        place(L, thump(0.3), t + 0.22)
        t += gap
        gap = max(0.55, gap * 0.985)
    # 到家：温暖的大和弦
    chord(L, 55, 6.5, [41, 53, 57, 60, 65], amp=0.12, bright=2200)
    chord(L, 61, 5, [46, 53, 58, 62, 65], amp=0.12, bright=2400, r=3)
    # 转场呼声
    for at in [11.6, 19.6, 26.1, 31.6, 38.6, 47.6, 54.6, 60.6]:
        place(L, whoosh(), at - 0.4, 0.8)
    # App 的提示音：报平安（E 段点“我没事”）、提醒（G）、求救（H）
    chk = load_caf(SOUNDS + 'checkin.caf')
    alarm = load_caf(SOUNDS + 'alarm.caf')
    place(L, chk, 26.5 + 1.0, 0.5)   # 手表轻震
    place(L, chk, 26.5 + 3.0, 0.35)
    place(L, alarm[: int(3.6 * SR)] * env_adsr(int(3.6 * SR), 0.05, 0.8), 39.0 + 4.2, 0.35)
    place(L, alarm[: int(3.4 * SR)] * env_adsr(int(3.4 * SR), 0.05, 0.8), 48.0 + 3.6, 0.4)
    # 收尾淡出
    L *= np.minimum(1, np.linspace(0, D, n) / 0.8)
    L *= np.clip((D - np.linspace(0, D, n)) / 2.0, 0, 1)
    write(out, L)


def usage(out, dur, events):
    n = int(dur * SR)
    L = np.zeros(n)
    prog = [[50, 57, 62, 65], [46, 53, 58, 62], [41, 53, 57, 60], [48, 55, 60, 64]]
    t, i = 0.0, 0
    while t < dur:
        chord(L, t, 8 + 2, prog[i % 4], amp=0.07, bright=1300, a=2, r=2.5)
        t += 8; i += 1
    chk = load_caf(SOUNDS + 'checkin.caf')
    alarm = load_caf(SOUNDS + 'alarm.caf')
    for ev in events:
        if ev['kind'] == 'checkin': place(L, chk, ev['t'], 0.45)
        elif ev['kind'] == 'alarm':
            d = ev.get('dur', 3)
            place(L, alarm[: int(d * SR)] * env_adsr(int(d * SR), 0.05, 0.6), ev['t'], 0.3)
    L *= np.minimum(1, np.linspace(0, dur, n) / 1.0)
    L *= np.clip((dur - np.linspace(0, dur, n)) / 2.5, 0, 1)
    write(out, L)


def write(out, L):
    # 简单的立体声：右声道稍微延迟，做一点宽度
    R = np.concatenate([np.zeros(int(0.012 * SR)), L[: -int(0.012 * SR)]])
    st = np.stack([L, R], 1)
    peak = np.max(np.abs(st)) or 1
    st = st / peak * 0.85
    pcm = (st * 32767).astype('<i2').tobytes()
    import wave
    with wave.open(out, 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm)


if __name__ == '__main__':
    if sys.argv[1] == 'promo':
        promo(sys.argv[2])
    else:
        usage(sys.argv[2], float(sys.argv[3]), json.load(open(sys.argv[4])) if len(sys.argv) > 4 else [])
