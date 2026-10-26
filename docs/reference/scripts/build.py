import sys, json, math, subprocess, os
sys.path.insert(0, '/private/tmp/claude-501/m101')
R = '/private/tmp/claude-501/m101/raw/'
OUT = '/Volumes/SSD/Projects/Personal/iBoard/.claude/worktrees/wf_5ec4ddaa-f84-1/docs/reference/'
KY = 516.0  # keyboard top in pt (AX group y)
ex = json.load(open(R + 'extras.json'))


def fit_r(ins, step=6):
    best = None
    for r10 in range(100, 1800):
        r = r10 / 10
        err = 0
        for k, v in ins:
            yy = k + 0.5
            m = r - math.sqrt(max(r * r - (r - yy) ** 2, 0)) if yy < r else 0
            err += (m - v) ** 2
        if best is None or err < best[0]:
            best = (err, r)
    return round(best[1] / 3, 1)


def tiles(name):
    t = json.load(open(R + 'meas-' + name + '.json'))['tiles']
    out = {}
    for k, v in t.items():
        f = v['frame_pt']
        if v['radius_pt'] < 1:  # bar buttons / untiled
            continue
        out[k] = {'x': round(f[0], 2), 'y': round(f[1] - KY, 2), 'w': round(f[2], 2), 'h': round(f[3], 2), 'fill': v['fill'], 'radius': v['radius_pt']}
    return out


layers = {}
for l in ('letters-shift-auto', 'letters-lower', 'letters-shift', 'numbers', 'symbols'):
    layers[l] = {'light': tiles('L-' + l), 'dark': tiles('D-' + l)}
traits = {}
for t in ('email', 'url', 'num', 'dec', 'tel', 'search', 'search2', 'go', 'send', 'next', 'done', 'nocap'):
    try:
        traits[t] = {'light': tiles('L-trait-' + t), 'dark': tiles('D-trait-' + t)}
    except Exception as e:
        try:
            traits[t] = {'dark': tiles('D-trait-' + t)}
        except Exception:
            pass

top_r = fit_r(ex['L']['kbd_top_left_inset_px_by_row'])
bot_r = fit_r(ex['L']['kbd_bottom_left_inset_px_by_row'][::-1] if False else ex['L']['kbd_bottom_left_inset_px_by_row'])

