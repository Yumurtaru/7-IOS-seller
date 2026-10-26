# -*- coding: utf-8 -*-
"""
Карточка приложения в App Store Connect — из файлов репозитория (общий скрипт
курьера, клиента и продавца; у клиента и продавца — режимы version и check).

    python3 ci/asc_store.py apply   заполнить карточку (тексты, скриншоты,
                                    информация о приложении, сведения для
                                    проверки, возрастной рейтинг)
    python3 ci/asc_store.py check   готова ли карточка к подаче на проверку
    python3 ci/asc_store.py version только карточка версии: найти редактируемую,
                                    переименовать в номер из project.yml или
                                    создать (для обновлений: иначе 409 whatsNew)

Источник правды — репозиторий:
    store/app.json              категории, язык, ответы анкеты возраста
    store/ru/*.txt              название, подзаголовок, рекламный текст,
                                описание, ключевые слова, ссылки
    store/review_notes.txt      заметки для проверяющего Apple
    store/screenshots/<ТИП>/    скриншоты (ТИП — как у Apple: APP_IPHONE_67
                                для 6,7–6,9″, APP_IPHONE_65 для 6,5″)

Секреты — только в переменных Codemagic (группа yumurta_courier_review):
    REVIEW_CONTACT_FIRST_NAME, REVIEW_CONTACT_LAST_NAME, REVIEW_CONTACT_PHONE,
    REVIEW_CONTACT_EMAIL (иначе review_contact_email из app.json),
    REVIEW_DEMO_LOGIN, REVIEW_DEMO_PASSWORD, REVIEW_VIDEO_URL (необязательно).
Ключ App Store Connect даёт интеграция yumurta_asc: APP_STORE_CONNECT_ISSUER_ID,
APP_STORE_CONNECT_KEY_IDENTIFIER, APP_STORE_CONNECT_PRIVATE_KEY.

Прочие переключатели:
    STORE_SCREENSHOTS_REPLACE=1  заменить скриншоты, которые уже есть в карточке
                                 (без него уже загруженные не трогаем)
    STORE_MANUAL_DONE=1          владелец сделал то, чего нет в API Apple
                                 (анкета «Конфиденциальность», цена) — нужно
                                 только перед ПЕРВОЙ подачей
    APP_VERSION                  номер версии (иначе из project.yml)
    APP_STORE_APP_ID             id приложения (иначе ищем по bundle id)

Коды выхода:
    apply — всегда 0: шаг-обслуживание сборку не роняет, обо всём пишет в лог.
    check — 2, если ТОЧНО известно, что подача не пройдёт (чего не хватает —
            в логе); 0 — готово или проверить не удалось (тогда так и пишет).
"""
import hashlib
import json
import os
import re
import struct
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.environ.get("ASC_API_BASE", "https://api.appstoreconnect.apple.com").rstrip("/")

# Состояния карточки версии, в которых её можно править.
VERSION_EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                    "METADATA_REJECTED", "INVALID_BINARY", "READY_FOR_REVIEW"}
# Версия хоть раз была в продаже — значит, это обновление, а не первый выпуск.
SOLD = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION",
        "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"}
# Версия подана и ждёт Apple: новая сборка в неё не попадёт, а новую карточку
# Apple не даст создать, пока эта не решена (ошибка 22.10.2026, клиент 1.2).
IN_REVIEW = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_DISTRIBUTION",
             "PROCESSING_FOR_APP_STORE"}
# Одобрена или выпущена: номер версии закрыт, нужен следующий.
CLOSED = SOLD | {"PENDING_DEVELOPER_RELEASE", "ACCEPTED", "APPROVED", "PREORDER_READY_FOR_SALE"}
APPINFO_EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                    "METADATA_REJECTED", "READY_FOR_REVIEW"}

# Размеры скриншотов, которые Apple принимает для каждого типа (портрет и пейзаж).
SHOT_SIZES = {
    "APP_IPHONE_67": {(1290, 2796), (1320, 2868), (1260, 2736), (2796, 1290), (2868, 1320), (2736, 1260)},
    "APP_IPHONE_65": {(1242, 2688), (1284, 2778), (2688, 1242), (2778, 1284)},
    "APP_IPHONE_61": {(1179, 2556), (1206, 2622), (2556, 1179), (2622, 1206)},
    "APP_IPHONE_55": {(1242, 2208), (2208, 1242)},
}
# Хватит одного из них — остальные размеры Apple получит масштабированием.
SHOT_REQUIRED_ANY = ("APP_IPHONE_67", "APP_IPHONE_65")

# Поля анкеты возраста, которые НЕ вопросы (переопределения, ссылки, номера) —
# их пустота подаче не мешает. socialMediaAgeRestricted — уточнение к
# socialMedia: нужен, только если socialMedia = true.
AGE_NOT_QUESTIONS = {"kidsAgeBand", "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride",
                     "gracRatingClassificationNumber", "developerAgeRatingInfoUrl", "seventeenPlus",
                     "socialMediaAgeRestricted"}


