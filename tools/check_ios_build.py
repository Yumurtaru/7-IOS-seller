#!/usr/bin/env python3
"""
Проверки того, что уже роняло сборку в Codemagic (компилятора Swift здесь нет):
  1. API новее цели развёртывания (iOS 16.0 по project.yml).
  2. Метки аргументов, которых у вызываемого типа нет ВООБЩЕ.
  3. ПРОБЕЛЫ: пробел только с одной стороны «=», «==», «&&»… (`let a =f()`).
  4. СКОРОСТЬ: длинная склейка строк «+» внутри Text(…) — Xcode 26 не успевает
     проверить типы. Склеивать интерполяцией.
Запуск: из папки проекта `T=Sources py -3 tools/check_ios_build.py`
(админке и курьеру — тот же файл из 8 IOS-client-new/tools).

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

# ── 3) и 4): по коду без строк и комментариев ───────────────────────────────
def code_only(text):
    """Та же длина и те же переводы строк; содержимое строковых литералов —
    'x' (кавычки остаются), комментарии — пробелы. Интерполяция \\( … ) — тоже 'x'."""
    o, i, n = list(text), 0, len(text)
    def blank(a, b, ch):
        for k in range(a, b):
            if o[k] != '\n': o[k] = ch
    def skip_str(j, hashes, multi):
        """j — первый знак после открывающей кавычки; вернуть индекс после закрывающей."""
        close = ('"""' if multi else '"') + '#' * hashes
        while j < n:
            c = text[j]
            if c == '\n' and not multi and hashes == 0: return j
            if c == '\\' and text[j + 1:j + 1 + hashes] == '#' * hashes:
                k = j + 1 + hashes
                if k < n and text[k] == '(':          # интерполяция
                    depth, k = 1, k + 1
                    while k < n and depth:
                        if text[k] == '(': depth += 1
                        elif text[k] == ')': depth -= 1
                        elif text[k] == '"': k = skip_str(k + 1, 0, False) - 1
                        k += 1
                    j = k; continue
                j = k + 1; continue
            if text.startswith(close, j): return j + len(close)
            j += 1
        return n
    while i < n:
        c = text[i]
        if text.startswith('//', i):
            e = text.find('\n', i); e = n if e < 0 else e
            blank(i, e, ' '); i = e; continue
        if text.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith('/*', j): depth += 1; j += 2
                elif text.startswith('*/', j): depth -= 1; j += 2
                else: j += 1
            blank(i, j, ' '); i = j; continue
        m = re.match(r'(#*)("""|")', text[i:i + 12])
        if m and (m.group(1) == '' or text[i:i + len(m.group(0))] == m.group(0)) and (c == '"' or c == '#'):
            h, q = len(m.group(1)), m.group(2)
            s = i + h + len(q)
            e = skip_str(s, h, q == '"""')
            end_q = len(q) + h
            blank(s, max(s, e - end_q), 'x'); i = e; continue
        i += 1
    return ''.join(o)

code = {f: code_only(t) for f, t in src.items()}

# 3) «'=' must have consistent whitespace on both sides» — пробел только с одной
#    стороны инфиксного оператора (AssistantModels.swift: `let help =rx(…)`).
OPS = r'(?:==|!=|\+=|-=|\*=|/=|&&|\|\||\?\?|=)'
for f, text in code.items():
    for i, ln in enumerate(text.split('\n'), 1):
        for m in re.finditer(r'(?<=[ \t])' + OPS + r'(?=[^\s=&|?>])', ln):
            add('ПРОБЕЛЫ', f, i, f'«{m.group(0)}»: пробел слева есть, справа нет')
        for m in re.finditer(r'(?<=[\w)\]"])' + OPS + r'(?=[ \t])', ln):
            add('ПРОБЕЛЫ', f, i, f'«{m.group(0)}»: пробел справа есть, слева нет')

# 4) Длинная склейка строк через «+» в одном выражении: Xcode 26 не успевает
#    вывести типы («unable to type-check this expression in reasonable time»,
#    AppsNotifyView.swift). Склеивать интерполяцией "\(a) / \(b)".
for f, text in code.items():
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        start, stmt = i, lines[i]
        while i + 1 < len(lines) and re.match(r'\s*\+', lines[i + 1]):
            i += 1; stmt += ' ' + lines[i]
        pluses = len(re.findall(r'(?<![+=])\+(?![+=])', stmt))
        # Медленно именно внутри Text(…): у Text много init (String,
        # LocalizedStringKey, AttributedString…), перебор растёт экспоненциально.
        # Такие же цепочки вне Text Xcode 26 собирает (сборки проходили), внутри
        # Text — до 6 частей собирал (продавец, админка), на 9 частях упал.
        # Text(…) + Text(…) — другое (склейка Text), его не считаем.
        if pluses >= 6 and '"' in stmt and re.search(r'\bText\(', stmt) \
                and not re.search(r'\+\s*Text\(', stmt):
            add('СКОРОСТЬ', f, start + 1, f'склейка строк из {pluses + 1} частей через «+» — заменить интерполяцией')
        i += 1

out.sort(key=lambda p: (p[0], p[1], p[2]))
for kind, f, line, msg in out:
    print(f'{kind:12} {f}:{line}  {msg}')
print(f'\nфайлов проверено: {len(files)}, замечаний: {len(out)}')
sys.exit(1 if out else 0)
