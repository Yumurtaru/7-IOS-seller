#!/usr/bin/env python3
"""
Две проверки, которых НЕ делает swiftc -parse и которые уронили сборку:
  1. API новее цели развёртывания (iOS 16.0 по project.yml).
  2. Метки аргументов, которых у вызываемого типа нет ВООБЩЕ.

Правило 2 намеренно узкое: не «не передан обязательный аргумент» (там куча
ложных срабатываний из-за @State/@Environment и memberwise-init), а «такого
имени в объявлении типа нет ни разу» — ровно случай FavoritesScreen.
"""
import re, sys, glob, os

files = sorted(glob.glob(os.environ.get('T','tree') + '/**/*.swift', recursive=True))
src = {f: open(f, encoding='utf-8').read() for f in files}
out = []
def add(kind, f, line, msg): out.append((kind, f.replace(os.environ.get('T','tree') + '/', ''), line, msg))

# ── 1) Доступность ───────────────────────────────────────────────────────────
NEWER = {
    'ContentUnavailableView': 'iOS 17', 'scrollTargetBehavior': 'iOS 17',
    'scrollTargetLayout': 'iOS 17', 'containerRelativeFrame': 'iOS 17',
    'symbolEffect': 'iOS 17', 'sensoryFeedback': 'iOS 17',
    'PhaseAnimator': 'iOS 17', 'KeyframeAnimator': 'iOS 17',
    'contentMargins': 'iOS 17', 'scrollPosition': 'iOS 17',
    'visualEffect': 'iOS 17', 'toolbarTitleDisplayMode': 'iOS 17',
    'scrollBounceBehavior': 'iOS 16.4', 'onScrollGeometryChange': 'iOS 18',
    'MeshGradient': 'iOS 18', 'onScrollVisibilityChange': 'iOS 18',
    'tabViewBottomAccessory': 'iOS 26', 'glassEffect': 'iOS 26',
}
for f, text in src.items():
    for i, ln in enumerate(text.split('\n'), 1):
        if '@available' in ln or '#available' in ln: continue
        for api, ver in NEWER.items():
            if re.search(r'[.(\s]' + re.escape(api) + r'\b', ln):
                add('ДОСТУПНОСТЬ', f, i, f'{api} — {ver}, а цель сборки iOS 16.0')
        if re.search(r'@Observable\b', ln):
            add('ДОСТУПНОСТЬ', f, i, '@Observable — iOS 17, а цель сборки iOS 16.0')

# onChange: на iOS 16 ровно один параметр в замыкании
for f, text in src.items():
    for m in re.finditer(r'\.onChange\(of:\s*[^)]+\)\s*\{\s*([^}\n]*?)\s+in', text):
        if ',' in m.group(1):
            add('ДОСТУПНОСТЬ', f, text[:m.start()].count('\n') + 1,
                'onChange с двумя параметрами — iOS 17; на iOS 16 нужен один')

# ── 2) Метки, которых у типа нет ─────────────────────────────────────────────
# Тело каждого объявленного типа — чтобы искать в нём имя метки.
bodies = {}
def type_bodies(text):
    """Тела всех объявленных типов — по балансу скобок, а не по отступу:
    однострочные объявления (struct X { let a: Int }) иначе «съедали» весь
    остаток файла и давали горы ложных срабатываний."""
    res = []
    for m in re.finditer(r'(?:^|\n)\s*(?:public |private |fileprivate |internal |final )*'
                         r'(?:struct|class|enum)\s+(\w+)', text):
        name = m.group(1)
        i = text.find('{', m.end())
        if i < 0: continue
        depth, j = 0, i
        while j < len(text):
            if text[j] == '{': depth += 1
            elif text[j] == '}':
                depth -= 1
                if depth == 0: break
            j += 1
        res.append((name, text[i + 1:j]))
    return res

for f, text in src.items():
    for name, body in type_bodies(text):
        if name in bodies:
            bodies[name]['text'] += '\n' + body      # extension дополняет тип
        else:
            bodies[name] = {'text': body, 'file': f}

for f, text in src.items():
    for m in re.finditer(r'\b([A-Z]\w+)\(([^()]*(?:\([^()]*\)[^()]*)*)\)', text):
        name, args = m.group(1), m.group(2)
        if name not in bodies: continue
        body = bodies[name]['text']
        # Вырезаем вложенные вызовы: иначе метки ЧУЖИХ функций
        # (OrderFlow.stepTitle(key, shopType:)) приписывались бы внешнему типу.
        flat, depth = [], 0
        for ch in args:
            if ch == '(': depth += 1
            elif ch == ')': depth -= 1
            elif depth == 0: flat.append(ch)
        args_top = ''.join(flat)
        for lm in re.finditer(r'(?:^|,)\s*(\w+)\s*:', args_top):
            label = lm.group(1)
            if not re.search(r'\b' + re.escape(label) + r'\b', body):
                add('ПОДПИСЬ', f, text[:m.start()].count('\n') + 1,
                    f'{name}(…): метки «{label}» в объявлении нет '
                    f'({os.path.basename(bodies[name]["file"])})')

out.sort(key=lambda p: (p[0], p[1], p[2]))
for kind, f, line, msg in out:
    print(f'{kind:12} {f}:{line}  {msg}')
print(f'\nфайлов проверено: {len(files)}, замечаний: {len(out)}')
sys.exit(1 if out else 0)
