#!/usr/bin/env python3
"""Checks the layout before you build or write it to the keyboard.

    python3 scripts/check-layout.py            default layout + add-ons in personal/ and addons/
    python3 scripts/check-layout.py --public   default layout + addons/ only

Errors (exit 1): a key code with Option, two keys sending the same combo, a VS Code "pass" with no
VS Code rule, a malformed "show" entry, a "keys:" action PromptPad can't parse.
Warnings: actions no key sends, keys whose combo has no action, positions with no factory value.
"""
import json, re, sys, glob, os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
public = '--public' in sys.argv

def merge(a, b):
    out = dict(a)
    for k, bv in b.items():
        av = out.get(k)
        if isinstance(av, dict) and isinstance(bv, dict): out[k] = merge(av, bv)
        elif isinstance(av, list) and isinstance(bv, list) and all(isinstance(x, dict) and 'id' in x for x in av + bv):
            lst = list(av)
            for item in bv:
                i = next((n for n, x in enumerate(lst) if x['id'] == item['id']), None)
                if i is None: lst.append(item)
                else: lst[i] = merge(lst[i], item)
            out[k] = lst
        else: out[k] = bv
    return out

layout = json.load(open(f'{root}/Resources/layout.json'))
overlays = glob.glob(f'{root}/addons/*/layout.json') + ([] if public else glob.glob(f'{root}/personal/*/layout.json'))
for p in sorted(overlays): layout = merge(layout, json.load(open(p)))

errors, warnings = [], []
F = {0x68 + i: f'f{13 + i}' for i in range(8)}
LAYER_MOD = {'base': 0, 'fn': 0x02, 'm3': 0x08}   # Fn holds Shift, M4 holds Command
ALLOWED_OPTION = {0x0450, 0x044f}                  # Option+arrow word moves (real keys, not combos)

def norm(c):
    p = c.lower().split('+'); alias = {'control': 'ctrl', 'option': 'opt', 'alt': 'opt', 'command': 'cmd'}
    mods = {alias.get(m, m) for m in p[:-1]}
    return '+'.join([m for m in ('ctrl', 'opt', 'shift', 'cmd') if m in mods] + [p[-1]])

def combo(code, extra):
    hi, lo = code >> 8, code & 0xFF
    if hi >= 0x10 or lo not in F: return None       # layer keys, RGB, Bluetooth, plain keys: not PromptPad combos
    mods = (hi & 0x0F) | extra
    names = [n for bit, n in ((1, 'ctrl'), (4, 'opt'), (2, 'shift'), (8, 'cmd')) if mods & bit]
    return '+'.join(names + [F[lo]])

produced = {}
for kid, k in layout['keys'].items():
    for ln in ('base', 'fn', 'm3'):
        if ln not in k or 'code' not in k[ln]: continue
        c = int(k[ln]['code'], 16)
        if c == 0: continue
        src = int(k['base']['code'], 16) if c == 1 and ln != 'base' and 'base' in k else c
        if c == 1 and ln == 'base': continue
        if src < 0x2000 and (src >> 8) & 0x04 and src not in ALLOWED_OPTION:
            errors.append(f'{kid}/{ln}: code {src:04x} has Option (Claude opens its quick entry on Option)')
        cb = combo(src, LAYER_MOD[ln] if src < 0x2000 else 0)
        if cb: produced.setdefault(cb, []).append(f'{kid}/{ln}')
for ln, e in layout.get('encoder', {}).items():
    for d in ('ccw', 'cw'):
        c = int(e[d], 16)
        src = int(layout['encoder']['base'][d], 16) if c == 1 else c
        cb = combo(src, LAYER_MOD[ln] if src < 0x2000 else 0)
        if cb: produced.setdefault(cb, []).append(f'knob-{d}/{ln}')

for cb, srcs in produced.items():
    if len(srcs) > 1: errors.append(f'{cb} is sent by several keys: {", ".join(srcs)}')

actions = {norm(k): v for k, v in layout['actions'].items()}
for a in actions:
    if a not in produced: warnings.append(f'action "{a}" is not sent by any key')
for cb, srcs in produced.items():
    if cb not in actions: warnings.append(f'{", ".join(srcs)} sends {cb}, which has no action')

key_names = set('abcdefghijklmnopqrstuvwxyz0123456789.,/;[]`\\=-\'') | {
    'return', 'enter', 'tab', 'space', 'delete', 'esc', 'escape', 'left', 'right', 'down', 'up', 'pageup', 'pagedown',
    'home', 'end', 'forwarddelete', 'fwddelete', 'f12'} | {f'f{n}' for n in range(13, 21)}
mods = {'cmd', 'command', 'shift', 'opt', 'alt', 'option', 'ctrl', 'control'}
for cb, v in actions.items():
    for app, act in (v.items() if isinstance(v, dict) else [('*', v)]):
        if isinstance(act, str) and act.lower().startswith('keys:'):
            for part in act[5:].split(','):
                ks = [p for p in part.lower().split('+') if p not in mods]
                if len(ks) != 1 or ks[0] not in key_names: errors.append(f'{cb} [{app}]: can\'t parse "{act}"')

rules_path = f'{root}/Resources/vscode-keybindings.json'
rule_keys = {norm(r['key']) for r in json.load(open(rules_path))}
for cb, v in actions.items():
    if isinstance(v, dict) and v.get('vscode') == 'pass' and cb not in rule_keys:
        errors.append(f'{cb} is "pass" in VS Code but Resources/vscode-keybindings.json has no rule for it')

app_ids = {a['id'] for a in layout.get('apps', [])}
for kid, k in layout['keys'].items():
    for ln in ('base', 'fn', 'm3'):
        show = (k.get(ln) or {}).get('show')
        if show is None: continue
        if not isinstance(show, dict): errors.append(f'{kid}/{ln}: "show" must be an object'); continue
        for app, e in show.items():
            if app != '*' and app not in app_ids: warnings.append(f'{kid}/{ln}: "show" for unknown app "{app}"')
            if e is not None and not (isinstance(e, list) and len(e) == 4):
                errors.append(f'{kid}/{ln}/{app}: "show" entries are [title, SF Symbol, category, detail] or null')

factory = layout.get('device', {}).get('factory')
if factory and os.path.exists(f'{root}/Resources/{factory}'):
    have = {tuple(l.split()[:4]) for l in open(f'{root}/Resources/{factory}') if l.strip()}
    idx = layout['layers']
    for kid, k in layout['keys'].items():
        for ln, i in idx.items():
            if ln in k and 'code' in k[ln] and ('key', str(i), str(k['pos'][0]), str(k['pos'][1])) not in have:
                warnings.append(f'{kid}/{ln}: no factory value (PromptPad saves the current one before first writing it)')

for w in warnings: print('warning:', w)
for e in errors: print('ERROR:', e)
print(f'{len(errors)} errors, {len(warnings)} warnings ({"public" if public else "with personal add-ons"})')
sys.exit(1 if errors else 0)