def age_unanswered(cur):
    """Вопросы анкеты без ответа — по всей анкете Apple, а не только по app.json."""
    left = [k for k, v in cur.items() if v is None and k not in AGE_NOT_QUESTIONS]
    if cur.get("socialMedia") is True and cur.get("socialMediaAgeRestricted") is None:
        left.append("socialMediaAgeRestricted")
    return sorted(left)


LIMITS = {"name": 30, "subtitle": 30, "promotionalText": 170, "keywords": 100,
          "description": 4000, "notes": 4000}


def say(*a):
    print(*a)
    sys.stdout.flush()


class ApiError(Exception):
    def __init__(self, status, text):
        Exception.__init__(self, "HTTP %s: %s" % (status, text[:400]))
        self.status = status
        self.text = text


class Asc(object):
    """Маленький клиент App Store Connect API (JWT ES256, JSON:API)."""

    def __init__(self, issuer, key_id, private_key):
        import jwt  # PyJWT — ставится вместе с codemagic-cli-tools
        import requests
        self._jwt = jwt
        self._rq = requests.Session()
        self.issuer, self.key_id, self.key = issuer, key_id, private_key
        self._tok, self._tok_at = None, 0

    def _token(self):
        if self._tok and time.time() - self._tok_at < 600:
            return self._tok
        now = int(time.time())
        t = self._jwt.encode({"iss": self.issuer, "iat": now, "exp": now + 1100,
                              "aud": "appstoreconnect-v1"},
                             self.key, algorithm="ES256",
                             headers={"kid": self.key_id, "typ": "JWT"})
        self._tok = t.decode() if isinstance(t, bytes) else t
        self._tok_at = time.time()
        return self._tok

    def call(self, method, path, body=None, params=None, ok404=False):
        url = path if path.startswith("http") else API + path
        for attempt in range(3):
            r = self._rq.request(method, url, params=params,
                                 data=json.dumps(body) if body is not None else None,
                                 headers={"Authorization": "Bearer " + self._token(),
                                          "Content-Type": "application/json"},
                                 timeout=60)
            if r.status_code == 401 and attempt < 2:
                self._tok = None
                continue
            if r.status_code >= 500 and attempt < 2:
                time.sleep(3)
                continue
            break
        if ok404 and r.status_code == 404:
            return None
        if r.status_code >= 400:
            raise ApiError(r.status_code, r.text)
        if not r.content:
            return {}
        return r.json()

    def get(self, path, params=None, ok404=False):
        return self.call("GET", path, params=params, ok404=ok404)

    def data(self, path, params=None, ok404=False):
        """Список (или один объект) из ответа, всегда списком."""
        j = self.get(path, params=params, ok404=ok404)
        d = (j or {}).get("data")
        if d is None:
            return []
        return d if isinstance(d, list) else [d]

    def upload(self, op, blob):
        h = {x["name"]: x["value"] for x in (op.get("requestHeaders") or [])}
        part = blob[op.get("offset", 0): op.get("offset", 0) + op.get("length", len(blob))]
        r = self._rq.request(op.get("method", "PUT"), op["url"], data=part, headers=h, timeout=120)
        if r.status_code >= 400:
            raise ApiError(r.status_code, r.text)


# ─────────────────────────── файлы репозитория ───────────────────────────

