# oci-a1-flex-auto

GitHub Actions каждые 10 минут пытается создать бесплатный ARM-инстанс Oracle Cloud (`VM.Standard.A1.Flex`, Always Free: 2 OCPU / 12 GB RAM / 50 GB boot) и присылает в Telegram OCID, как только это удалось. Если ёмкости нет — перебирает Availability Domains по кругу и завершается без ошибки. Существующие инстансы (включая `VM.Standard.E2.1.Micro`) скрипт не трогает: он только вызывает `instance launch`.

```
GitHub Actions (cron */10, workflow_dispatch)
   └── scripts/launch-a1-flex.sh
         ├── разворачивает ~/.oci/config и ~/.oci/oci_api_key.pem из секретов
         ├── находит compartment (tenancy), AD, образ Ubuntu 22.04, публичную подсеть
         ├── loop: AD1 → AD2 → AD3 → AD1 ...  (oci compute instance launch)
         └── успех → Telegram sendMessage с OCID
```

## Секреты

Settings → **Secrets and variables** → **Actions** → **New repository secret**.

| Секрет | Что класть |
|---|---|
| `OCI_CONFIG` | Полный текст `~/.oci/config`: `[DEFAULT]` + `user`, `fingerprint`, `tenancy`, `region`, `key_file=~/.oci/oci_api_key.pem` |
| `OCI_PRIVATE_KEY` | Приватный API-ключ OCI (PEM, `-----BEGIN PRIVATE KEY-----`) — тот, что скачали при создании API-ключа |
| `SSH_PUBLIC_KEY` | Одна строка публичного ключа для доступа по SSH: `ssh-ed25519 AAAA... user@host` (`cat ~/.ssh/id_ed25519.pub`) |
| `TELEGRAM_TOKEN` | Токен бота от @BotFather (`123456789:AA...`) |
| `TELEGRAM_USER_ID` | Ваш numeric chat_id (узнать у @myidbot командой `/getid`) |

Обязательно напишите своему боту **/start**, иначе Telegram вернёт `403: bot can't initiate conversation with a user`.

Необязательные **Repository variables** (если не заданы — берутся дефолты из скрипта): `COMPARTMENT_ID`, `AVAILABILITY_DOMAINS`, `IMAGE_ID`, `SUBNET_ID`, `INSTANCE_NAME`, `OCPUS`, `MEMORY_GB`, `BOOT_VOLUME_GB`, `MAX_ATTEMPTS`, `SLEEP_SECONDS`, `RATE_LIMIT_SLEEP_SECONDS`.

## Первый запуск

1. Добавьте все пять секретов (см. выше).
2. Actions → **Try to create OCI A1.Flex** → **Run workflow** → ветка `main` → **Run workflow**.

Первый ручной запуск обязателен: он проверяет, что секреты и права OCI настроены верно. Если секрет отсутствует или креды неверны, job упадёт с понятным сообщением в логе.

## Проверка результата

```bash
# Все инстансы A1 в компартменте
oci compute instance list --compartment-id <TENANCY_OCID> \
  --query 'data[?shape==`VM.Standard.A1.Flex`].{name:"display-name",state:"lifecycle-state",id:id}' \
  --output table

# Публичный IP
oci compute instance list-vnics --instance-id <INSTANCE_OCID> \
  --query 'data[0]."public-ip"' --raw-output

# Подключение (пользователь Ubuntu-образов OCI — ubuntu)
ssh -i ~/.ssh/id_ed25519 ubuntu@<PUBLIC_IP>
```

OCID созданного инстанса печатается в логе шага «Запустить попытку создания инстанса» и приходит в Telegram.

## Как это работает с ошибками

| Ответ OCI | Поведение |
|---|---|
| `Out of host capacity` / `InternalError` | следующий Availability Domain, пауза 10 с |
| `TooManyRequests` / 429 | пауза 60 с, затем повтор |
| `LimitExceeded` | завершение с кодом 0 — workflow **не** краснеет (инстанс уже создан или исчерпан лимит) |
| `NotAuthorizedOrNotFound` / `InvalidParameter` | завершение с кодом 1 — это реальная поломка конфигурации |
| Прочее | пауза 10 с и повтор |

Скрипт сам останавливается через 200 секунд, чтобы успеть записать лог до `timeout-minutes: 4`.

## Остановка

После успешного создания инстанса отключите workflow: Actions → **Try to create OCI A1.Flex** → `...` → **Disable workflow**. Иначе каждый запуск будет получать `LimitExceeded` и впустую тратить минуты.

Удалить инстанс (освободит и boot volume в общем лимите 200 GB):

```bash
oci compute instance terminate --instance-id <INSTANCE_OCID> --preserve-boot-volume false
```

## Заметки

- **Диск.** Always Free даёт 200 GB на все boot volumes. Уже существующий `E2.1.Micro` занимает часть, поэтому дефолт `BOOT_VOLUME_GB=50`. Если увеличиваете — считайте: `200 − (boot volume E2.1.Micro)`.
- **Ёмкость.** `Out of host capacity` может длиться днями и неделями — это норма для Always Free ARM. Уменьшение до 1 OCPU / 6 GB иногда помогает.
- **AMD vs ARM.** Лимиты AMD и ARM независимы; ваш `E2.1.Micro` не затрагивается.
- **Минуты Actions.** Публичный репозиторий — стандартные раннеры бесплатны. В приватном на Free-плане всего 2000 минут/мес, а `*/10` даёт ~144 запуска в сутки × ~2–4 мин — лимит выгорит за считанные дни. Поэтому репозиторий публичный.
- **Неактивность.** GitHub отключает scheduled workflows после ~60 дней без активности в репозитории: раз в 2 месяца делайте любой коммит.
- **Секреты.** Значения секретов не попадают в логи, артефакты и комментарии workflow. `.gitignore` исключает `.oci/`, `*.pem`, `*.log`, `.env`. Никогда не коммитьте приватный ключ OCI в репозиторий.
