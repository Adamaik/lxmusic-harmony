"""Small cross-artist playlist retrieval experiment. Run with Python 3."""
import csv
import json
import math
import random
import sys
from collections import Counter, defaultdict
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen


def fetch(route, **params):
    url = 'https://music.163.com/api/' + route + '?' + urlencode(params)
    with urlopen(url, timeout=10) as response:
        return json.load(response)


def main(output):
    rng = random.Random(42)
    lists = {}
    for category in ['粤语', '华语', '民谣', '摇滚']:
        page = fetch('playlist/list', cat=category, order='hot', limit=20, offset=0)
        for entry in page['playlists']:
            lists[entry['id']] = entry['creator']['userId']
    songs = {}
    corpus = []
    seen = set()
    for pid, author in lists.items():
        try:
            detail = fetch('v6/playlist/detail', id=pid)['playlist']
            song_ids = [row['id'] for row in detail['trackIds'][:100]]
            tracks = fetch('song/detail', ids=json.dumps(song_ids, separators=(',', ':')))['songs']
        except (OSError, KeyError, ValueError) as error:
            print(pid, error, file=sys.stderr)
            continue
        ids = frozenset(t['id'] for t in tracks if t.get('artists'))
        if len(ids) < 2 or ids in seen:
            continue
        seen.add(ids)
        corpus.append((author, ids))
        for t in tracks:
            if t.get('artists'):
                songs[t['id']] = (t['name'], tuple(a['name'] for a in t['artists']))
    authors = sorted({a for a, _ in corpus})
    rng.shuffle(authors)
    held = set()
    held_count = 0
    sizes = Counter(a for a, _ in corpus)
    for author in authors:
        if held_count + sizes[author] <= max(1, len(corpus)//4):
            held.add(author)
            held_count += sizes[author]
    index = defaultdict(list)
    for author, ids in corpus:
        if author not in held:
            for seed in ids:
                index[seed].append((author, ids))
    popular = sorted(index, key=lambda s: (-len(index[s]), s))

    def different(seed, song):
        return set(songs[seed][1]).isdisjoint(songs[song][1])

    def rank(seed):
        votes = defaultdict(dict)
        for author, ids in index.get(seed, []):
            for song in ids:
                if different(seed, song):
                    weight = 1 / math.log2(1 + len(ids))
                    votes[song][author] = max(votes[song].get(author, 0), weight)
        return sorted(votes, key=lambda s: (-sum(votes[s].values()) /
                      math.sqrt(len(index[s])), s))[:5]

    trials = hits = baseline = covered = 0
    examples = {}
    for author, ids in corpus:
        if author not in held:
            continue
        for seed in sorted(ids):
            target = {s for s in ids if different(seed, s)}
            if not target:
                continue
            picks = rank(seed)
            top = [s for s in popular if different(seed, s)][:5]
            trials += 1
            covered += bool(picks)
            hits += bool(target.intersection(picks))
            baseline += bool(target.intersection(top))
            if picks:
                examples[seed] = (picks, top)
    seeds = sorted(examples)
    rng.shuffle(seeds)
    output.mkdir(parents=True, exist_ok=True)
    def label(s):
        return songs[s][0] + ' — ' + '/'.join(songs[s][1])
    with (output/'blind.csv').open('w', encoding='utf-8-sig', newline='') as f, (output/'key.csv').open('w', encoding='utf-8-sig', newline='') as k:
        rows, keys = csv.writer(f), csv.writer(k)
        rows.writerow(['种子','候选','愿意继续听','首次听且想收藏'])
        keys.writerow(['种子','候选','来源'])
        for seed in seeds[:20]:
            picks, top = examples[seed]
            batch = sorted(set(picks + top))
            rng.shuffle(batch)
            for s in batch:
                rows.writerow([label(seed),label(s),'',''])
                keys.writerow([label(seed),label(s),'+'.join(n for n,l in [('共现',picks),('热门',top)] if s in l)])
    print(dict(playlists=len(corpus), authors=len(authors), tracks=len(songs), trials=trials,
               covered=covered, hits=hits, popularity_hits=baseline, blind_seeds=min(20,len(seeds))))


if __name__ == '__main__':
    main(Path(sys.argv[1]))
