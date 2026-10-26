# Yumurta Бизнес — iOS-кабинет продавца (SwiftUI)

Нативное iOS-приложение кабинета продавца/кафе/услуг маркетплейса Yumurta.
API — тот же бэкенд, что и веб-панель `/seller/` (`https://yumurta.ru`,
эндпоинты `/api/seller/*` + `/api/v1/auth/refresh`, `/api/v1/push/register`).
Минимальная версия: **iOS 16**. Структура зеркальна клиентскому
`3 IOS-client/yumurta-ios1` (`Sources/{App,Core,Features,Net,Components}` + XcodeGen).

## Сборка (XcodeGen — как у клиентского приложения)
1. `brew install xcodegen`
2. В папке проекта: `xcodegen generate`
3. Открыть `YumurtaBusiness.xcodeproj`, выбрать Team (Signing & Capabilities),
   bundle id уже `ru.marketplace.business`.
4. Запустить на симуляторе или устройстве.

## Ручные шаги (не блокируют сборку)
- **Push:** ничего добавлять не нужно. Доставка идёт прямым APNs, как в
  приложении покупателя: приложение отдаёт сырой device-токен на
  `POST /api/v1/push/register` с `platform: ios_seller`, а сервер шлёт через
  общий командный ключ `.p8` (`config/apns-key.p8`) с топиком
  `ru.marketplace.business` (`APNS_BUNDLE_ID_SELLER` в `config/config.php`).
  Firebase и `GoogleService-Info.plist` больше не используются.
  Единственное требование со стороны Apple: у идентификатора
  `ru.marketplace.business` должна быть включена возможность
  Push Notifications, а профиль App Store — перевыпущен после её включения.
- **Иконка:** добавить `icon_1024.png` в `Sources/Assets.xcassets/AppIcon.appiconset/`
  (и прописать `"filename"` в его `Contents.json`).

## Что реализовано (Фаза 1 целиком)
- **Auth:** вход email/телефон + пароль, выбор панели (seller/kafe/service →
  `/api/seller/login` | `/api/kafe/login` | `/api/service/login`), JWT в Keychain,
  Bearer в каждом запросе, молчаливый refresh по 401 через actor
  (single-flight, `/api/v1/auth/refresh`), при провале — logout.
  Refresh-токен сервер отдаёт только в cookie — приложение достаёт его из
  `HTTPCookieStorage` после логина.
- **Мульти-магазин:** `GET /api/seller/shops` (+счётчики) → `POST /api/seller/switch-shop`,
  переключатель в шапке каждого экрана, полная перезагрузка данных.
- **Навигация:** TabView по `shops.type` (тип берётся из `GET /api/seller/settings` —
  `/api/seller/shops` его не отдаёт): shop/cafe → Заказы+Товары, service → Записи+Услуги.
- **Дашборд:** метрики за период, график 14 дней (Swift Charts), активные заказы,
  баланс кошелька, счётчики, pull-to-refresh.
- **Заказы:** фильтры-чипы + пагинация (`has_more`), деталь с модификаторами
  (парсинг `modifiers_json`), tel:-звонок, лог статусов, машина переходов —
  зеркало серверной таблицы (сервер валидирует), отмена с причиной,
  поллинг `new-count` 30 с + звук/бейдж, чат с `after_id`-подгрузкой.
- **Товары:** поиск/фильтры/пагинация, свайп-тумблер наличия, быстрая цена,
  полная форма по `saveProduct()` (теги, аллергены, КБЖУ, артикул/штрихкод…),
  фото multipart до 5 со сжатием, AI-описание с остатком лимита,
  bulk-режим выбора, стоп-лист с таймером `until_minutes`.
- **Услуги (service):** записи со сменой статуса и чатом, CRUD услуг,
  CRUD мастеров + фото, сетка слотов по неделям, генерация слотов, PUT/DELETE слота.
- **Кошелёк:** баланс/история/пендинги/тариф, warning низкого баланса,
  пополнение card_online/sbp/bank_transfer (реквизиты с копированием),
  отмена заявки; при появлении `payment_url` в ответе сервера — откроется
  SFSafariViewController (поддержано уже сейчас).
- **Возвраты:** список с фильтрами, деталь (позиции, фото клиента, лог),
  approve (бонусы/ручной + сумма + комментарий), reject с причиной.
- **Push:** регистрация APNs-токена (`POST /api/v1/push/register`), звук нового
  заказа в foreground, тумблеры категорий, deep link по тапу
  (new_order/order_chat → заказ/чат, return → возвраты).

## Известные особенности контракта (проверено по PHP-коду)
- Конверт ответов seller-API: `{ok, data, error, errors}` (`core/Response.php`);
  `/api/v1/*` — другой конверт `{success, data, meta, error:{message}}`.
- Деньги приходят строками `"0.00"` → везде `Decimal` через `@LenientDecimal`.
- `POST /wallet/topup` (card/sbp) сейчас подтверждает сразу (эквайринг-заглушка) —
  URL оплаты не возвращается; клиент готов к обоим сценариям.
- Чат возвращает массив сообщений прямо в `data` (не `{items:[]}`).
- `switch-shop` пишет выбор в `user_sessions.current_shop_id` — выбор живёт
  в серверной сессии токена и переживает refresh (sid сохраняется).
