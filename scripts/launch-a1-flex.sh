#!/usr/bin/env bash
#
# launch-a1-flex.sh — пытается создать бесплатный ARM-инстанс Oracle Cloud
# (VM.Standard.A1.Flex) в Always Free лимите.
#
# Запускается из GitHub Actions по расписанию. За один запуск делает несколько
# попыток, перебирая Availability Domains по кругу.
#
# Коды выхода:
#   0 — инстанс создан, либо ёмкости нет, либо лимит уже исчерпан (штатные исходы);
#   1 — фатальная ошибка конфигурации/авторизации/параметров.
#
# Значения секретов никогда не попадают в лог.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Переменные (можно переопределить через окружение)
# ---------------------------------------------------------------------------

# Секреты. Если заданы — скрипт сам развернёт их в ~/.oci и ~/.ssh.
OCI_CONFIG="${OCI_CONFIG:-}"
OCI_PRIVATE_KEY="${OCI_PRIVATE_KEY:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"

# Telegram (если пусто — уведомление просто не отправляется).
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"

# OCID компартмента. Пусто → tenancy из ~/.oci/config.
COMPARTMENT_ID="${COMPARTMENT_ID:-}"

# AD через запятую: "AD-1,AD-2,AD-3". Пусто → автоопределение.
AVAILABILITY_DOMAINS="${AVAILABILITY_DOMAINS:-}"

# OCID образа / подсети. Пусто → автоопределение.
IMAGE_ID="${IMAGE_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"

# Путь к публичному SSH-ключу (после разворачивания секрета).
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-${HOME}/.ssh/id_ed25519.pub}"

# Параметры инстанса (Always Free: 2 OCPU / 12 GB / boot 50 GB).
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-50}"
INSTANCE_NAME="${INSTANCE_NAME:-a1-flex-free}"

# Сколько попыток за запуск и паузы между ними.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-10}"
SLEEP_SECONDS="${SLEEP_SECONDS:-15}"
RATE_LIMIT_SLEEP_SECONDS="${RATE_LIMIT_SLEEP_SECONDS:-45}"

# Жёсткий дедлайн скрипта. Workflow даёт 6 минут на job, из них ~1 минута
# уходит на checkout и установку OCI CLI, поэтому 300 с — безопасный предел.
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-300}"

# ---------------------------------------------------------------------------
# 2. Служебные пути
# ---------------------------------------------------------------------------

LOG_DIR="${HOME}/.oci"
LOG_FILE="${LOG_DIR}/a1-flex-launch.log"
OCI_CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-${HOME}/.oci/config}"

START_TS=$(date +%s)
INSTANCE_ID=""
LAST_CLASS="none"
ADS=()

mkdir -p "${LOG_DIR}" "${HOME}/.ssh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Функции
# ---------------------------------------------------------------------------

log() {
  local level="$1"
  shift
  local line
  line="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [${level}] $*"
  printf '%s\n' "${line}" >&2
  printf '%s\n' "${line}" >>"${LOG_FILE}" 2>/dev/null || true
}

die() {
  log ERROR "$*"
  exit 1
}

# notify_telegram <текст> — best-effort, никогда не роняет скрипт.
notify_telegram() {
  local text="$1"

  if [[ -z "${TELEGRAM_TOKEN}" || -z "${TELEGRAM_USER_ID}" ]]; then
    log WARN "TELEGRAM_TOKEN/TELEGRAM_USER_ID не заданы — уведомление пропущено"
    return 0
  fi

  local response http_code body
  # Токен уходит только в URL запроса к api.telegram.org и не логируется.
  response=$(curl -sS --max-time 20 -w '\n%{http_code}' \
    -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_USER_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true" 2>&1) || {
    log WARN "Не удалось отправить сообщение в Telegram (curl завершился с ошибкой)"
    return 0
  }

  http_code=$(printf '%s' "${response}" | tail -n1)
  body=$(printf '%s' "${response}" | sed '$d')

  if [[ "${http_code}" == "200" ]]; then
    log INFO "Уведомление в Telegram отправлено"
  else
    log WARN "Telegram ответил HTTP ${http_code}: ${body}"
  fi
  return 0
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда '$1'. Установите её и повторите запуск."
}

