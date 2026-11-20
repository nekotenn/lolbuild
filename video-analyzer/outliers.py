# 毎夜の外れ値探し（GitHub Actionsで動く）
# 1) YouTube Data APIで条件ごとに探す → 2) 「チャンネル平均の何倍」「登録者の何倍」で外れ値を出す
# 3) 新しく見つかった上位をGeminiで分解（キーがあれば） → data/ に保存（GitHub Pagesでスマホから見える）
import json, os, re, sys, time, datetime as dt
import requests

KEY = os.environ.get('GOOGLE_API_KEY', '').strip()
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, 'data')
Y = 'https://www.googleapis.com/youtube/v3/'
G = 'https://generativelanguage.googleapis.com/v1beta/'
ANALYZE_PER_PRESET = int(os.environ.get('ANALYZE_PER_PRESET', '5'))
os.makedirs(DATA, exist_ok=True)


def load(name, default):
    p = os.path.join(DATA, name)
    try:
        return json.load(open(p, encoding='utf-8'))
    except Exception:
        return default


def save(name, obj):
    json.dump(obj, open(os.path.join(DATA, name), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)


def yt(path, **params):
    params = {k: v for k, v in params.items() if v not in ('', None)}
    params['key'] = KEY
    r = requests.get(Y + path, params=params, timeout=30)
    j = r.json()
    if r.status_code != 200:
        raise RuntimeError(j.get('error', {}).get('message', r.status_code))
    return j


def secs(d):
    m = re.match(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?', d or '') or None
    return sum(int(x or 0) * k for x, k in zip(m.groups(), (3600, 60, 1))) if m else 0


def find(p):
    after = (dt.datetime.utcnow() - dt.timedelta(days=p['days'])).strftime('%Y-%m-%dT%H:%M:%SZ')
    ids = []
    for q in p['q']:
        j = yt('search', part='snippet', type='video', q=q, maxResults=50, order='viewCount',
               publishedAfter=after, videoDuration=None if p['dur'] == 'any' else p['dur'],
               relevanceLanguage=p.get('lang'))
        ids += [i['id']['videoId'] for i in j.get('items', []) if i['id'].get('videoId')]
    ids = list(dict.fromkeys(ids))
    vids = []
    for i in range(0, len(ids), 50):
        vids += yt('videos', part='snippet,statistics,contentDetails', id=','.join(ids[i:i + 50])).get('items', [])
    chs = list({v['snippet']['channelId'] for v in vids})
    ch = {}
    for i in range(0, len(chs), 50):
        for c in yt('channels', part='statistics', id=','.join(chs[i:i + 50])).get('items', []):
            s = c['statistics']
            vc = max(int(s.get('videoCount', 0) or 0), 1)
            ch[c['id']] = {'subs': int(s.get('subscriberCount', 0) or 0), 'avg': int(s.get('viewCount', 0) or 0) / vc}
    now = dt.datetime.utcnow()
    out = []
    for v in vids:
        views = int(v['statistics'].get('viewCount', 0) or 0)
        c = ch.get(v['snippet']['channelId'], {'subs': 0, 'avg': 0})
        pub = dt.datetime.strptime(v['snippet']['publishedAt'][:19], '%Y-%m-%dT%H:%M:%S')
        r_sub = views / max(c['subs'], 1)
        r_avg = views / max(c['avg'], 1)
        if r_avg < p['min_avg'] and r_sub < p['min_sub']:
            continue
        out.append({'id': v['id'], 'title': v['snippet']['title'], 'ch': v['snippet']['channelTitle'],
                    'views': views, 'subs': c['subs'], 'r_sub': round(r_sub, 1), 'r_avg': round(r_avg, 1),
                    'per_day': round(views / max((now - pub).days, 1)), 'len': secs(v['contentDetails'].get('duration')),
                    'published': v['snippet']['publishedAt'][:10]})
    out.sort(key=lambda h: (h['r_avg'], h['r_sub']), reverse=True)
    return out[:40], len(vids)


def pick_model():
    j = requests.get(G + 'models', params={'key': KEY, 'pageSize': 200}, timeout=30).json()
    names = [m['name'].split('/')[-1] for m in j.get('models', []) if 'generateContent' in m.get('supportedGenerationMethods', [])]
    names = [n for n in names if 'flash' in n and not re.search(r'lite|image|tts|live|audio|embed|8b', n)]
    ver = lambda n: float((re.search(r'gemini-(\d+(?:\.\d+)?)', n) or [0, 0])[1])
    names.sort(key=lambda n: (-ver(n), 'preview' in n or 'exp' in n))
    if not names:
        raise RuntimeError('Flashモデルが見つからない')
    return names[0]


def analyze(model, vid, prompt, long):
    body = {'contents': [{'parts': [{'file_data': {'file_uri': 'https://www.youtube.com/watch?v=' + vid}}, {'text': prompt}]}],
            'generationConfig': {'temperature': 0.4, 'responseMimeType': 'application/json'}}
    if long:
        body['generationConfig']['mediaResolution'] = 'MEDIA_RESOLUTION_LOW'
    for a in range(4):
        r = requests.post(G + f'models/{model}:generateContent', params={'key': KEY}, json=body, timeout=600)
        j = r.json()
        if r.status_code == 200:
            t = ''.join(p.get('text', '') for p in j['candidates'][0]['content']['parts'])
            try:
                return json.loads(re.sub(r'^```json|```$', '', t.strip()))
            except Exception:
                return {'raw': t}
        msg = j.get('error', {}).get('message', str(r.status_code))
        if r.status_code == 400 and 'mediaResolution' in body['generationConfig'] and re.search('media_?resolution', msg, re.I):
            del body['generationConfig']['mediaResolution']
            continue
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(30 * (a + 1))
            continue
        raise RuntimeError(msg)
    raise RuntimeError('混雑で失敗')


def md_table(items):
    rows = ['| 平均の何倍 | 登録者の何倍 | 再生 | 長さ | 動画 |', '|---|---|---|---|---|']
    for h in items[:30]:
        t = h['title'].replace('|', '／')
        rows.append(f"| {h['r_avg']} | {h['r_sub']} | {h['views']:,} | {h['len'] // 60}:{h['len'] % 60:02d} | [{t}](https://www.youtube.com/watch?v={h['id']}) {h['ch'].replace('|', '／')} |")
    return '\n'.join(rows)


def main():
    if not KEY:
        print('GOOGLE_API_KEY がないので何もしない（PC版 F:\\tools\\outliers が毎夜動く）'); return
    presets = json.load(open(os.path.join(HERE, 'presets.json'), encoding='utf-8'))
    prompt_tpl = open(os.path.join(HERE, 'prompt.txt'), encoding='utf-8').read()
    today = (dt.datetime.utcnow() + dt.timedelta(hours=9)).strftime('%Y-%m-%d')
    seen = load('seen.json', {})
    analysis = load('analysis.json', {})
    latest = {'date': today, 'presets': {}}
    md = [f'# 外れ値 {today}（毎夜の自動探し）\n']
    try:
        model = pick_model()
    except Exception as e:
        model = None
        print('Geminiなし:', e)
    for p in presets:
        try:
            items, scanned = find(p)
        except Exception as e:
            latest['presets'][p['id']] = {'label': p['label'], 'error': str(e), 'items': []}
            print(p['id'], 'エラー', e)
            continue
        for h in items:
            h['new'] = h['id'] not in seen
            seen.setdefault(h['id'], today)
        latest['presets'][p['id']] = {'label': p['label'], 'scanned': scanned, 'items': items}
        md += [f"## {p['label']}（{scanned}本から {len(items)}本）\n", md_table(items), '']
        if model:
            todo = [h for h in items if h['id'] not in analysis][:ANALYZE_PER_PRESET]
            for h in todo:
                try:
                    d = analyze(model, h['id'], prompt_tpl.replace('{goal}', p['goal']), h['len'] > 600)
                    analysis[h['id']] = {'at': today, 'model': model, 'preset': p['id'], 'meta': h, 'd': d}
                    print('分解OK', h['title'][:40])
                except Exception as e:
                    print('分解だめ', h['id'], e)
                time.sleep(6)
        print(p['id'], scanned, '本から', len(items), '本')
    save('latest.json', latest)
    save(f'outliers_{today}.json', latest)
    save('seen.json', seen)
    save('analysis.json', analysis)
    open(os.path.join(DATA, 'latest.md'), 'w', encoding='utf-8').write('\n'.join(md))


if __name__ == '__main__':
    main()
