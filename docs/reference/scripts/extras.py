import sys, json, math
sys.path.insert(0, '/private/tmp/claude-501/m101')
from measure import *


import measure as _m
_gb = _m.glyph_bbox


def glyph_bbox(d, rect, fill, tol=40):
    if isinstance(fill, str):
        fill = tuple(int(fill[i:i + 2], 16) for i in (1, 3, 5))
    return _gb(d, rect, fill, tol)


def capheight(d, tile_pt, fill):
    x, y, w, h = tile_pt
    rect = (int(x * S) + 8, int(y * S) + 8, int((x + w) * S) - 8, int((y + h) * S) - 8)
    return glyph_bbox(d, rect, fill, tol=60)


def inner(f, pad=6):
    return (int(f[0] * S) + pad, int(f[1] * S) + pad, int((f[0] + f[2]) * S) - pad, int((f[1] + f[3]) * S) - pad)


def ret(t):
    for k in ('return','go','send','done','next','search','Search'):
        if k in t: return t[k]


def meas(name):
    return json.load(open(R + 'meas-' + name + '.json'))['tiles']


out = {}
for mode in ('L', 'D'):
    o = {}
    d = load(mode + '-letters-lower')
    m = meas(mode + '-letters-lower')
    o['backdrop_between_rows'] = hexc(px(d, 195 * S, int(595 * S)))
    o['backdrop_below_row4'] = hexc(px(d, 195 * S, int(780 * S)))
    o['backdrop_prediction_bar'] = hexc(px(d, int(60 * S), int(530 * S)))
    o['tile_fill'] = {k: m[k]['fill'] for k in ('q', 'a', 'z', 'shift', 'delete', 'numbers', 'space', 'return')}
    dark_text = mode == 'L'
    o['letter_color'] = hexc(extreme(d, inner(m['q']['frame_pt']), dark=dark_text))
    for nm in ('x', 'h', 'q'):
        bb = capheight(d, m[nm]['frame_pt'], m[nm]['fill'])
        t = m[nm]['frame_pt']
        o['glyph_' + nm] = {'h_pt': round((bb[3] - bb[1]) / S, 2), 'w_pt': round((bb[2] - bb[0]) / S, 2),
                            'top_below_tile_top_pt': round(bb[1] / S - t[1], 2), 'bottom_above_tile_bottom_pt': round(t[1] + t[3] - bb[3] / S, 2)}
    du = load(mode + '-letters-shift-auto')
    mu = meas(mode + '-letters-shift-auto')
    for nm in ('H', 'E'):
        if nm in mu:
            bb = capheight(du, mu[nm]['frame_pt'], mu[nm]['fill'])
            o['upper_' + nm + '_h_pt'] = round((bb[3] - bb[1]) / S, 2)
    sh = mu.get('shift')
    if sh:
        o['shift_active_tile_fill'] = sh['fill']
        o['shift_active_glyph_color'] = hexc(extreme(du, inner(sh['frame_pt']), dark=dark_text))
        gb = glyph_bbox(du, inner(sh['frame_pt']), sh['fill'], 60)
        o['shift_active_glyph_bbox_pt'] = [round(a / S, 2) for a in gb]
    rect = (int(150 * S), int(520 * S), int(236 * S), int(556 * S))
    bar = px(d, int(60 * S), int(530 * S))
    bb = glyph_bbox(d, rect, bar, tol=60)
    o['pred_text_bbox_pt'] = [round(a / S, 2) for a in bb]
    o['pred_text_color'] = hexc(extreme(d, rect, dark=dark_text))
    r2 = (bb[0], bb[1], bb[0] + int(9 * S), bb[3])
    b2 = glyph_bbox(d, r2, bar, tol=60)
    o['pred_first_glyph_h_pt'] = round((b2[3] - b2[1]) / S, 2)
    row = int(538 * S)
    o['divider_samples'] = [(round(x / S, 2), hexc(px(d, x, row))) for x in range(int(140 * S), int(147 * S)) if dist(px(d, x, row), bar) > 3][:4]
    host = px(d, 5, int(400 * S))
    o['host_color'] = hexc(host)
    ins = []
    for k in range(0, 90, 6):
        y = int(516 * S) + k
        x = 0
        while x < 200 and dist(px(d, x, y), host) <= 4:
            x += 1
        ins.append((k, x))
    o['kbd_top_left_inset_px_by_row'] = ins
    ins = []
    for k in range(0, 90, 6):
        y = H - 1 - k
        x = 0
        while x < 300 and dist(px(d, x, y), host) <= 4:
            x += 1
        ins.append((k, x))
    o['kbd_bottom_left_inset_px_by_row'] = ins
    y = int(516 * S) + 20
    while y > 1200 and dist(px(d, 195 * S, y), host) > 4:
        y -= 1
    o['kbd_top_edge_y_pt'] = (y + 1) / S
    rect = (int(20 * S), int(785 * S), int(60 * S), int(830 * S))
    o['emoji_glyph_color'] = hexc(extreme(d, rect, dark=dark_text))
    dg = load(mode + '-trait-go')
    mg = meas(mode + '-trait-go')
    o['return_go_fill'] = ret(mg)['fill']
    o['return_go_glyph_color'] = hexc(extreme(dg, inner(ret(mg)['frame_pt']), dark=False))
    o['return_done_fill'] = ret(meas(mode + '-trait-done'))['fill']
    o['return_next_fill'] = ret(meas(mode + '-trait-next'))['fill']
    o['return_send_fill'] = ret(meas(mode + '-trait-send'))['fill']
    dp = load(mode + '-trait-num')
    mp = meas(mode + '-trait-num')
    o['numpad_key_fill'] = mp['1']['fill']
    o['numpad_backdrop'] = hexc(px(dp, int(130 * S), int(595 * S)))
    o['numpad_tile_radius_pt'] = mp['1']['radius_pt']
    out[mode] = o
json.dump(out, open(R + 'extras.json', 'w'), indent=1)
print(json.dumps(out))
