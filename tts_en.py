# 英語の読み上げ（Kokoro・ローカル・無料）
# 使い方: uv run --python 3.12 --with kokoro-onnx --with soundfile tts_en.py --file 台本.txt --out out.wav [--voice af_heart] [--speed 1.0]
#        uv run ... tts_en.py --text "Hello" --out hello.wav
# 初回だけ、モデル（約330MB）を %LOCALAPPDATA%\kokoro に取ってくる
import argparse, os, sys, urllib.request

BASE = 'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/'
FILES = ['kokoro-v1.0.onnx', 'voices-v1.0.bin']
HOME = os.path.join(os.environ.get('LOCALAPPDATA') or os.path.expanduser('~'), 'kokoro')


def ensure_models():
    os.makedirs(HOME, exist_ok=True)
    for f in FILES:
        p = os.path.join(HOME, f)
        if os.path.exists(p) and os.path.getsize(p) > 1_000_000:
            continue
        print(f'モデルを取得中: {f}', flush=True)
        urllib.request.urlretrieve(BASE + f, p + '.part')
        os.replace(p + '.part', p)
    return [os.path.join(HOME, f) for f in FILES]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--text')
    ap.add_argument('--file')
    ap.add_argument('--out', default='out.wav')
    ap.add_argument('--voice', default='af_heart')
    ap.add_argument('--speed', type=float, default=1.0)
    ap.add_argument('--lang', default='en-us')
    ap.add_argument('--list-voices', action='store_true')
    a = ap.parse_args()
    import soundfile as sf
    from kokoro_onnx import Kokoro
    model, voices = ensure_models()
    k = Kokoro(model, voices)
    if a.list_voices:
        print('\n'.join(k.get_voices()))
        return
    text = a.text if a.text else open(a.file, encoding='utf-8').read() if a.file else None
    if not text:
        sys.exit('--text か --file を指定')
    # 段落ごとに作ってつなぐ（長い台本でも止まらない）
    import numpy as np
    parts, sr = [], 24000
    paras = [p.strip() for p in text.split('\n') if p.strip()]
    for i, p in enumerate(paras, 1):
        s, sr = k.create(p, voice=a.voice, speed=a.speed, lang=a.lang)
        parts += [s, np.zeros(int(sr * 0.35), dtype=s.dtype)]
        print(f'{i}/{len(paras)}', flush=True)
    sf.write(a.out, np.concatenate(parts), sr)
    print('できました: ' + os.path.abspath(a.out))


if __name__ == '__main__':
    main()
