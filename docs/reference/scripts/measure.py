import json, subprocess, sys, math
from collections import deque

S = 3  # px per pt
W, H = 1170, 2532
R = '/private/tmp/claude-501/m101/raw/'


def load(name):
    data = subprocess.run(['magick', R + name + '.png', '-depth', '8', 'rgb:-'], capture_output=True).stdout
    assert len(data) == W * H * 3, len(data)
    return data


def px(d, x, y):
    i = (y * W + x) * 3
    return (d[i], d[i + 1], d[i + 2])


def dist(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))


def flood(d, sx, sy, tol=5, limit=(0, 0, W, H)):
    ref = px(d, sx, sy)
    x0, y0, x1, y1 = limit
    seen = {(sx, sy)}
    q = deque([(sx, sy)])
    minx = maxx = sx
    miny = maxy = sy
    rows = {}
    while q:
        x, y = q.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if x0 <= nx < x1 and y0 <= ny < y1 and (nx, ny) not in seen and dist(px(d, nx, ny), ref) <= tol:
                seen.add((nx, ny))
                q.append((nx, ny))
    xs = [p[0] for p in seen]
    ys = [p[1] for p in seen]
    bx0, bx1, by0, by1 = min(xs), max(xs), min(ys), max(ys)
    return ref, (bx0, by0, bx1 + 1, by1 + 1), seen


def corner_radius(seen, bbox, corner='tl'):
    """Fit radius (px) from per-row inset of the fill at the top rows."""
    x0, y0, x1, y1 = bbox
    rowmin = {}
    for (x, y) in seen:
        if y < y0 + 40:
            rowmin[y] = min(rowmin.get(y, 1e9), x)
    obs = [(y - y0, rowmin[y] - x0) for y in sorted(rowmin) if y - y0 < 30]
    best = None
    for r10 in range(10, 400):
        r = r10 / 10
        err = 0
        for k, ins in obs:
            yy = k + 0.5
            if yy < r:
                model = r - math.sqrt(max(r * r - (r - yy) ** 2, 0))
            else:
                model = 0
            err += (model - ins) ** 2
        if best is None or err < best[0]:
            best = (err, r)
    return best[1]


def glyph_bbox(d, rect, fill, tol=40):
    """bbox of pixels differing from fill inside rect (px)."""
    x0, y0, x1, y1 = rect
    xs = []
    ys = []
    for y in range(y0, y1):
        for x in range(x0, x1):
            if dist(px(d, x, y), fill) > tol:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return (min(xs), min(ys), max(xs) + 1, max(ys) + 1)


def extreme(d, rect, dark=True):
    x0, y0, x1, y1 = rect
    best = None
    for y in range(y0, y1):
        for x in range(x0, x1):
            p = px(d, x, y)
            s = sum(p)
            if best is None or (s < best[0] if dark else s > best[0]):
                best = (s, p)
    return best[1]


def hexc(p):
    return '#%02X%02X%02X' % p


def ax_keys(name):
    j = json.load(open(R + 'ax-' + name + '.json'))
    out = {}

    def w(n):
        f = n.get('frame')
        if n.get('type') == 'Button' and n.get('AXLabel') and f and f['y'] > 500:
            out.setdefault(n['AXLabel'], f)
        for c in n.get('children', []) or []:
            w(c)
    for n in j:
        w(n)
    return out


def pxr(f):
    return (round(f['x'] * S), round(f['y'] * S), round((f['x'] + f['width']) * S), round((f['y'] + f['height']) * S))


def measure(prefix, label_of_cap):
    d = load(prefix)
    keys = ax_keys(prefix)
    res = {'ax_hit_rects_pt': {k: [round(v['x'], 2), round(v['y'], 2), round(v['width'], 2), round(v['height'], 2)] for k, v in keys.items()}}
    tiles = {}
    for k in keys:
        if k in ('Emoji', 'Dictate', 'Padding-Left', 'Padding-Right') or keys[k]['width'] == 0:
            continue
        x0, y0, x1, y1 = pxr(keys[k])
        if y1 > H - 10 or x1 > W or y0 < 1540:
            continue
        sx = (x0 + x1) // 2 + (x1 - x0) // 4 if (x1 - x0) > 200 else (x0 + x1) // 2
        sy = y0 + int((y1 - y0) * 0.7)
        ref, bb, seen = flood(d, sx, sy, tol=5, limit=(max(x0 - 30, 0), y0 - 30, min(x1 + 30, W), y1 + 30))
        r = corner_radius(seen, bb)
        tiles[k] = {'fill': hexc(ref), 'frame_pt': [bb[0] / S, bb[1] / S, (bb[2] - bb[0]) / S, (bb[3] - bb[1]) / S],
                    'radius_pt': round(r / S, 2)}
    res['tiles'] = tiles
    return d, res


if __name__ == '__main__':
    prefix = sys.argv[1]
    d, res = measure(prefix, None)
    json.dump(res, open(R + 'meas-' + prefix + '.json', 'w'), indent=1)
    for k, v in res['tiles'].items():
        print(k, v['fill'], [round(a, 2) for a in v['frame_pt']], v['radius_pt'])
