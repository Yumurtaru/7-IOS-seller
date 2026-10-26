# Yumurta Seller — ответ Apple, Guideline 2.1(b)
Submission ID 1846cafd-2690-46d5-a47c-0a11eda1df5a · версия 1.0 (15) отклонена 14.09.2026

---

## Почему отказ повторился

В прошлый раз мы написали Apple, что раздел подписок удалён. **В билде его не удалили.**
Раздел был спрятан флагом с сервера:

```swift
// MoreView.swift
if session.plansEnabled {
    NavigationLink { PlansView() } label: { Label("Тариф и подписка", …) }
}

// Session.swift
@Published private(set) var plansEnabled: Bool = true   // ← по умолчанию ВКЛЮЧЕНО
```

Значение по умолчанию — `true`. Проверяющий ставит приложение с нуля, и до первого
ответа `/api/seller/me` пункт «Тариф и подписка» виден. Внутри — рабочая покупка
подписки со списанием с кошелька, мимо In-App Purchase. Ровно то, о чём Apple
и спрашивает.

Отдельный риск, которого мы избежали: функция, появляющаяся в уже проверенном
приложении после переключателя на сервере — это Guideline 2.3.1 (скрытые функции).
Отказ по 2.3.1 снимается тяжелее, чем по 2.1(b).

---

## Что изменено в коде (билд 1.0 (16))

| Файл | Что сделано |
|---|---|
| `Sources/Features/Plans/PlansView.swift` | Экран тарифов удалён, файл пустой |
| `Sources/Features/More/MoreView.swift` | Пункт меню «Тариф и подписка» удалён |
| `Sources/Core/Session.swift` | Флаг `plansEnabled` удалён — прятать больше нечего |
| `Sources/Net/API+Seller3.swift` | Методы `plans()` и `selectPlan()` удалены |

Теперь в iOS-сборке нет ни экрана, ни кнопки покупки, ни пункта меню, ни
серверного переключателя, который мог бы их вернуть.

Модели `PlansResponse` / `SubscriptionPlan` остались в `Models+Phase3.swift` —
на них никто не ссылается, вызвать их неоткуда. Трогать не стали: лишняя правка
перед сборкой это лишний риск.

---

## Чем площадка зарабатывает (это и есть суть ответа)

Подписок продавцов нет **нигде** — ни в iOS, ни в Android, ни на сайте.
Единственный доход площадки — **сборы с заказа**:

- **Сервисный сбор** — фиксированная сумма или процент от суммы товаров
  (`service_fee_fixed` / `service_fee_percent`). Настраивается на магазин.
  Платит либо покупатель — тогда сбор видно строкой в его заказе, либо магазин —
  тогда сбор удерживается с расчётного счёта продавца (`service_fee_payer`).
- **Комиссия** — процент или фиксированная сумма с выполненного заказа,
  удерживается с продавца (`order_commissions`).

Оба списания привязаны к **реальному заказу**: товары собраны и доставлены по
адресу покупателя, либо услуга оказана очно. Цифрового контента в системе нет
вообще.

Плюс в приложении есть **продвижение** (`BoostView`) — платное поднятие
объявлений магазина выше в поиске маркетплейса, оплата с того же счёта. Это
реклама физического магазина, показывается покупателям на сайте и в клиентском
приложении, а не внутри Yumurta Seller.

Для Apple такая конструкция сильнее прежней: нет подписок — нет предмета спора
про In-App Purchase. Остаётся только сбор за реальную доставку и реклама, а это
прямо выведено из-под IAP пунктом 3.1.5(a).

---

## Порядок действий — строго по шагам

1. Собрать **билд 1.0 (16)** с этими правками.
2. Установить на устройство и **убедиться глазами**: «Ещё» → «Настройки» →
   пункта «Тариф и подписка» нет.
3. App Store Connect → версия 1.0 → **выбрать билд 16** вместо 15.
4. Вставить текст ниже через **«Ответ на проверку приложения»**.
5. **«Повторно отправить на проверку приложения»**.

Отвечать до загрузки билда 16 бессмысленно: проверяющий смотрит тот билд,
который прикреплён к версии.

---

## Текст ответа — вставить как есть

Hello,

Thank you for the review. Below are answers to each of your questions, plus a
correction to our previous reply.

**Correction first.** In our earlier response we stated that the subscription
plans section had been removed. That was inaccurate, and we apologise. In that
build the section was hidden behind a server-side setting rather than removed
from the code, and the setting defaults to "on" until the app receives its first
server response — which is why your reviewer still saw it. In build 1.0 (16) the
screen, the purchase action, the menu entry and the server switch have all been
deleted from the source. There is no code path left that can display
subscription plans in this app.

**About the app.** Yumurta Seller is a free B2B companion app for merchants —
sole proprietors and companies — who sell physical goods (groceries, prepared
food) and real-world services (for example haircuts and clinic appointments) on
the yumurta.ru marketplace in Russia. It is a management dashboard: orders,
catalogue, stock, couriers, staff, analytics. Consumers cannot use it. There is
no sign-up inside the app at all; an account exists only after the marketplace
operator has verified the business's tax ID and approved a merchant contract.
Shoppers use a separate consumer app.