def read_text(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8") as f:
        t = f.read().replace("\r\n", "\n").strip()
    return t or None


def load_config():
    with open(os.path.join(ROOT, "store", "app.json"), encoding="utf-8") as f:
        return json.load(f)


def project_version():
    v = os.environ.get("APP_VERSION", "").strip()
    if v:
        return v
    t = read_text("project.yml") or ""
    m = re.search(r'CFBundleShortVersionString:\s*"?([0-9.]+)"?', t)
    return m.group(1) if m else ""


def cut(text, limit, what):
    if text is None or len(text) <= limit:
        return text
    say("  ВНИМАНИЕ: %s длиннее %d символов (%d) — обрезаю по строке." % (what, limit, len(text)))
    u = text[:limit]
    i = u.rfind("\n")
    return (u[:i] if i > limit * 3 // 4 else u).rstrip()


def env(name):
    v = os.environ.get(name, "").strip()
    return v or None


def image_size(path):
    with open(path, "rb") as f:
        head = f.read(26)
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            w, h = struct.unpack(">II", head[16:24])
            return w, h
        if head[:2] == b"\xff\xd8":
            f.seek(2)
            while True:
                b = f.read(1)
                while b and b != b"\xff":
                    b = f.read(1)
                while b == b"\xff":
                    b = f.read(1)
                if not b:
                    return None
                m = b[0]
                if m in (0xD8, 0x01) or 0xD0 <= m <= 0xD7:
                    continue
                ln = struct.unpack(">H", f.read(2))[0]
                if m in (0xC0, 0xC1, 0xC2):
                    f.read(1)
                    h, w = struct.unpack(">HH", f.read(4))
                    return w, h
                f.seek(ln - 2, 1)
    return None


def local_shots():
    """{ТИП: [пути]} — только подходящие по размеру, по имени файла."""
    base = os.path.join(ROOT, "store", "screenshots")
    out = {}
    if not os.path.isdir(base):
        return out
    for t in sorted(os.listdir(base)):
        d = os.path.join(base, t)
        if not os.path.isdir(d):
            continue
        files = sorted(x for x in os.listdir(d) if x.lower().endswith((".png", ".jpg", ".jpeg")))
        if not files:
            continue
        if t not in SHOT_SIZES:
            say("  Скриншоты: папка %s — неизвестный тип, пропускаю (известные: %s)." % (t, ", ".join(sorted(SHOT_SIZES))))
            continue
        good = []
        for x in files:
            p = os.path.join(d, x)
            sz = image_size(p)
            if sz not in SHOT_SIZES[t]:
                say("  Скриншоты: %s/%s — размер %s не подходит для %s (нужно %s), пропускаю."
                    % (t, x, "%dx%d" % sz if sz else "не прочитан", t,
                       " или ".join("%dx%d" % s for s in sorted(SHOT_SIZES[t]) if s[0] < s[1])))
                continue
            good.append(p)
        if len(good) > 10:
            say("  Скриншоты: в %s больше 10 файлов — Apple берёт не больше 10, лишние пропускаю." % t)
            good = good[:10]
        if good:
            out[t] = good
    return out


# ─────────────────────────── поиск в App Store Connect ───────────────────────────

def attrs(x):
    return (x or {}).get("attributes") or {}


def vstate(v):
    a = attrs(v)
    return a.get("appVersionState") or a.get("appStoreState") or a.get("state") or ""


def find_app(asc, bundle):
    aid = env("APP_STORE_APP_ID")
    if aid:
        return aid
    for x in asc.data("/v1/apps", params={"filter[bundleId]": bundle, "limit": 200}):
        if attrs(x).get("bundleId") == bundle:
            return x["id"]
    return None


def versions(asc, app_id):
    return asc.data("/v1/apps/%s/appStoreVersions" % app_id,
                    params={"filter[platform]": "IOS", "limit": 200})


REVIEW_HELP = ("Варианты: (1) дождаться решения Apple, затем поднять номер версии в project.yml "
               "(CFBundleShortVersionString и все MARKETING_VERSION) и запустить снова; "
               "(2) App Store Connect → эта версия → «Удалить из проверки» — карточка станет редактируемой, "
               "и следующий запуск положит в неё новую сборку (место в очереди Apple теряется)")


def busy_reason(number, state):
    """Почему карточку версии number нельзя взять, и что делать — человеческим языком."""
    if state in IN_REVIEW:
        return "версия %s уже подана и ждёт Apple (%s) — новая сборка в неё не попадёт. %s" % (number, state, REVIEW_HELP)
    if state in CLOSED:
        return ("версия %s уже одобрена или выпущена (%s) — номер закрыт: поднимите номер версии в project.yml "
                "(CFBundleShortVersionString и все MARKETING_VERSION) и «Что нового» в release-notes/ru.txt" % (number, state))
    return "карточка версии %s в состоянии %s — править нельзя" % (number, state or "?")


def pick_version(asc, app_id, number, create):
    """(версия, первый_ли_выпуск, почему_нет). Редактируемая карточка версии."""
    vs = versions(asc, app_id)
    first = not any(({attrs(v).get("appStoreState"), attrs(v).get("appVersionState")} & SOLD) for v in vs)
    mine = [v for v in vs if attrs(v).get("versionString") == number]
    if mine:
        v = mine[0]
        if vstate(v) in VERSION_EDITABLE:
            return v, first, None
        return None, first, busy_reason(number, vstate(v))
    editable = [v for v in vs if vstate(v) in VERSION_EDITABLE]
    if editable:
        v = editable[0]
        old = attrs(v).get("versionString")
        if not create:
            return v, first, None
        # Публикация Codemagic всё равно переименовала бы её в наш номер —
        # делаем это сами, чтобы следующие шаги находили карточку по номеру.
        try:
            asc.call("PATCH", "/v1/appStoreVersions/%s" % v["id"], body={"data": {
                "type": "appStoreVersions", "id": v["id"], "attributes": {"versionString": number}}})
            say("  Карточка версии %s переименована в %s." % (old, number))
            v.setdefault("attributes", {})["versionString"] = number
        except ApiError as e:
            say("  Переименовать карточку %s в %s не удалось (%s) — работаю с ней как есть." % (old, number, e))
        return v, first, None
    waiting = [v for v in vs if vstate(v) in IN_REVIEW]
    hint = ""
    if waiting:
        w = waiting[0]
        wv = attrs(w).get("versionString") or "?"
        hint = (" Версия %s ещё на проверке у Apple (%s) — пока её не решат, новую карточку %s Apple не даёт создать. "
                "Номер %s в project.yml уже новый, менять его не нужно. Варианты: (1) дождаться решения Apple по %s "
                "(одобрят — выпустить её, откажут — она станет редактируемой) и запустить эту сборку снова; "
                "(2) сейчас: App Store Connect → версия %s → «Удалить из проверки», затем запустить снова — "
                "карточка %s станет %s и получит эту сборку (место в очереди Apple теряется)"
                % (wv, vstate(w), number, number, wv, wv, wv, number))
    if not create:
        if waiting:
            return None, first, "карточки версии %s нет." % number + hint
        return None, first, "редактируемой карточки версии нет — её создаст шаг «Карточка версии» (режим version) или «+ Версия» в App Store Connect"
    try:
        j = asc.call("POST", "/v1/appStoreVersions", body={"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": number},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
        say("  Создана карточка версии %s." % number)
        return j["data"], first, None
    except ApiError as e:
        return None, first, "создать карточку версии %s не удалось: %s.%s" % (number, e, hint)


def pick_locale(items, want, key="locale"):
    for x in items:
        if attrs(x).get(key) == want:
            return x
    return items[0] if items else None


def editable_appinfo(asc, app_id):
    infos = asc.data("/v1/apps/%s/appInfos" % app_id)
    for i in infos:
        a = attrs(i)
        if (a.get("state") or a.get("appStoreState")) in APPINFO_EDITABLE:
            return i
    return None


# ─────────────────────────── заполнение ───────────────────────────

def patch_diff(asc, typ, obj, want, label):
    """Записать только то, что отличается. Пустое в репозитории — не трогаем."""
    cur = attrs(obj)
    ch = {k: v for k, v in want.items() if v is not None and (cur.get(k) or "") != v}
    if not ch:
        say("  %s — без изменений." % label)
        return True
    try:
        asc.call("PATCH", "/v1/%s/%s" % (typ, obj["id"]),
                 body={"data": {"type": typ, "id": obj["id"], "attributes": ch}})
        say("  %s — записано: %s." % (label, ", ".join(sorted(ch))))
        return True
    except ApiError as e:
        say("  %s — записать не удалось: %s" % (label, e))
        # По одному полю — чтобы одно неудачное (имя занято и т.п.) не мешало остальным.
        if len(ch) > 1:
            for k, v in sorted(ch.items()):
                try:
                    asc.call("PATCH", "/v1/%s/%s" % (typ, obj["id"]),
                             body={"data": {"type": typ, "id": obj["id"], "attributes": {k: v}}})
                    say("    %s — записано отдельно." % k)
                except ApiError as e2:
                    say("    %s — не записано: %s" % (k, e2))
        return False


def texts(cfg):
    loc = cfg.get("locale", "ru")
    g = lambda n: read_text("store/%s/%s.txt" % (loc, n))
    return {
        "name": cut(g("name"), LIMITS["name"], "Название"),
        "subtitle": cut(g("subtitle"), LIMITS["subtitle"], "Подзаголовок"),
        "privacyPolicyUrl": g("privacy_url"),
    }, {
        "description": cut(g("description"), LIMITS["description"], "Описание"),
        "keywords": cut(g("keywords"), LIMITS["keywords"], "Ключевые слова"),
        "promotionalText": cut(g("promotional_text"), LIMITS["promotionalText"], "Рекламный текст"),
        "supportUrl": g("support_url"),
        "marketingUrl": g("marketing_url"),
    }


def review_wanted(cfg):
    notes = read_text("store/review_notes.txt")
    if notes:
        video = env("REVIEW_VIDEO_URL")
        lines = []
        for ln in notes.split("\n"):
            if "[INSERT SCREEN RECORDING LINK]" in ln:
                if not video:
                    continue
                ln = ln.replace("[INSERT SCREEN RECORDING LINK]", video)
            lines.append(ln)
        notes = cut("\n".join(lines).strip(), LIMITS["notes"], "Заметки для проверяющего")
    w = {
        "contactFirstName": env("REVIEW_CONTACT_FIRST_NAME"),
        "contactLastName": env("REVIEW_CONTACT_LAST_NAME"),
        "contactPhone": env("REVIEW_CONTACT_PHONE"),
        "contactEmail": env("REVIEW_CONTACT_EMAIL") or cfg.get("review_contact_email"),
        "demoAccountName": env("REVIEW_DEMO_LOGIN"),
        "demoAccountPassword": env("REVIEW_DEMO_PASSWORD"),
        "notes": notes,
    }
    return {k: v for k, v in w.items() if v}


def do_review(asc, ver, cfg):
    want = review_wanted(cfg)
    want["demoAccountRequired"] = bool(cfg.get("demo_account_required", True))
    d = asc.data("/v1/appStoreVersions/%s/appStoreReviewDetail" % ver["id"], ok404=True)
    shown = [k for k in sorted(want) if k not in ("demoAccountPassword", "notes")]
    if d:
        cur = attrs(d[0])
        ch = {k: v for k, v in want.items() if cur.get(k) != v}
        if not ch:
            say("  Сведения для проверки — без изменений.")
            return
        try:
            asc.call("PATCH", "/v1/appStoreReviewDetails/%s" % d[0]["id"],
                     body={"data": {"type": "appStoreReviewDetails", "id": d[0]["id"], "attributes": ch}})
            say("  Сведения для проверки — записано: %s." % ", ".join(sorted(ch)))
        except ApiError as e:
            say("  Сведения для проверки — записать не удалось: %s" % e)
        return
    try:
        asc.call("POST", "/v1/appStoreReviewDetails", body={"data": {
            "type": "appStoreReviewDetails", "attributes": want,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver["id"]}}}}})
        say("  Сведения для проверки — созданы (%s%s)." % (", ".join(shown),
            ", пароль" if "demoAccountPassword" in want else ""))
    except ApiError as e:
        say("  Сведения для проверки — создать не удалось: %s" % e)


