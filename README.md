# Chicken Monitor

Система мониторинга температуры кур в реальном времени.

## Что умеет

- Показывает температуру и заряд батареи каждого датчика
- Подсвечивает статус цветом: зелёный = норма, жёлтый = внимание, красный = опасно
- Графики температуры за любой период (от 1 часа до 1 года)
- Группировка куриц по загонам
- Автоматическое обновление данных каждые 3 секунды

## Установка (VirtualBox — для Windows 7 и выше)

### Шаг 1. Установите VirtualBox

- Windows 7: скачайте **VirtualBox 6.1** с https://www.virtualbox.org/wiki/Download_Old_Builds_6_1 (пункт «Windows hosts»)
- Windows 10/11: скачайте **VirtualBox 7.x** с https://www.virtualbox.org/wiki/Downloads

Установите как обычную программу.

### Шаг 2. Скачайте проект

Скачайте ZIP с репозитория или клонируйте через git. Распакуйте в любую папку, например `C:\Chicken-Monitor`.

### Шаг 3. Настройте MQTT

Откройте **PowerShell**. Для этого нажмите Win+R, введите `powershell`, нажмите Enter.

Перейдите в папку проекта (укажите путь туда, куда вы распаковали проект):
```powershell
cd C:\Chicken-Monitor\project
```

Запустите настройку:
```powershell
.\setup.ps1
```

Скрипт спросит:
- **IP-адрес MQTT-брокера** — адрес вашего брокера в сети
- **Порт** — обычно 1883, просто нажмите Enter
- **Логин и пароль MQTT** — если на брокере есть авторизация
- **Пороги температуры** — нажмите Enter чтобы оставить по умолчанию

На вопрос **«Start Chicken Monitor now?»** ответьте **n** (мы запустим через виртуальную машину).

### Шаг 4. Запустите виртуальную машину

В том же PowerShell перейдите в корень проекта и запустите деплой (укажите путь туда, куда вы распаковали проект):
```powershell
cd C:\Chicken-Monitor
.\vm\deploy-vbox.ps1
```

Скрипт спросит пароль — придумайте любой. Дальше всё произойдёт автоматически:
- Скачается Ubuntu (~700 МБ)
- Создастся виртуальная машина
- Установится Docker
- Запустится система мониторинга

Это занимает 5–15 минут. После завершения откройте в браузере:

```
http://localhost:8080
```

### Повторный запуск

После перезагрузки компьютера виртуальная машина выключается. Чтобы запустить снова, откройте PowerShell и выполните (укажите путь туда, куда вы распаковали проект):
```powershell
cd C:\Chicken-Monitor
.\vm\deploy-vbox.ps1
```

### Обновление

Если изменили настройки MQTT или обновили код:
```powershell
cd C:\Chicken-Monitor\project
.\setup.ps1
cd C:\Chicken-Monitor
.\vm\update-vbox.ps1
```

### Выключение и удаление

Выключить виртуальную машину:
```powershell
& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' controlvm 'Chicken-Monitor' acpipowerbutton
```

Полностью удалить:
```powershell
& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' unregistervm 'Chicken-Monitor' --delete
```

---

## Установка (Hyper-V — только Windows 10/11 Pro)

Если у вас Windows 10/11 Pro, можно использовать Hyper-V вместо VirtualBox.

### Подготовка

Включите Hyper-V (PowerShell от администратора):
```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```

Установите qemu-img:
```powershell
winget install SoftwareFreedomConservancy.QEMU
```

### Запуск

```powershell
cd C:\Chicken-Monitor\project
.\setup.ps1

cd C:\Chicken-Monitor
.\vm\deploy.ps1
```

В конце скрипт покажет IP-адрес. Откройте в браузере:
```
http://<IP-адрес>:8000
```

### Обновление

```powershell
cd C:\Chicken-Monitor
.\vm\update.ps1
```

### Выключение и удаление

```powershell
Stop-VM -Name 'Chicken-Monitor'
```

Полностью удалить:
```powershell
Stop-VM 'Chicken-Monitor' -Force
Remove-VM 'Chicken-Monitor' -Force
Remove-Item 'C:\Hyper-V\Chicken-Monitor' -Recurse -Force
```

---

## Установка (Docker — Linux/Mac/Windows 10+)

Если на компьютере уже установлен Docker, можно запустить без виртуальной машины. Этот способ подходит для Linux, Mac и Windows 10+ с Docker Desktop.

### Шаг 1. Установите Docker

- **Linux:** https://docs.docker.com/engine/install/
- **Mac / Windows 10+:** https://www.docker.com/products/docker-desktop/

Убедитесь что Docker запущен (иконка Docker в трее / `docker --version` в терминале).

### Шаг 2. Скачайте проект

Скачайте ZIP с репозитория или клонируйте через git. Распакуйте в любую папку.

### Шаг 3. Настройте и запустите

**Linux / Mac** — откройте терминал:
```bash
cd /путь/к/Chicken-Monitor/project
./setup.sh
```

**Windows** — откройте PowerShell:
```powershell
cd C:\Chicken-Monitor\project
.\setup.ps1
```

Скрипт спросит настройки MQTT и пароль базы данных. На вопрос **«Start Chicken Monitor now?»** ответьте **Y**.

Скрипт автоматически запустит `docker compose up`, который поднимет:
- **PostgreSQL** — база данных для хранения показаний
- **Backend** — FastAPI-сервер + MQTT-клиент + веб-интерфейс

### Шаг 4. Откройте в браузере

```
http://localhost:8000
```

### Повторный запуск

Если контейнеры остановились (перезагрузка, выключение Docker):
```bash
cd /путь/к/Chicken-Monitor/project
docker compose up -d
```

### Обновление

Если изменили настройки MQTT или обновили код:
```bash
cd /путь/к/Chicken-Monitor/project
docker compose up -d --build
```

### Остановка и удаление

Остановить:
```bash
cd /путь/к/Chicken-Monitor/project
docker compose down
```

Остановить и удалить все данные:
```bash
docker compose down -v
```

---

## Настройка датчиков

Датчики должны отправлять данные на MQTT-брокер в топики:

| Топик | Что отправлять | Пример |
|-------|---------------|--------|
| `ThermoChicken/1/Temperature` | Температура | `39.5` |
| `ThermoChicken/1/voltage` | Напряжение батареи | `3.72` |

Где `1` — номер/ID датчика (буквы, цифры, дефис, до 32 символов).

## Статусы температуры

| Цвет | Значение | Диапазон |
|------|---------|---------|
| Зелёный | Норма | 38.0 – 41.5 °C |
| Жёлтый | Внимание | 41.5 – 42.5 °C |
| Красный | Опасно | ниже 38 или выше 42.5 °C |

Пороги можно изменить через `setup.ps1`.