**1. Does your app include any paid content, subscriptions, features, or
services?**

No. There is no paid content and there are no subscriptions — not in this app,
not in our Android app, and not on our website. Subscription plans do not exist
anywhere in our service. The app is free and every feature is available to every
merchant at no charge; nothing is locked behind a payment.

Our marketplace earns money in exactly one way: per-order fees on real-world
orders.

- **Service fee.** A fixed amount or a percentage of the goods subtotal,
  configured per merchant. Depending on that merchant's contract it is either
  shown to the shopper as a line on their order in the consumer app, or deducted
  from the merchant's settlement account.
- **Commission.** A percentage or fixed amount on each fulfilled order, deducted
  from the merchant's settlement account.

Both are charged only when an order is actually fulfilled — physical goods
picked, packed and delivered to a buyer's street address, or a service performed
in person at the merchant's premises.

To make those deductions possible, the app shows the merchant's **settlement
account ("Кошелёк")**: a prepaid balance held with the marketplace operator,
topped up by bank transfer against an invoice. It buys no digital content and
unlocks no app functionality — if it runs out, the merchant simply stops
receiving new orders from the marketplace, and the app itself behaves exactly
the same.

The app also offers **listing promotion ("Продвижение")**: a merchant may spend
from the same account to have their physical-goods listings ranked higher in the
marketplace for a chosen number of days. This is business advertising for a
physical-goods store, shown to shoppers on our website and in our consumer app —
never inside Yumurta Seller. It is the same model as the advertising-manager
apps businesses use to buy ads.

Under Guideline 3.1.5(a), purchases of physical goods and services consumed
outside the app must use a purchase method other than In-App Purchase, which is
why these use the merchant's settlement account.

**2. Where can users purchase the content, subscriptions, features, or services
that can be accessed in the app?**

Nowhere. Nothing that is accessed in the app is purchased anywhere, inside or
outside it. The fees and advertising described above pay for real-world order
fulfilment and for marketplace advertising, and grant no access to anything
within the app.

**3. What specific types of previously purchased content, subscriptions,
features, or services can a user access in the app?**

None. No merchant holds a subscription or any purchased entitlement, and the app
has no screen that would grant access to one.

**4. What paid content, subscriptions, or features are unlocked within the app
that do not use In-App Purchase?**

None. No digital content exists in this app, and no feature is unlocked by any
payment. Every function is identical for every merchant regardless of their
account balance.

**5. Are the enterprise services in your app sold to single users, consumers, or
for family use?**

Exclusively to registered businesses. Our counterparties are sole proprietors
(ИП), limited companies (ООО) and registered self-employed professionals, each
under a signed B2B contract with the marketplace operator, ИП Мамедов Анар Юсиф
оглы (ОГРНИП 317619600075150, ИНН 614904997565). Fees and advertising are
invoiced to that legal entity with tax documentation. There is no personal,
family or consumer use, and no route by which an individual consumer can obtain
an account.

**6. Can users purchase physical goods or services together with digital content
in your app? If so, please describe how the physical and digital content are
connected and why you bundle them together in a single purchase.**

No. There is no digital content anywhere in our service, so no bundle of
physical and digital content exists. Merchants deal only with physical goods and
real-world services delivered or performed offline.

We are happy to provide a test account, a screen recording, or any further
detail you need.

Kind regards,
Yumurta

---

## Если проверяющий вернётся с вопросом про кошелёк

Короткий ответ по правилам самой Apple:

> The settlement account funds the marketplace's per-order fees on physical goods
> delivered to a buyer's physical address and services performed in person, and
> the merchant's advertising inside a physical-goods marketplace. Guideline
> 3.1.5(a) requires purchases of physical goods and services consumed outside the
> app to use a purchase method other than In-App Purchase.

Не соглашайтесь «на всякий случай» встроить In-App Purchase: сбор за реальный
заказ через IAP не проводится по правилам самой Apple, и это сломает расчёты
с продавцами.

---

## Что проверить ДО отправки ответа

В ответе сказано, что подписок нет нигде. Это должно быть правдой на момент
проверки — ревьюер может открыть сайт.

1. Админка → Настройки сайта → **«Тарифы продавцов» выключены**
   (`seller_plans_enabled = 0`). Значение по умолчанию в коде — `1`, так что
   выключение должно быть записано явно.
2. В кабинете продавца на сайте раздела тарифов **не видно**.
3. В Android-приложении продавца раздела тарифов **не видно**.

Если где-то тарифы ещё показываются — сначала выключить, потом отвечать.

---

## Чего не делать после одобрения

**Не возвращать тарифы в iOS.** Теперь их там нет физически, и это правда,
которую мы сообщили Apple. Если когда-нибудь понадобятся — только новой версией,
поданной на проверку. Появление функции в уже одобренном приложении без проверки
— это Guideline 2.3.1 и отказ с блокировкой обновлений.