def do_categories(asc, info, cfg):
    rel = {}
    for key, rk in (("primary_category", "primaryCategory"), ("secondary_category", "secondaryCategory")):
        want = cfg.get(key)
        if not want:
            continue
        cur = asc.data("/v1/appInfos/%s/%s" % (info["id"], rk), ok404=True)
        if cur and cur[0].get("id") == want:
            continue
        rel[rk] = {"data": {"type": "appCategories", "id": want}}
    if not rel:
        say("  Категории — без изменений.")
        return
    try:
        asc.call("PATCH", "/v1/appInfos/%s" % info["id"],
                 body={"data": {"type": "appInfos", "id": info["id"], "relationships": rel}})
        say("  Категории — записано: %s." % ", ".join("%s=%s" % (k, v["data"]["id"]) for k, v in sorted(rel.items())))
    except ApiError as e:
        say("  Категории — записать не удалось: %s" % e)


def do_age(asc, info, cfg):
    """Только НЕзаполненные вопросы, по одному: анкета Apple меняется, а
    неизвестное поле в общем запросе сорвало бы и все остальные."""
    answers = cfg.get("age_rating") or {}
    d = asc.data("/v1/appInfos/%s/ageRatingDeclaration" % info["id"], ok404=True)
    if not d:
        say("  Возрастной рейтинг — анкета не найдена, пропускаю.")
        return
    decl = d[0]
    cur = attrs(decl)
    todo = {k: v for k, v in answers.items() if k in cur and cur.get(k) is None}
    if not todo:
        left = age_unanswered(cur)
        if left:
            say("  Возрастной рейтинг — без ответа: %s. Впишите ответ в store/app.json (age_rating) или ответьте в App Store Connect." % ", ".join(left))
        else:
            say("  Возрастной рейтинг — уже заполнен, не трогаю.")
        return
    okn, bad = 0, []
    for k, v in sorted(todo.items()):
        try:
            asc.call("PATCH", "/v1/ageRatingDeclarations/%s" % decl["id"],
                     body={"data": {"type": "ageRatingDeclarations", "id": decl["id"], "attributes": {k: v}}})
            okn += 1
        except ApiError as e:
            bad.append("%s (%s)" % (k, e.status))
    say("  Возрастной рейтинг — записано ответов: %d%s." % (okn, ("; не приняты: " + ", ".join(bad)) if bad else ""))
    cur = dict(cur, **{k: v for k, v in todo.items() if k not in [b.split(" ")[0] for b in bad]})
    left = age_unanswered(cur)
    if left:
        say("  Возрастной рейтинг — без ответа: %s. Впишите ответ в store/app.json (age_rating) или ответьте в App Store Connect." % ", ".join(left))


