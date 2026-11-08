# Expense Tracker для iOS

Нативный клиент (SwiftUI) для API `https://rmillerqa.tech/expense-tracker/api` (бэкенд — `../expense-tracker`).
Операции можно добавлять, менять и удалять без сети: они уйдут на сервер, когда связь вернётся.
Категории, теги и настройки без сети только просматриваются.

## Сборка

```sh
brew install xcodegen      # один раз
xcodegen generate          # после изменения project.yml или добавления файлов
open ExpenseTracker.xcodeproj
```

Файл `.xcodeproj` генерируется, в git не хранится. Адрес сервера задаётся в `Config/Base.xcconfig` (`API_BASE_URL`).

## Запуск в симуляторе

Xcode → схема **ExpenseTracker** → любой iPhone-симулятор → Run (⌘R). Подпись не нужна.

## Запуск на iPhone (бесплатный Apple ID)

1. Xcode → Settings → Accounts → **+** → Apple ID. Появится *Personal Team*.
2. `cp Config/Local.xcconfig.example Config/Local.xcconfig` и впишите `APP_TEAM_ID`
   (его видно в Accounts → Personal Team, или в Signing & Capabilities после выбора команды).
3. `xcodegen generate`, подключите iPhone кабелем, разрешите «Доверять этому компьютеру».
4. На iPhone: Настройки → Конфиденциальность и безопасность → **Режим разработчика** → вкл., перезагрузка.
5. В Xcode выберите iPhone и нажмите Run.
6. При первом запуске: Настройки → Основные → VPN и управление устройством → доверять разработчику.

С бесплатным аккаунтом подпись действует 7 дней: потом просто снова нажмите Run в Xcode.
Если Xcode пишет, что bundle ID занят, задайте свой `APP_BUNDLE_ID` в `Config/Local.xcconfig`.

## Тесты

```sh
xcodebuild -project ExpenseTracker.xcodeproj -scheme ExpenseTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

UI-тест входит на сервер под тестовым аккаунтом и без учётных данных пропускается:
`TEST_RUNNER_UITEST_EMAIL=… TEST_RUNNER_UITEST_PASSWORD=… xcodebuild … test`.

## Устройство кода

| Папка | Что внутри |
|---|---|
| `Core/Network` | `APIClient` (общий refresh токена на все запросы), эндпоинты, разбор ошибок, JSON-кодеры |
| `Core/Auth` | токены в Keychain |
| `Core/DTO` | модели API (по `packages/types/src/index.ts`) |
| `Core/Store` | кэш SwiftData и `SyncStore`: очередь офлайн-изменений и синхронизация |
| `Features/*` | экраны: вход, операции, сводка, справочники, настройки |
