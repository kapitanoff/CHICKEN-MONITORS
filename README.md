# Chicken Monitor

Мониторинг температуры кур в реальном времени.

## Оглавление

- [Файл настроек .env](#файл-настроек-env)
- [Способ 1. VirtualBox (Windows 7 и выше)](#способ-1-virtualbox-windows-7-и-выше)
  - [Установка](#1-установите-virtualbox)
  - [Git для Windows 7](#2-установите-git-только-для-windows-7)
  - [Повторный запуск](#повторный-запуск-после-перезагрузки)
  - [Обновление](#обновление)
  - [Выключить / удалить](#выключить--удалить)
- [Способ 2. Hyper-V (только Windows 10/11 Pro)](#способ-2-hyper-v-только-windows-1011-pro)
  - [Установка](#1-включите-hyper-v)
  - [Обновление](#обновление-1)
  - [Выключить / удалить](#выключить--удалить-1)
- [Способ 3. Docker (Linux / Mac / Windows 10+)](#способ-3-docker-linux--mac--windows-10)
  - [Установка](#1-установите-docker)
  - [Повторный запуск](#повторный-запуск)
  - [Остановить / удалить](#остановить--удалить)
- [Веб-интерфейс](#веб-интерфейс)
- [Датчики](#датчики)

---

## Файл настроек `.env`

Файл `project/.env` — настройки проекта. **Без него проект не запустится.**

На **Windows 7** используйте скрипт `setup-win7.ps1`, на Windows 10+ — `setup.ps1`. Можно также создать вручную — откройте Блокнот, вставьте текст ниже, заполните и сохраните как `project/.env`:

```
MQTT_HOST=
MQTT_PORT=1883
MQTT_USERNAME=
MQTT_PASSWORD=

POSTGRES_USER=chicken
POSTGRES_PASSWORD=chickenpass2024
POSTGRES_DB=chicken_monitor
DATABASE_URL=postgresql+psycopg://chicken:chickenpass2024@localhost/chicken_monitor

TEMP_GREEN_MIN=40.0
TEMP_GREEN_MAX=42.0
TEMP_YELLOW_MAX=43.0
```

> **Важно (Windows 7):** Блокнот на Win7 может записать всё в одну строку. Убедитесь, что каждый параметр на отдельной строке. Или используйте `setup-win7.ps1` — он создаст файл правильно.

| Параметр | Что писать |
|----------|-----------|
| `MQTT_HOST` | IP-адрес MQTT-брокера — узнайте у того, кто настраивал датчики |
| `MQTT_PORT` | Порт брокера. Если не знаете — оставьте `1883` |
| `MQTT_USERNAME` | Логин от брокера. Нет авторизации — оставьте пустым |
| `MQTT_PASSWORD` | Пароль от брокера. Нет авторизации — оставьте пустым |
| `POSTGRES_USER` | Можно не менять |
| `POSTGRES_PASSWORD` | Можно не менять |
| `POSTGRES_DB` | Можно не менять |
| `DATABASE_URL` | Можно не менять. Если меняли `POSTGRES_USER` или `POSTGRES_PASSWORD` — подставьте их по шаблону |
| `TEMP_GREEN_MIN` | Ниже этого — опасно (красный). По умолчанию `40.0` |
| `TEMP_GREEN_MAX` | Выше этого — предупреждение (жёлтый). По умолчанию `42.0` |
| `TEMP_YELLOW_MAX` | Выше этого — опасно (красный). По умолчанию `43.0` |

Пороги можно менять прямо в веб-интерфейсе — шестерёнка в шапке.

---

## Способ 1. VirtualBox (Windows 7 и выше)

### 1. Установите VirtualBox

- Windows 7: https://www.virtualbox.org/wiki/Download_Old_Builds_6_1 → «Windows hosts»
- Windows 10/11: https://www.virtualbox.org/wiki/Downloads

### 2. Установите Git (только для Windows 7)

На Windows 7 нет встроенных утилит `ssh`, `scp`, `tar` — они нужны скрипту для работы с виртуальной машиной. Git for Windows включает их все.

Скачайте и установите **Git 2.46.2** (последняя версия для Windows 7): https://github.com/git-for-windows/git/releases/download/v2.46.2.windows.1/Git-2.46.2-64-bit.exe

> Новые версии Git (2.47+) не поддерживают Windows 7.

При установке оставьте все настройки по умолчанию.

> На Windows 10/11 этот шаг не нужен — там всё есть из коробки.

### 3. Скачайте проект

Скачайте ZIP с репозитория, распакуйте, например в `C:\Chicken-Monitor`.

### 4. Откройте PowerShell

Win+R → `powershell` → Enter. Выполните:
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser
```

### 5. Настройте .env

**Windows 7:**
```powershell
cd C:\Chicken-Monitor\project
.\setup-win7.ps1
```

**Windows 10/11:**
```powershell
cd C:\Chicken-Monitor\project
.\setup.ps1
```

Введите данные MQTT-брокера. На Windows 10+ на **«Start Chicken Monitor now?»** ответьте **n**.

### 6. Запустите виртуальную машину

```powershell
cd C:\Chicken-Monitor\vm
.\deploy-vbox.ps1
```

Придумайте пароль когда спросит. Ждите 5–15 минут.

### 7. Откройте в браузере

```
http://localhost:8080
```

### Повторный запуск после перезагрузки

```powershell
cd C:\Chicken-Monitor\vm
.\deploy-vbox.ps1
```

Скрипт увидит что ВМ уже есть и просто запустит её.

### Обновление

```powershell
cd C:\Chicken-Monitor\vm
.\update-vbox.ps1
```

Для сброса базы данных (удалит все данные куриц):
```powershell
.\update-vbox.ps1 -ResetDB
```

### Выключить / удалить

Через VirtualBox GUI: правой кнопкой на ВМ → «Закрыть» / «Удалить» → «Удалить все файлы».

Или через PowerShell:
```powershell
# Выключить
& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' controlvm 'Chicken-Monitor' acpipowerbutton

# Удалить полностью
& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' unregistervm 'Chicken-Monitor' --delete
```

---

## Способ 2. Hyper-V (только Windows 10/11 Pro)

### 1. Включите Hyper-V

PowerShell **от имени администратора**:
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```
Перезагрузите компьютер.

### 2. Установите qemu-img

```powershell
winget install SoftwareFreedomConservancy.QEMU
```

### 3. Скачайте проект

Скачайте ZIP, распакуйте в `C:\Chicken-Monitor`.

### 4. Настройте и запустите

```powershell
cd C:\Chicken-Monitor\project
.\setup.ps1
cd C:\Chicken-Monitor\vm
.\deploy.ps1
```

На **«Start Chicken Monitor now?»** ответьте **n**. Скрипт покажет IP-адрес → откройте `http://<IP>:8000`.

### Обновление

```powershell
cd C:\Chicken-Monitor\vm
.\update.ps1
```

### Выключить / удалить

```powershell
# Выключить
Stop-VM -Name 'Chicken-Monitor'

# Удалить полностью
Stop-VM 'Chicken-Monitor' -Force
Remove-VM 'Chicken-Monitor' -Force
Remove-Item 'C:\Hyper-V\Chicken-Monitor' -Recurse -Force
```

---

## Способ 3. Docker (Linux / Mac / Windows 10+)

### 1. Установите Docker

- Linux: https://docs.docker.com/engine/install/
- Mac / Windows 10+: https://www.docker.com/products/docker-desktop/

### 2. Скачайте проект

Скачайте ZIP, распакуйте в любую папку.

### 3. Настройте и запустите

**Windows:**
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser
cd C:\Chicken-Monitor\project
.\setup.ps1
```

**Linux / Mac:**
```bash
cd /путь/к/Chicken-Monitor/project
./setup.sh
```

На **«Start Chicken Monitor now?»** ответьте **Y**.

Или запустите вручную:
```bash
docker compose up -d --build
```

### 4. Откройте в браузере

```
http://localhost:8000
```

### Повторный запуск

```bash
cd /путь/к/Chicken-Monitor/project
docker compose up -d
```

### Остановить / удалить

```bash
# Остановить (данные сохранятся)
docker compose down

# Удалить вместе с данными
docker compose down -v
```

---

## Веб-интерфейс

- Карточки куриц с цветовой индикацией (зелёный / жёлтый / красный)
- График температуры при клике на курицу (с тултипами — наведите на точку для подробностей)
- Группировка по загонам (кнопка «По загонам»)
- Управление загонами (создание, переименование, удаление)
- Назначение курицы в загон (выпадающий список в карточке)
- Удаление курицы (кнопка «Удалить» в карточке)
- Настройка порогов температуры (шестерёнка в шапке)

---

## Датчики

Датчики шлют данные в MQTT-брокер:

```
ThermoChicken/<ID>/Temperature    →  41.2
ThermoChicken/<ID>/voltage        →  3.72
```

`<ID>` — номер датчика (буквы, цифры, дефис).