def do_content_rights(asc, app_id, cfg):
    want = cfg.get("content_rights")
    if not want:
        return
    j = asc.get("/v1/apps/%s" % app_id)
    if attrs(j.get("data")).get("contentRightsDeclaration"):
        say("  Права на контент — уже указаны.")
        return
    try:
        asc.call("PATCH", "/v1/apps/%s" % app_id, body={"data": {
            "type": "apps", "id": app_id, "attributes": {"contentRightsDeclaration": want}}})
        say("  Права на контент — записано.")
    except ApiError as e:
        say("  Права на контент — записать не удалось: %s" % e)


SHOT_OK = {"COMPLETE", "UPLOAD_COMPLETE"}


def shot_state(x):
    return (attrs(x).get("assetDeliveryState") or {}).get("state") or ""


def shot_sets(asc, loc_id):
    return {attrs(s).get("screenshotDisplayType"): s
            for s in asc.data("/v1/appStoreVersionLocalizations/%s/appScreenshotSets" % loc_id, params={"limit": 50})}


def do_screens(asc, loc):
    mine = local_shots()
    if not mine:
        say("  Скриншоты — в store/screenshots/ нет подходящих файлов, пропускаю.")
        return
    replace = env("STORE_SCREENSHOTS_REPLACE") == "1"
    sets = shot_sets(asc, loc["id"])
    for typ, files in sorted(mine.items()):
        s = sets.get(typ)
        if s:
            have = asc.data("/v1/appScreenshotSets/%s/appScreenshots" % s["id"], params={"limit": 50})
            broken = [h for h in have if shot_state(h) not in SHOT_OK]
            if have and not replace and not broken:
                say("  Скриншоты %s — в карточке уже %d, не трогаю (заменить: STORE_SCREENSHOTS_REPLACE=1)." % (typ, len(have)))
                continue
            if broken and not replace:
                # Недогруженная заготовка (AWAITING_UPLOAD) или отказ Apple (FAILED) —
                # подача с ними не пройдёт: перезаливаем набор целиком, по порядку.
                say("  Скриншоты %s — %d из %d не загружены до конца или отклонены Apple — перезаливаю набор."
                    % (typ, len(broken), len(have)))
            for h in have:
                try:
                    asc.call("DELETE", "/v1/appScreenshots/%s" % h["id"])
                except ApiError as e:
                    say("  Скриншоты %s — удалить старый не удалось: %s" % (typ, e))
            if have:
                say("  Скриншоты %s — старые удалены: %d." % (typ, len(have)))
        else:
            try:
                s = asc.call("POST", "/v1/appScreenshotSets", body={"data": {
                    "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": typ},
                    "relationships": {"appStoreVersionLocalization": {"data": {
                        "type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
            except ApiError as e:
                say("  Скриншоты %s — создать набор не удалось: %s" % (typ, e))
                continue
        done = 0
        for p in files:
            blob = open(p, "rb").read()
            name = os.path.basename(p)
            r = None
            try:
                r = asc.call("POST", "/v1/appScreenshots", body={"data": {
                    "type": "appScreenshots", "attributes": {"fileName": name, "fileSize": len(blob)},
                    "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": s["id"]}}}}})["data"]
                for op in attrs(r).get("uploadOperations") or []:
                    asc.upload(op, blob)
                asc.call("PATCH", "/v1/appScreenshots/%s" % r["id"], body={"data": {
                    "type": "appScreenshots", "id": r["id"],
                    "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
                done += 1
            except ApiError as e:
                say("  Скриншоты %s — %s не загружен: %s" % (typ, name, e))
                # Заготовку не оставляем: иначе она висит в AWAITING_UPLOAD и мешает подаче.
                if r and r.get("id"):
                    try:
                        asc.call("DELETE", "/v1/appScreenshots/%s" % r["id"])
                    except ApiError:
                        say("    (заготовку удалить не удалось — следующий запуск перезальёт набор)")
        say("  Скриншоты %s — загружено %d из %d (Apple обрабатывает их ещё пару минут)." % (typ, done, len(files)))


# ─────────────────────────── режимы ───────────────────────────

def connect():
    iss, kid = env("APP_STORE_CONNECT_ISSUER_ID"), env("APP_STORE_CONNECT_KEY_IDENTIFIER")
    key = os.environ.get("APP_STORE_CONNECT_PRIVATE_KEY", "")
    if key.startswith("@env:"):
        key = os.environ.get(key[5:], "")
    elif key.startswith("@file:"):
        try:
            key = open(os.path.expanduser(key[6:])).read()
        except OSError:
            key = ""
    if not key.strip() and kid:
        for d in ("private_keys", "~/private_keys", "~/.private_keys", "~/.appstoreconnect/private_keys"):
            p = os.path.join(os.path.expanduser(d), "AuthKey_%s.p8" % kid)
            if os.path.isfile(p):
                key = open(p).read()
                break
    if not (iss and kid and key.strip()):
        return None, "нет ключа App Store Connect (интеграция yumurta_asc в блоке integrations)"
    try:
        return Asc(iss, kid, key.replace("\\n", "\n")), None
    except ImportError as e:
        return None, "нет библиотеки Python (%s) — её ставит codemagic-cli-tools" % e


def guarded(label, fn, *a):
    """Один раздел карточки упал — остальные всё равно заполняем."""
    try:
        return fn(*a)
    except ApiError as e:
        say("  %s — App Store Connect ответил ошибкой: %s" % (label, e))
    except Exception as e:  # noqa — шаг-обслуживание
        say("  %s — непредвиденная ошибка %s: %s" % (label, type(e).__name__, e))
    return None


def notes_text():
    """«Что нового»: APP_STORE_WHATS_NEW → файл APP_STORE_WHATS_NEW_FILE →
    release-notes/ru.txt (как шаг «Что нового» в codemagic.yaml)."""
    t = env("APP_STORE_WHATS_NEW")
    if t:
        return t, "переменная APP_STORE_WHATS_NEW"
    f = env("APP_STORE_WHATS_NEW_FILE") or "release-notes/ru.txt"
    t = read_text(f)
    return (cut(t, 4000, "«Что нового»") if t else None), f


def fill_whats_new(asc, ver, first):
    """Вписать «Что нового» в ТУ ЖЕ карточку версии, которую потом проверяет
    шлагбаум (21.10.2026: шаг CLI «Что нового» однажды не вписал текст, а
    причина в логе не видна). Пустые поля — во все локализации; заполненное
    не трогаем без APP_STORE_WHATS_NEW_FORCE=1. Ошибку Apple печатаем целиком."""
    if first:
        say("  «Что нового»: первый выпуск — у первой версии этого поля нет, пропускаю.")
        return
    text, src = notes_text()
    if not text:
        say("  «Что нового»: текста нет (%s пуст или отсутствует) — подача обновления упадёт на 409 whatsNew." % src)
        return
    force = env("APP_STORE_WHATS_NEW_FORCE") == "1"
    locs = asc.data("/v1/appStoreVersions/%s/appStoreVersionLocalizations" % ver["id"])
    if not locs:
        say("  «Что нового»: у карточки версии нет локализаций — вписать некуда.")
        return
    for loc in locs:
        a = attrs(loc)
        name = a.get("locale") or "?"
        if (a.get("whatsNew") or "").strip() and not force:
            say("  «Что нового» (%s) — уже заполнено, не трогаю (перезаписать: APP_STORE_WHATS_NEW_FORCE=1)." % name)
            continue
        try:
            asc.call("PATCH", "/v1/appStoreVersionLocalizations/%s" % loc["id"], body={"data": {
                "type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"whatsNew": text}}})
            # Перечитываем: записалось ли на самом деле.
            back = attrs((asc.get("/v1/appStoreVersionLocalizations/%s" % loc["id"]) or {}).get("data"))
            ok = (back.get("whatsNew") or "").strip() != ""
            say("  «Что нового» (%s) — %s (из %s, %d симв.)." % (name, "записано" if ok else "Apple принял запрос, но поле пустое", src, len(text)))
        except ApiError as e:
            say("  «Что нового» (%s) — Apple не принял: %s" % (name, e))


def apply_version_only(asc, cfg):
    """Только карточка версии: найти редактируемую, переименовать в наш номер
    или создать. Без неё «Что нового» некуда вписать, а подача обновления
    падает с 409 whatsNew (Codemagic создаёт карточку уже после сборки)."""
    app_id = find_app(asc, cfg["bundle_id"])
    if not app_id:
        say("Карточки приложения %s в App Store Connect нет." % cfg["bundle_id"])
        return None, None
    number = project_version()
    ver, first, why = pick_version(asc, app_id, number, create=True)
    if ver:
        say("Карточка версии %s (%s, id %s) готова." % (attrs(ver).get("versionString"), vstate(ver) or "?", ver["id"]))
        guarded("«Что нового»", fill_whats_new, asc, ver, first)
    else:
        say("Карточки версии нет: %s." % why)
    return app_id, ver


def apply(asc, cfg):
    app_id, ver = apply_version_only(asc, cfg)
    if not app_id:
        return
    say("Приложение %s, версия %s." % (app_id, project_version() or "?"))
    info_t, ver_t = texts(cfg)

    # Информацию о приложении читаем ПОСЛЕ карточки версии: у обновления
    # редактируемая «Информация о приложении» появляется только вместе с ней.
    say("— Информация о приложении")
    info = guarded("Информация о приложении", editable_appinfo, asc, app_id)
    if info:
        loc = guarded("Локализация", lambda: pick_locale(asc.data("/v1/appInfos/%s/appInfoLocalizations" % info["id"]), cfg.get("locale", "ru")))
        if loc:
            guarded("Название", patch_diff, asc, "appInfoLocalizations", loc, info_t, "Название, подзаголовок, политика (%s)" % attrs(loc).get("locale"))
        guarded("Категории", do_categories, asc, info, cfg)
        guarded("Возрастной рейтинг", do_age, asc, info, cfg)
    else:
        say("  Сейчас не редактируется (идёт проверка или нет новой версии) — пропускаю.")
    guarded("Права на контент", do_content_rights, asc, app_id, cfg)

    say("— Страница версии")
    if not ver:
        say("  Пропускаю: карточки версии нет.")
        return
    loc = guarded("Локализация версии", lambda: pick_locale(asc.data("/v1/appStoreVersions/%s/appStoreVersionLocalizations" % ver["id"]), cfg.get("locale", "ru")))
    if not loc:
        say("  У версии нет локализации — пропускаю тексты и скриншоты.")
    else:
        guarded("Тексты версии", patch_diff, asc, "appStoreVersionLocalizations", loc, ver_t,
                "Описание, ключевые слова, рекламный текст, ссылки (%s)" % attrs(loc).get("locale"))
        guarded("Скриншоты", do_screens, asc, loc)
    say("— Сведения для проверки")
    guarded("Сведения для проверки", do_review, asc, ver, cfg)


def check(asc, cfg):
    """Список того, без чего Apple точно не примет заявку."""
    miss, warn = [], []
    bundle = cfg["bundle_id"]
    app_id = find_app(asc, bundle)
    if not app_id:
        return ["карточки приложения %s в App Store Connect нет" % bundle], warn
    number = project_version()
    ver, first, why = pick_version(asc, app_id, number, create=False)
    full = cfg.get("gate", "full") != "update"
    if first and full and env("STORE_MANUAL_DONE") != "1":
        miss.append("ПЕРВЫЙ выпуск: заполните руками анкету «Конфиденциальность приложения» и цену "
                    "(«Цены и доступность» → бесплатно), затем задайте STORE_MANUAL_DONE=1 "
                    "в группе yumurta_courier_review — API Apple их не умеет")
    if not ver:
        # Без редактируемой карточки «Что нового» не вписан: Codemagic создаст её
        # уже после сборки, пустой, и Apple ответит 409 whatsNew.
        miss.append("нет редактируемой карточки версии %s: %s" % (number, why))
        return miss, warn
    loc = pick_locale(asc.data("/v1/appStoreVersions/%s/appStoreVersionLocalizations" % ver["id"]), cfg.get("locale", "ru"))
    if not loc:
        miss.append("у версии нет локализации")
        return miss, warn
    a = attrs(loc)
    for k, t in (("description", "описание"), ("keywords", "ключевые слова"), ("supportUrl", "URL поддержки")):
        if not (a.get(k) or "").strip():
            miss.append("пусто: %s" % t)
    if not first and not (a.get("whatsNew") or "").strip():
        miss.append("пусто: «Что нового» в карточке версии %s (id %s, язык %s) — что ответил Apple, видно выше в шаге «Карточка версии»"
                    % (attrs(ver).get("versionString"), ver["id"], a.get("locale")))
    sets = shot_sets(asc, loc["id"])
    okshots = 0
    for t in SHOT_REQUIRED_ANY:
        if t in sets:
            sh = asc.data("/v1/appScreenshotSets/%s/appScreenshots" % sets[t]["id"], params={"limit": 50})
            failed = [x for x in sh if shot_state(x) == "FAILED"]
            waiting = [x for x in sh if shot_state(x) == "AWAITING_UPLOAD"]
            if failed:
                miss.append("скриншоты %s: Apple не обработал %d — запустите ios-store ещё раз (перезальёт набор)" % (t, len(failed)))
            if waiting:
                miss.append("скриншоты %s: %d загружены не до конца — запустите ios-store ещё раз (перезальёт набор)" % (t, len(waiting)))
            okshots += len([x for x in sh if shot_state(x) in SHOT_OK])
    if okshots == 0:
        miss.append("нет скриншотов iPhone 6,9″/6,7″ или 6,5″ (store/screenshots/APP_IPHONE_67/)")
    info = editable_appinfo(asc, app_id)
    if info:
        il = pick_locale(asc.data("/v1/appInfos/%s/appInfoLocalizations" % info["id"]), cfg.get("locale", "ru"))
        if il and not (attrs(il).get("privacyPolicyUrl") or "").strip():
            miss.append("пусто: ссылка на политику конфиденциальности")
        if not asc.data("/v1/appInfos/%s/primaryCategory" % info["id"], ok404=True):
            miss.append("не выбрана основная категория")
        d = asc.data("/v1/appInfos/%s/ageRatingDeclaration" % info["id"], ok404=True)
        if d:
            empty = age_unanswered(attrs(d[0]))
            if empty:
                miss.append("возрастной рейтинг: без ответа %s — впишите ответ в store/app.json (age_rating) или ответьте в App Store Connect" % ", ".join(sorted(empty)))
    if not full:
        return miss, warn
    rd = asc.data("/v1/appStoreVersions/%s/appStoreReviewDetail" % ver["id"], ok404=True)
    r = attrs(rd[0]) if rd else {}
    for k, t in (("contactFirstName", "REVIEW_CONTACT_FIRST_NAME"), ("contactLastName", "REVIEW_CONTACT_LAST_NAME"),
                 ("contactPhone", "REVIEW_CONTACT_PHONE"), ("contactEmail", "REVIEW_CONTACT_EMAIL")):
        if not (r.get(k) or "").strip():
            miss.append("сведения для проверки: пусто %s (переменная %s)" % (k, t))
    if cfg.get("demo_account_required", True):
        if not (r.get("demoAccountName") or "").strip():
            miss.append("демо-вход: пусто (переменная REVIEW_DEMO_LOGIN)")
        # Пароль Apple может не отдавать обратно — проверяем, только если поле пришло.
        if "demoAccountPassword" in r and not (r.get("demoAccountPassword") or "").strip():
            miss.append("демо-пароль: пусто (переменная REVIEW_DEMO_PASSWORD)")
    return miss, warn


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode not in ("apply", "check", "version"):
        say(__doc__)
        return 0
    try:
        cfg = load_config()
    except (OSError, ValueError) as e:
        say("Не читается store/app.json (%s) — пропускаю." % e)
        return 0
    asc, why = connect()
    if not asc:
        say("Пропускаю: %s." % why)
        return 0
    try:
        if mode == "version":
            apply_version_only(asc, cfg)
            return 0
        if mode == "apply":
            apply(asc, cfg)
            say("Готово. Что не записалось — выше, строки «не удалось».")
            return 0
        miss, warn = check(asc, cfg)
        for w in warn:
            say("  Заметка: %s." % w)
        if miss:
            say("════════ Карточка НЕ готова к подаче ════════")
            for m in miss:
                say("  • " + m)
            say("Подача упала бы и заняла одну из пяти заявок Apple — останавливаю ДО сборки.")
            say("Что где взять — RELEASE-CHECKLIST.md, шаг 7 (курьер) или ПУБЛИКАЦИЯ_И_PUSH.md, ЧАСТЬ 7 (клиент).")
            return 2
        say("Карточка готова к подаче.")
        return 0
    except ApiError as e:
        say("App Store Connect ответил ошибкой — %s. Пропускаю (не роняю сборку)." % e)
        return 0
    except Exception as e:  # шаг-обслуживание: неожиданное — в лог, не в падение
        say("Непредвиденная ошибка %s: %s. Пропускаю (не роняю сборку)." % (type(e).__name__, e))
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
