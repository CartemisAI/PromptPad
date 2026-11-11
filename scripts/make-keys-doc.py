#!/usr/bin/env python3
"""Writes docs/keys.md and docs/keys.zh-CN.md: every key, on every layer, in every app, from the default layout.

    python3 scripts/make-keys-doc.py
"""
import json, os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
layout = json.load(open(f'{root}/Resources/layout.json'))
zh = json.load(open(f'{root}/Resources/i18n/zh-Hans.json'))

# Keys in the order they sit on the keypad (rows top to bottom), with the legend printed on the keycap.
ORDER = [('knob', 'Knob'), ('esc', 'Esc'), ('del', 'Del'), ('tab', 'Tab'), ('bksp', 'Bksp'),
         ('m1', 'M1'), ('numlock', 'Num'), ('slash', '/'), ('star', '*'), ('minus', '−'),
         ('m2', 'M2'), ('7', '7'), ('8', '8'), ('9', '9'), ('plus', '+'),
         ('m3', 'M3'), ('4', '4'), ('5', '5'), ('6', '6'),
         ('m4', 'M4'), ('1', '1'), ('2', '2'), ('3', '3'), ('enter', 'Enter'),
         ('fn', 'Fn'), ('0', '0'), ('dot', '.')]
LAYERS = [('base', None), ('fn', 'Fn'), ('m3', 'M4')]

def entry(key, layer, app):
    show = ((layout['keys'].get(key) or {}).get(layer) or {}).get('show') or {}
    e = show[app] if app in show else show.get('*')
    return e if isinstance(e, list) and len(e) == 4 else None

def write(lang):
    t = (lambda s: zh.get(s, s)) if lang == 'zh' else (lambda s: s)
    out = []
    if lang == 'zh':
        out += ['# 每个键做什么', '', '[English](keys.md) · 由 `scripts/make-keys-doc.py` 根据默认布局生成，改了布局后重新运行即可。',
                '程序里按 Fn+NumLock 打开的键位图显示的是同样的内容。', '']
    else:
        out += ['# What every key does', '', '[中文](keys.zh-CN.md) · Generated from the default layout by `scripts/make-keys-doc.py`; run it again after changing the layout.',
                'The key map in the app (Fn+NumLock) shows the same thing.', '']
    for app in layout['apps']:
        out += [f'## {t(app["name"])}', '']
        for layer, hold in LAYERS:
            rows = []
            for key, legend in ORDER:
                e = entry(key, layer, app['id'])
                if not e or e[2] == 'none' and layer != 'base': continue
                title = t(e[0]).replace('\n', ' ')
                detail = t(e[3])
                label = t(legend) if legend in ('Knob', 'Bksp', 'Enter') else legend
                rows.append(f'| {label} | {title} | {detail} |')
            if not rows: continue
            if lang == 'zh':
                head = '基础层' if hold is None else f'按住 {hold}'
                out += [f'### {head}', '', '| 键 | 功能 | 说明 |', '|---|---|---|']
            else:
                head = 'Base layer' if hold is None else f'Holding {hold}'
                out += [f'### {head}', '', '| Key | Does | Detail |', '|---|---|---|']
            out += rows + ['']
    name = 'keys.zh-CN.md' if lang == 'zh' else 'keys.md'
    open(f'{root}/docs/{name}', 'w').write('\n'.join(out))
    print(f'docs/{name}: {sum(1 for l in out if l.startswith("| ") and not l.startswith("| Key") and not l.startswith("| 键"))} rows')

write('en'); write('zh')