# validate_number <имя> <значение> <регэксп>
validate_number() {
  local name="$1" value="$2" pattern="$3"
  [[ "${value}" =~ ${pattern} ]] || die "Параметр ${name}='${value}' имеет неверный формат."
}

# Сколько секунд осталось до дедлайна (0, если бюджет исчерпан).
remaining_seconds() {
  local elapsed=$(( $(date +%s) - START_TS ))
  local left=$(( MAX_RUNTIME_SECONDS - elapsed ))
  if ((left > 0)); then
    printf '%s\n' "${left}"
  else
    printf '0\n'
  fi
}

# sleep_within_budget <секунды> — спит не дольше остатка бюджета.
# Возвращает 1, если бюджета уже нет (тогда цикл должен завершиться).
sleep_within_budget() {
  local want="$1" left
  left=$(remaining_seconds)
  if ((left <= 0)); then
    return 1
  fi
  if ((want > left)); then
    log WARN "Бюджет времени почти исчерпан — пауза ${left} с вместо ${want} с."
    want="${left}"
  fi
  sleep "${want}"
  return 0
}

# Разворачиваем секреты из env в файлы. Значения НЕ печатаем.
deploy_secrets() {
  if [[ -n "${OCI_CONFIG}" ]]; then
    umask 077
    printf '%s\n' "${OCI_CONFIG}" >"${OCI_CONFIG_FILE}"
    log INFO "Конфиг OCI (~/.oci/config) развёрнут из секрета OCI_CONFIG"
  fi

  if [[ -n "${OCI_PRIVATE_KEY}" ]]; then
    umask 077
    printf '%s\n' "${OCI_PRIVATE_KEY}" >"${HOME}/.oci/oci_api_key.pem"
    log INFO "Приватный ключ OCI (~/.oci/oci_api_key.pem) развёрнут из секрета OCI_PRIVATE_KEY"
  fi

  if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
    umask 077
    printf '%s\n' "${SSH_PUBLIC_KEY}" >"${SSH_PUBLIC_KEY_PATH}"
    log INFO "Публичный SSH-ключ записан в ${SSH_PUBLIC_KEY_PATH}"
  fi

  chmod 700 "${HOME}/.oci" 2>/dev/null || true
  chmod 600 "${OCI_CONFIG_FILE}" 2>/dev/null || true
  chmod 600 "${HOME}/.oci/oci_api_key.pem" 2>/dev/null || true
  chmod 600 "${SSH_PUBLIC_KEY_PATH}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 4. Проверки окружения
# ---------------------------------------------------------------------------

require_cmd oci
require_cmd jq
require_cmd curl

validate_number OCPUS "${OCPUS}" '^[0-9]+$'
validate_number MEMORY_GB "${MEMORY_GB}" '^[0-9]+([.][0-9]+)?$'
validate_number BOOT_VOLUME_GB "${BOOT_VOLUME_GB}" '^[0-9]+$'
validate_number MAX_ATTEMPTS "${MAX_ATTEMPTS}" '^[0-9]+$'
validate_number SLEEP_SECONDS "${SLEEP_SECONDS}" '^[0-9]+$'
validate_number RATE_LIMIT_SLEEP_SECONDS "${RATE_LIMIT_SLEEP_SECONDS}" '^[0-9]+$'
validate_number MAX_RUNTIME_SECONDS "${MAX_RUNTIME_SECONDS}" '^[0-9]+$'

((MAX_ATTEMPTS > 0)) || die "MAX_ATTEMPTS должен быть больше нуля."
((BOOT_VOLUME_GB >= 50)) || die "BOOT_VOLUME_GB должен быть не меньше 50 (минимум OCI)."

deploy_secrets

# Публичный ключ обязателен: без него инстанс создастся, но подключиться будет нельзя.
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH/#\~/${HOME}}"
[[ -f "${SSH_PUBLIC_KEY_PATH}" ]] || die "Не найден публичный SSH-ключ: ${SSH_PUBLIC_KEY_PATH}"

SSH_KEY_VALUE=$(tr -d '\r\n' <"${SSH_PUBLIC_KEY_PATH}")
[[ -n "${SSH_KEY_VALUE}" ]] || die "Файл ${SSH_PUBLIC_KEY_PATH} пуст."
[[ "${SSH_KEY_VALUE}" =~ ^(ssh-|ecdsa-|sk-ssh-) ]] || die \
  "Файл ${SSH_PUBLIC_KEY_PATH} не похож на публичный SSH-ключ (ожидается префикс ssh-...)."

log INFO "Старт: shape=${SHAPE}, ${OCPUS} OCPU / ${MEMORY_GB} GB, boot=${BOOT_VOLUME_GB} GB, имя=${INSTANCE_NAME}"

# ---------------------------------------------------------------------------
# 5. Автоопределение параметров
# ---------------------------------------------------------------------------

detect_compartment() {
  if [[ -n "${COMPARTMENT_ID}" ]]; then
    log INFO "COMPARTMENT_ID задан вручную"
    return 0
  fi

  [[ -r "${OCI_CONFIG_FILE}" ]] || die "Не найден файл конфигурации OCI: ${OCI_CONFIG_FILE}"

  local section="${OCI_CLI_PROFILE:-DEFAULT}"
  COMPARTMENT_ID=$(awk -v s="[${section}]" '
    $0 == s { inside = 1; next }
    /^\[/   { inside = 0 }
    inside && /^[[:space:]]*tenancy[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "${OCI_CONFIG_FILE}")

  [[ -n "${COMPARTMENT_ID}" ]] || die "В ${OCI_CONFIG_FILE} (профиль ${section}) нет tenancy=."
  log INFO "COMPARTMENT_ID взят из ~/.oci/config (tenancy)"
}

detect_availability_domains() {
  if [[ -n "${AVAILABILITY_DOMAINS}" ]]; then
    IFS=',' read -r -a ADS <<<"${AVAILABILITY_DOMAINS}"
  else
    local raw
    if ! raw=$(oci iam availability-domain list \
      --compartment-id "${COMPARTMENT_ID}" \
      --output json 2>&1); then
      die "Не удалось получить список Availability Domains: $(printf '%s' "${raw}" | tr '\n' ' ')"
    fi
    mapfile -t ADS < <(printf '%s' "${raw}" | jq -r '.data[]?.name // empty')
  fi

  local cleaned=() ad
  for ad in "${ADS[@]}"; do
    ad="${ad//[[:space:]]/}"
    [[ -n "${ad}" ]] && cleaned+=("${ad}")
  done
  ADS=("${cleaned[@]}")

  ((${#ADS[@]} > 0)) || die "Список Availability Domains пуст."
  log INFO "Availability Domains (${#ADS[@]}): ${ADS[*]}"
}

detect_image() {
  if [[ -n "${IMAGE_ID}" ]]; then
    log INFO "IMAGE_ID задан вручную"
    return 0
  fi

  log INFO "Ищу последний образ Canonical Ubuntu 22.04 для ${SHAPE}..."

  local raw
  if ! raw=$(oci compute image list \
    --compartment-id "${COMPARTMENT_ID}" \
    --operating-system "Canonical Ubuntu" \
    --shape "${SHAPE}" \
    --sort-by TIMECREATED \
    --sort-order DESC \
    --output json 2>&1); then
    die "Не удалось получить список образов: $(printf '%s' "${raw}" | tr '\n' ' ')"
  fi

  IMAGE_ID=$(printf '%s' "${raw}" | jq -r '
    [ .data[]? | select((."display-name" // "") | test("22\\.04")) ][0].id // empty
  ')

  [[ -n "${IMAGE_ID}" ]] || die "Не найден образ Ubuntu 22.04 для ${SHAPE}. Задайте IMAGE_ID явно."
  log INFO "Найден образ Ubuntu 22.04: ${IMAGE_ID}"
}

detect_subnet() {
  if [[ -n "${SUBNET_ID}" ]]; then
    log INFO "SUBNET_ID задан вручную"
    return 0
  fi

  log INFO "Ищу публичную подсеть..."

  local vcns_raw vcn_id subnets_raw found=""
  if ! vcns_raw=$(oci network vcn list \
    --compartment-id "${COMPARTMENT_ID}" \
    --output json 2>&1); then
    die "Не удалось получить список VCN: $(printf '%s' "${vcns_raw}" | tr '\n' ' ')"
  fi

  while IFS= read -r vcn_id; do
    [[ -n "${vcn_id}" ]] || continue
    if ! subnets_raw=$(oci network subnet list \
      --compartment-id "${COMPARTMENT_ID}" \
      --vcn-id "${vcn_id}" \
      --output json 2>&1); then
      log WARN "Не удалось получить подсети VCN ${vcn_id}"
      continue
    fi
    found=$(printf '%s' "${subnets_raw}" | jq -r '
      [ .data[]? | select((."prohibit-public-ip-on-vnic" // false) == false) ][0].id // empty
    ')
    [[ -n "${found}" ]] && break
  done < <(printf '%s' "${vcns_raw}" | jq -r '.data[]?.id // empty')

  [[ -n "${found}" ]] || die "Публичная подсеть не найдена. Задайте SUBNET_ID явно."
  SUBNET_ID="${found}"
  log INFO "Найдена публичная подсеть: ${SUBNET_ID}"
}

# ---------------------------------------------------------------------------
# 6. Классификация ошибок OCI
# ---------------------------------------------------------------------------

# → capacity | rate | fatal-auth | fatal-limit | fatal-param | other
classify_error() {
  local text="$1"

  if grep -qiE 'out of host capacity|outofhostcapacity|internalerror|internal error' <<<"${text}"; then
    printf 'capacity\n'
  elif grep -qiE 'toomanyrequests|too many requests|(^|[^0-9])429([^0-9]|$)' <<<"${text}"; then
    printf 'rate\n'
  elif grep -qiE 'notauthorizedornotfound|notauthorisedornotfound|not authorized|not authorised|notauthenticated' <<<"${text}"; then
    printf 'fatal-auth\n'
  elif grep -qiE 'limitexceeded|limit exceeded|quota exceeded|out of quota' <<<"${text}"; then
    printf 'fatal-limit\n'
  elif grep -qiE 'invalidparameter|invalid parameter' <<<"${text}"; then
    printf 'fatal-param\n'
  else
    printf 'other\n'
  fi
}

# ---------------------------------------------------------------------------
# 7. Подготовка и основной цикл
# ---------------------------------------------------------------------------

detect_compartment
detect_availability_domains
detect_image
detect_subnet

SHAPE_CONFIG=$(jq -cn \
  --argjson ocpus "${OCPUS}" \
  --argjson memory "${MEMORY_GB}" \
  '{ocpus: $ocpus, memoryInGBs: $memory}')

METADATA_JSON=$(jq -cn \
  --arg key "${SSH_KEY_VALUE}" \
  '{ssh_authorized_keys: $key}')

ERR_FILE=$(mktemp)
trap 'rm -f "${ERR_FILE}"' EXIT

# Сдвигаем стартовый AD по минуте: соседние запуски начинают с разных доменов.
START_INDEX=$(( $(date +%M) % ${#ADS[@]} ))

attempt=0
rate_hits=0
while ((attempt < MAX_ATTEMPTS)); do
  if (($(remaining_seconds) <= 0)); then
    log WARN "Истёк лимит времени (${MAX_RUNTIME_SECONDS} с) — завершаемся."
    break
  fi

  ad="${ADS[$(((START_INDEX + attempt) % ${#ADS[@]}))]}"
  attempt=$((attempt + 1))

  log INFO "Попытка ${attempt}/${MAX_ATTEMPTS}: Availability Domain ${ad}"

  launch_out=""
  launch_ok=0
  # --no-retry: не даём CLI тратить минуты на собственные ретраи.
  if launch_out=$(oci --no-retry compute instance launch \
    --compartment-id "${COMPARTMENT_ID}" \
    --availability-domain "${ad}" \
    --shape "${SHAPE}" \
    --shape-config "${SHAPE_CONFIG}" \
    --image-id "${IMAGE_ID}" \
    --subnet-id "${SUBNET_ID}" \
    --display-name "${INSTANCE_NAME}" \
    --boot-volume-size-in-gbs "${BOOT_VOLUME_GB}" \
    --assign-public-ip true \
    --metadata "${METADATA_JSON}" \
    --output json 2>"${ERR_FILE}"); then
    launch_ok=1
  fi

  if ((launch_ok == 1)); then
    INSTANCE_ID=$(printf '%s' "${launch_out}" | jq -r '.data.id // empty')
    if [[ -z "${INSTANCE_ID}" ]]; then
      log WARN "OCI вернул успех, но OCID не найден — повторяем."
      LAST_CLASS="other"
      if ! sleep_within_budget "${SLEEP_SECONDS}"; then
        break
      fi
      continue
    fi

    log INFO "Инстанс создан. OCID: ${INSTANCE_ID} (AD ${ad})"

    if [[ -n "${SUCCESS_MARKER_FILE:-}" ]]; then
      printf '%s\n' "${INSTANCE_ID}" >"${SUCCESS_MARKER_FILE}" 2>/dev/null || true
    fi

    notify_telegram "✅ Инстанс OCI ${SHAPE} создан!
Имя: ${INSTANCE_NAME}
AD: ${ad}
OCID: ${INSTANCE_ID}

Публичный IP появится через 1-2 минуты. Узнать:
oci compute instance list-vnics --instance-id ${INSTANCE_ID} --query 'data[0].\"public-ip\"' --raw-output

Чтобы не тратить минуты Actions, отключите workflow:
Settings → Actions → Try to create OCI A1.Flex → Disable."

    exit 0
  fi

  err_text="$(cat "${ERR_FILE}" 2>/dev/null || true)${launch_out}"
  LAST_CLASS=$(classify_error "${err_text}")
  log WARN "OCI ответил ошибкой (${LAST_CLASS}): $(printf '%s' "${err_text}" | tr '\n' ' ' | cut -c1-400)"

  case "${LAST_CLASS}" in
    capacity)
      # Ёмкости нет — идём к следующему AD.
      ;;
    rate)
      rate_hits=$((rate_hits + 1))
      if ((rate_hits >= 2)); then
        # Второй 429 за запуск: дальше долбить API бессмысленно — следующий
        # запуск по расписанию произойдёт через 10 минут.
        log WARN "Повторный 429 TooManyRequests — прекращаем попытки до следующего запуска."
        break
      fi
      log WARN "Rate limit OCI — пауза ${RATE_LIMIT_SLEEP_SECONDS} с."
      if ! sleep_within_budget "${RATE_LIMIT_SLEEP_SECONDS}"; then
        break
      fi
      continue
      ;;
    fatal-auth)
      die "Ошибка авторизации/конфигурации OCI. Проверьте секреты OCI_CONFIG и OCI_PRIVATE_KEY."
      ;;
    fatal-limit)
      # Инстанс уже создан или исчерпан лимит — это НЕ падение workflow.
      log WARN "Лимит Always Free для ${SHAPE} исчерпан (вероятно, инстанс уже создан). Завершаемся успешно."
      exit 0
      ;;
    fatal-param)
      die "OCI отклонил параметры запроса. Проверьте IMAGE_ID/SUBNET_ID/OCPUS/MEMORY_GB/BOOT_VOLUME_GB."
      ;;
    *)
      log WARN "Неизвестная ошибка — пауза ${SLEEP_SECONDS} с и повтор."
      ;;
  esac

  if ! sleep_within_budget "${SLEEP_SECONDS}"; then
    log WARN "Бюджет времени исчерпан — завершаемся, следующий запуск по расписанию."
    break
  fi
done

if [[ "${LAST_CLASS}" == "rate" ]]; then
  log INFO "OCI ограничил частоту запросов после ${attempt} попыток. Следующий запуск — по расписанию."
else
  log INFO "Свободной ёмкости A1.Flex не нашлось за ${attempt} попыток. Следующий запуск — по расписанию."
fi
exit 0