M, E = 'measured', 'estimated'
doc = {
    'schema': 'iboard-native-metrics/1',
    'captured': '2026-10-26',
    'source': {
        'os': 'iOS 27.0 simulator (24A434)', 'device': 'iPhone 12 (390x844 pt @3x)', 'keyboard': 'system English (US) with Hindi (Hinglish) transliteration enabled (space bar shows "EN HI", prediction bar has an "A" script-switch button)',
        'host': 'Safari showing http://127.0.0.1 test page (white background)', 'method': 'simctl screenshots (1170x2532) + axe describe-ui hit rects + pixel scan (docs/reference/README.md)',
        'units': 'pt unless a key ends in _px; coordinates x from screen left, y relative to the keyboard top unless noted',
        'status_legend': {'measured': 'read directly from pixels or the accessibility tree', 'estimated': 'inferred (ratio, typical font metrics) and needs device verification'},
        'caveat': 'Translucent fills were sampled over a WHITE host page. The system keyboard backdrop is a blurred glass and changes with the host content (see docs/spikes/M0-04.md). Tile fills in dark mode are therefore only exact over a white host.'
    },
    'size_classes': {
        'iPhone12_portrait_390x844': {'status': M},
        'iPhone12_landscape': 'NOT TESTED: simulator rotation cannot be scripted here (no Simulator.app; Device Hub rotation not scriptable)',
        'iPhone12mini_portrait_375x812': 'NOT TESTED', 'iPhone12ProMax_portrait_428x926': 'NOT TESTED', 'iPhoneDuo': 'NOT TESTED'
    },
    'keyboard_iPhone12_portrait': {
        'frame': {'x': 0, 'y_screen': 516.0, 'w': 390, 'h': 328, 'status': M, 'note': 'AX group 0,516,390,328; includes prediction bar and the emoji/dictation row; bottom edge is the screen edge (no home-indicator inset applied by us)'},
        'prediction_bar': {'y': 0, 'h': 44, 'status': M, 'note': 'AX "Typing Predictions" group x 44..342 (3 equal cells 99.33 wide), leading button 0..44 (the keyboard-mode switcher chevrons), trailing button 342..390 (script switch "A"); empty cells when there are no predictions (email/URL/search fields)'},
        'rows': {
            'row1_tile_top': 52, 'row2_tile_top': 106, 'row3_tile_top': 160, 'row4_tile_top': 214, 'row_pitch': 54, 'tile_height': 43,
            'vertical_gap_between_rows': 11, 'status': M,
            'note': 'AX hit rects are 54 tall and start 1pt above tile tops (hit rect y 567 vs tile y 568); tile bottoms leave an 11pt hit-padding band'},
        'bottom_accessory_row': {'y': 257, 'h': 71, 'status': M, 'content': 'emoji button left (AX 8.5,775.7 68x68.7), dictation mic right (313.4,775.4 68x68.7); glyphs without tiles', 'note': 'In a third-party keyboard the globe/mic bar is the system accessory (see M0-04); here the row is part of the system keyboard'},
        'letters': {
            'tile_w': 32.33, 'key_pitch': 38.33, 'horizontal_gap': 6.0, 'status': M,
            'row1_first_tile_x': 6.67, 'row2_first_tile_x': 25.67, 'row3_letters_first_tile_x': 64.0,
            'shift_tile': {'x': 6.67, 'w': 43.67}, 'delete_tile': {'x': 339.67, 'w': 44.0},
            'gap_shift_to_z': 13.67, 'gap_m_to_delete': 13.67,
            'bottom_row': {'numbers_tile': {'x': 6.67, 'w': 89.67}, 'space_tile': {'x': 102.33, 'w': 185.33}, 'return_tile': {'x': 293.67, 'w': 90.0}, 'gaps': 6.0},
            'ax_hit_rect_pitch_note': 'letter hit rect 38.33 x 54, abutting (edge keys extend to the screen edge: Q rect x 4.67)'
        },
        'numbers_symbols': {
            'status': M, 'row3_keys': 'toggle (#+= / 123) 43.67 wide at x 6.67; five punctuation tiles 47.67 wide at pitch 53.67 starting x 64.0; delete 44 at x 339.67',
            'row1_row2': 'ten tiles, same frames as letters row 1 (32.33 wide, pitch 38.33); ninth key in row 2 labelled "ampersand" (AX)'
        },
        'numeric_pad': {
            'status': M, 'tile_w': 122.33, 'tile_h': 48, 'tile_pitch_x': 128.33, 'tile_pitch_y': 54, 'row_tops': [50, 104, 158, 212], 'first_x': 4.67,
            'radius': ex['L']['numpad_tile_radius_pt'], 'row4': 'decimal/phone-pad bottom row has an untiled "." (or "+*#" tile on tel) left, zero tile centre, untiled delete right; globe at bottom left of the accessory row replaces emoji',
            'note': 'digit tiles carry ABC/DEF sub-labels in small caps (~9-10pt, estimated)'
        },
        'corner_radius': {'key_tile': 8.47, 'status': M, 'return_blue_tile': 9.07, 'numeric_pad_tile': ex['L']['numpad_tile_radius_pt'],
                          'keyboard_top_corners': top_r, 'keyboard_bottom_corners': bot_r,
                          'note': 'keyboard container radii fitted from the per-row inset profile, bottom corners follow the display corner (approximate, circle fit); tile radii also circle fit (actual iOS uses continuous corners)'},
        'shadow': {'status': 'NOT MEASURED', 'note': 'no visible hard shadow under tiles in the 3x captures; iOS keys normally carry a ~1pt dark under-edge'},
    },
    'fonts': {
        'status': E,
        'letter_lowercase': {'size_pt': 25, 'weight': 'regular', 'family': 'SF Pro (system)', 'basis': 'x-height 13pt measured; SF x-height ratio ~0.52 gives about 25'},
        'letter_uppercase': {'size_pt': 22, 'weight': 'regular', 'basis': f'cap height {ex["L"]["upper_H_h_pt"]}pt measured; ratio 0.705'},
        'special_key_labels_123_ABC': {'size_pt': 16, 'weight': 'regular', 'basis': 'estimated from the capture; not measured'},
        'prediction_text': {'size_pt': 17, 'weight': 'regular', 'basis': f'first glyph height {ex["L"]["pred_first_glyph_h_pt"]}pt; ratio 0.705'},
        'space_bar_language_label': {'text': 'EN HI', 'size_pt': 9, 'color': 'secondary label', 'status': E},
        'glyph_measurements': {'L': {k: ex['L'][k] for k in ('glyph_x', 'glyph_h', 'glyph_q', 'upper_H_h_pt', 'upper_E_h_pt', 'pred_text_bbox_pt', 'pred_first_glyph_h_pt')}}
    },
    'colors': {
        'status': M + ' (over white host)',
        'light': {k: ex['L'][k] for k in ('backdrop_between_rows', 'backdrop_below_row4', 'backdrop_prediction_bar', 'tile_fill', 'letter_color', 'pred_text_color', 'divider_samples', 'shift_active_tile_fill', 'shift_active_glyph_color', 'emoji_glyph_color', 'return_go_fill', 'return_go_glyph_color', 'return_done_fill', 'return_send_fill', 'return_next_fill', 'numpad_key_fill', 'numpad_backdrop')},
        'dark': {k: ex['D'][k] for k in ('backdrop_between_rows', 'backdrop_below_row4', 'backdrop_prediction_bar', 'tile_fill', 'letter_color', 'pred_text_color', 'divider_samples', 'shift_active_tile_fill', 'shift_active_glyph_color', 'emoji_glyph_color', 'return_go_fill', 'return_go_glyph_color', 'return_done_fill', 'return_send_fill', 'return_next_fill', 'numpad_key_fill', 'numpad_backdrop')},
        'observations': [
            'Light: every tile (letters, shift, delete, 123, space, return) is the same #FFFFFF; no darker "function key" fill in iOS 27.0 light mode',
            'Dark: every tile is #575757 over a #373737 backdrop (white host); function keys are not distinguished',
            'Blue action return (go/send/done/join-style) = #007AFF with white glyph in both appearances; "next" (>) and default return stay tile colour',
            'Shift active = the same tile colour with a filled arrow glyph (not an inverted tile)'
        ]
    },
    'trait_variants': 'see layouts.traits; return-key variants: default (arrow-return glyph), go/send/done = blue tile with arrow/up-arrow/check glyph, next = chevron on a normal tile',
    'layouts': {'layers': layers, 'traits': traits},
    'observations_ios27': [
        'The keyboard has a persistent 44pt prediction bar even for plain fields; email, URL and search-type fields show it empty (three empty cells and dividers); text fields show 3 predictions with the first quoted ("Ve")',
        'No globe key on letters in this capture (probably because only one keyboard is enabled; not verified); the emoji button sits bottom-left and the mic bottom-right on the accessory row below the 4th key row, 71pt tall',
        'Return key label is a glyph, not text. Currency key on the numbers layer is the locale currency (rupee here)',
        'Auto-capitalisation: opening a text field shows the shifted layer; autocapitalize=none starts lowercase',
        'Caps lock (double tap shift) could not be triggered through axe synthetic taps: NOT CAPTURED',
        'Hinglish: the system "English + Hindi" keyboard shows "EN HI" on the space bar and an "A" script-switch key at the right end of the prediction bar; iBoard should mirror this affordance for F4/Hinglish'
    ],
    'iboardlayout_token_suggestions': {
        'note': 'derived values for IBoardLayout (iPhone 12 portrait, scale with screen width 390 for other widths until measured)',
        'keyboardHeight': 328, 'predictionBarHeight': 44, 'rowPitch': 54, 'keyHeight': 43, 'keyWidthLetters': 32.33, 'keyPitchLetters': 38.33, 'horizontalGap': 6, 'verticalGap': 11,
        'edgeMargin': 6.67, 'cornerRadiusKey': 8.5, 'rowInsets': [6.67, 25.67, 64.0], 'bottomAccessoryHeight': 71,
        'status': E
    }
}
os.makedirs(OUT + 'screenshots', exist_ok=True)
json.dump(doc, open(OUT + 'native-metrics.json', 'w'), indent=1)
print('radii', top_r, bot_r, 'traits', list(traits.keys()))
