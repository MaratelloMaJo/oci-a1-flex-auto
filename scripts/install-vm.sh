#!/usr/bin/env bash
#
# install-vm.sh â€” ÑƒÑÑ‚Ð°Ð½Ð°Ð²Ð»Ð¸Ð²Ð°ÐµÑ‚ oci-a1-flex-auto Ð½Ð° Linux VM (Ubuntu/Debian Ð¸Ð»Ð¸
# Oracle Linux/RHEL) ÐºÐ°Ðº systemd timer Ñ Ð·Ð°Ð¿ÑƒÑÐºÐ¾Ð¼ ÐºÐ°Ð¶Ð´Ñ‹Ðµ 5 Ð¼Ð¸Ð½ÑƒÑ‚.
#
# Ð˜ÑÐ¿Ð¾Ð»ÑŒÐ·Ð¾Ð²Ð°Ð½Ð¸Ðµ:
#   sudo bash scripts/install-vm.sh \
#     [--oci-config PATH] [--oci-key PATH] [--ssh-pub PATH] \
#     [--telegram-token TOKEN] [--telegram-user-id ID] [--interval MIN]
#
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/MaratelloMaJo/oci-a1-flex-auto.git}"
INSTALL_DIR="/opt/oci-a1-flex"
CONF_DIR="/etc/oci-a1-flex"
STATE_DIR="/var/lib/oci-a1-flex"

OCI_CONFIG_SRC=""
OCI_KEY_SRC=""
SSH_PUB_SRC=""
TELEGRAM_TOKEN_VAL=""
TELEGRAM_USER_ID_VAL=""
INTERVAL_MIN="5"

usage() {
  cat <<'EOF'
Ð˜ÑÐ¿Ð¾Ð»ÑŒÐ·Ð¾Ð²Ð°Ð½Ð¸Ðµ:
  sudo bash scripts/install-vm.sh [Ð¾Ð¿Ñ†Ð¸Ð¸]

ÐžÐ¿Ñ†Ð¸Ð¸:
  --oci-config PATH        ÐŸÑƒÑ‚ÑŒ Ðº Ñ„Ð°Ð¹Ð»Ñƒ ~/.oci/config (Ð¸Ð»Ð¸ OCI_CONFIG.txt)
  --oci-key PATH           ÐŸÑƒÑ‚ÑŒ Ðº Ð¿Ñ€Ð¸Ð²Ð°Ñ‚Ð½Ð¾Ð¼Ñƒ ÐºÐ»ÑŽÑ‡Ñƒ OCI (.pem)
  --ssh-pub PATH           ÐŸÑƒÑ‚ÑŒ Ðº Ð¿ÑƒÐ±Ð»Ð¸Ñ‡Ð½Ð¾Ð¼Ñƒ SSH-ÐºÐ»ÑŽÑ‡Ñƒ (.pub)
  --telegram-token TOKEN   Ð¢Ð¾ÐºÐµÐ½ Telegram-Ð±Ð¾Ñ‚Ð° (Ð½ÐµÐ¾Ð±ÑÐ·Ð°Ñ‚ÐµÐ»ÑŒÐ½Ð¾)
  --telegram-user-id ID    Chat ID Ð² Telegram (Ð½ÐµÐ¾Ð±ÑÐ·Ð°Ñ‚ÐµÐ»ÑŒÐ½Ð¾)
  --interval MIN           Ð˜Ð½Ñ‚ÐµÑ€Ð²Ð°Ð» Ñ‚Ð°Ð¹Ð¼ÐµÑ€Ð° Ð² Ð¼Ð¸Ð½ÑƒÑ‚Ð°Ñ… (Ð¿Ð¾ ÑƒÐ¼Ð¾Ð»Ñ‡Ð°Ð½Ð¸ÑŽ: 5)
  -h, --help               ÐŸÐ¾ÐºÐ°Ð·Ð°Ñ‚ÑŒ ÑÐ¿Ñ€Ð°Ð²ÐºÑƒ
EOF
}

while (($# > 0)); do
  case "$1" in
    --oci-config) OCI_CONFIG_SRC="${2:-}"; shift 2 ;;
    --oci-key) OCI_KEY_SRC="${2:-}"; shift 2 ;;
    --ssh-pub) SSH_PUB_SRC="${2:-}"; shift 2 ;;
    --telegram-token) TELEGRAM_TOKEN_VAL="${2:-}"; shift 2 ;;
    --telegram-user-id) TELEGRAM_USER_ID_VAL="${2:-}"; shift 2 ;;
    --interval) INTERVAL_MIN="${2:-5}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ÐÐµÐ¸Ð·Ð²ÐµÑÑ‚Ð½Ñ‹Ð¹ Ð¿Ð°Ñ€Ð°Ð¼ÐµÑ‚Ñ€: $1" >&2; usage; exit 1 ;;
  esac
done

if ((EUID != 0)); then
  echo "Ð—Ð°Ð¿ÑƒÑÑ‚Ð¸Ñ‚Ðµ ÑÐºÑ€Ð¸Ð¿Ñ‚ Ñ Ð¿Ñ€Ð°Ð²Ð°Ð¼Ð¸ root (Ñ‡ÐµÑ€ÐµÐ· sudo)." >&2
  exit 1
fi

if ! [[ "${INTERVAL_MIN}" =~ ^[0-9]+$ ]] || ((INTERVAL_MIN < 1 || INTERVAL_MIN > 59)); then
  echo "ÐÐµÐºÐ¾Ñ€Ñ€ÐµÐºÑ‚Ð½Ñ‹Ð¹ --interval: '${INTERVAL_MIN}' (Ð¾Ð¶Ð¸Ð´Ð°ÐµÑ‚ÑÑ Ñ‡Ð¸ÑÐ»Ð¾ 1..59)." >&2
  exit 1
fi

echo "[1/5] Ð£ÑÑ‚Ð°Ð½Ð°Ð²Ð»Ð¸Ð²Ð°ÑŽ ÑÐ¸ÑÑ‚ÐµÐ¼Ð½Ñ‹Ðµ Ð·Ð°Ð²Ð¸ÑÐ¸Ð¼Ð¾ÑÑ‚Ð¸..."
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq git jq curl python3 python3-venv python3-pip
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q git jq curl python3 python3-pip
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q git jq curl python3 python3-pip
else
  echo "ÐÐµ Ð½Ð°Ð¹Ð´ÐµÐ½ apt-get, dnf Ð¸Ð»Ð¸ yum. Ð£ÑÑ‚Ð°Ð½Ð¾Ð²Ð¸Ñ‚Ðµ git, jq, curl, python3 Ð²Ñ€ÑƒÑ‡Ð½ÑƒÑŽ." >&2
  exit 1
fi

echo "[2/5] Ð Ð°Ð·Ð²Ð¾Ñ€Ð°Ñ‡Ð¸Ð²Ð°ÑŽ Ñ€ÐµÐ¿Ð¾Ð·Ð¸Ñ‚Ð¾Ñ€Ð¸Ð¹ Ð¸ venv Ð´Ð»Ñ oci-cli..."
mkdir -p "${INSTALL_DIR}" "${CONF_DIR}" "${STATE_DIR}"
chmod 700 "${CONF_DIR}" "${STATE_DIR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${LOCAL_REPO_ROOT}/scripts/launch-a1-flex.sh" ]]; then
  rm -rf "${INSTALL_DIR}/repo"
  cp -a "${LOCAL_REPO_ROOT}" "${INSTALL_DIR}/repo"
elif [[ -d "${INSTALL_DIR}/repo/.git" ]]; then
  git -C "${INSTALL_DIR}/repo" pull --ff-only
else
  git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}/repo"
fi

if [[ ! -x "${INSTALL_DIR}/venv/bin/oci" ]]; then
  python3 -m venv "${INSTALL_DIR}/venv"
  "${INSTALL_DIR}/venv/bin/pip" install --quiet --upgrade pip
  "${INSTALL_DIR}/venv/bin/pip" install --quiet oci-cli
fi

echo "[3/5] ÐÐ°ÑÑ‚Ñ€Ð°Ð¸Ð²Ð°ÑŽ ÑÐµÐºÑ€ÐµÑ‚Ñ‹ Ð² ${CONF_DIR}..."
copy_secret_if_given() {
  local src="$1" dst="$2"
  if [[ -n "${src}" ]]; then
    [[ -f "${src}" ]] || { echo "Ð¤Ð°Ð¹Ð» Ð½Ðµ Ð½Ð°Ð¹Ð´ÐµÐ½: ${src}" >&2; exit 1; }
    cp "${src}" "${dst}"
    chmod 600 "${dst}"
  fi
}

copy_secret_if_given "${OCI_CONFIG_SRC}" "${CONF_DIR}/oci.config"
copy_secret_if_given "${OCI_KEY_SRC}" "${CONF_DIR}/oci_api_key.pem"
copy_secret_if_given "${SSH_PUB_SRC}" "${CONF_DIR}/ssh_public_key.pub"

if [[ ! -f "${CONF_DIR}/env" ]]; then
  cat >"${CONF_DIR}/env" <<EOF
TELEGRAM_TOKEN=${TELEGRAM_TOKEN_VAL}
TELEGRAM_USER_ID=${TELEGRAM_USER_ID_VAL}
OCPUS=2
MEMORY_GB=12
BOOT_VOLUME_GB=50
INSTANCE_NAME=a1-flex-free
MAX_ATTEMPTS=10
SLEEP_SECONDS=15
RATE_LIMIT_SLEEP_SECONDS=45
MAX_RUNTIME_SECONDS=240
EOF
  chmod 600 "${CONF_DIR}/env"
else
  if [[ -n "${TELEGRAM_TOKEN_VAL}" ]]; then
    sed -i "s|^TELEGRAM_TOKEN=.*|TELEGRAM_TOKEN=${TELEGRAM_TOKEN_VAL}|" "${CONF_DIR}/env"
  fi
  if [[ -n "${TELEGRAM_USER_ID_VAL}" ]]; then
    sed -i "s|^TELEGRAM_USER_ID=.*|TELEGRAM_USER_ID=${TELEGRAM_USER_ID_VAL}|" "${CONF_DIR}/env"
  fi
fi

echo "[4/5] Ð¡Ð¾Ð·Ð´Ð°ÑŽ runner Ð¸ systemd-ÑŽÐ½Ð¸Ñ‚Ñ‹..."
cat >"${INSTALL_DIR}/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONF_DIR="/etc/oci-a1-flex"
STATE_DIR="/var/lib/oci-a1-flex"
INSTALL_DIR="/opt/oci-a1-flex"
MARKER="${STATE_DIR}/instance_created"

if [[ -f "${MARKER}" ]]; then
  echo "Ð˜Ð½ÑÑ‚Ð°Ð½Ñ ÑƒÐ¶Ðµ ÑÐ¾Ð·Ð´Ð°Ð½ ($(cat "${MARKER}")). ÐžÑ‚ÐºÐ»ÑŽÑ‡Ð°ÑŽ Ñ‚Ð°Ð¹Ð¼ÐµÑ€."
  systemctl disable --now oci-a1-flex.timer >/dev/null 2>&1 || true
  exit 0
fi

for f in oci.config oci_api_key.pem ssh_public_key.pub; do
  if [[ ! -s "${CONF_DIR}/${f}" ]]; then
    echo "ÐÐµ Ð·Ð°Ð¿Ð¾Ð»Ð½ÐµÐ½ Ð¾Ð±ÑÐ·Ð°Ñ‚ÐµÐ»ÑŒÐ½Ñ‹Ð¹ Ñ„Ð°Ð¹Ð»: ${CONF_DIR}/${f}" >&2
    exit 1
  fi
done

export HOME="${STATE_DIR}"
export PATH="${INSTALL_DIR}/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export SUCCESS_MARKER_FILE="${MARKER}"

set -a
# shellcheck source=/dev/null
source "${CONF_DIR}/env"
set +a

export OCI_CONFIG
OCI_CONFIG="$(cat "${CONF_DIR}/oci.config")"
export OCI_PRIVATE_KEY
OCI_PRIVATE_KEY="$(cat "${CONF_DIR}/oci_api_key.pem")"
export SSH_PUBLIC_KEY
SSH_PUBLIC_KEY="$(cat "${CONF_DIR}/ssh_public_key.pub")"

bash "${INSTALL_DIR}/repo/scripts/launch-a1-flex.sh"

if [[ -f "${MARKER}" ]]; then
  echo "Ð˜Ð½ÑÑ‚Ð°Ð½Ñ ÑƒÑÐ¿ÐµÑˆÐ½Ð¾ ÑÐ¾Ð·Ð´Ð°Ð½! ÐžÑ‚ÐºÐ»ÑŽÑ‡Ð°ÑŽ oci-a1-flex.timer."
  systemctl disable --now oci-a1-flex.timer >/dev/null 2>&1 || true
fi
EOF
chmod 700 "${INSTALL_DIR}/run.sh"

cat >"/etc/systemd/system/oci-a1-flex.service" <<EOF
[Unit]
Description=Try to create OCI VM.Standard.A1.Flex instance
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/run.sh
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal
EOF

cat >"/etc/systemd/system/oci-a1-flex.timer" <<EOF
[Unit]
Description=Run OCI A1.Flex launcher every ${INTERVAL_MIN} minutes

[Timer]
OnBootSec=30s
OnCalendar=*:0/${INTERVAL_MIN}
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "[5/5] ÐŸÐµÑ€ÐµÐ·Ð°Ð³Ñ€ÑƒÐ¶Ð°ÑŽ systemd..."
systemctl daemon-reload

missing=0
for f in oci.config oci_api_key.pem ssh_public_key.pub; do
  if [[ ! -s "${CONF_DIR}/${f}" ]]; then
    missing=1
  fi
done

if ((missing == 0)); then
  systemctl enable --now oci-a1-flex.timer
  echo "Ð“Ð¾Ñ‚Ð¾Ð²Ð¾! Ð¢Ð°Ð¹Ð¼ÐµÑ€ oci-a1-flex.timer Ð·Ð°Ð¿ÑƒÑ‰ÐµÐ½ (ÐºÐ°Ð¶Ð´Ñ‹Ðµ ${INTERVAL_MIN} Ð¼Ð¸Ð½)."
  echo "ÐŸÑ€Ð¾Ð²ÐµÑ€Ð¸Ñ‚ÑŒ ÑÑ‚Ð°Ñ‚ÑƒÑ: systemctl list-timers oci-a1-flex.timer"
  echo "Ð›Ð¾Ð³Ð¸ Ð² Ñ€ÐµÐ°Ð»ÑŒÐ½Ð¾Ð¼ Ð²Ñ€ÐµÐ¼ÐµÐ½Ð¸: journalctl -u oci-a1-flex.service -f"
  echo "Ð¢ÐµÑÑ‚Ð¾Ð²Ñ‹Ð¹ Ð·Ð°Ð¿ÑƒÑÐº Ð¿Ñ€ÑÐ¼Ð¾ ÑÐµÐ¹Ñ‡Ð°Ñ: systemctl start oci-a1-flex.service"
else
  echo "Ð®Ð½Ð¸Ñ‚Ñ‹ ÑƒÑÑ‚Ð°Ð½Ð¾Ð²Ð»ÐµÐ½Ñ‹, Ð½Ð¾ Ñ‚Ð°Ð¹Ð¼ÐµÑ€ ÐÐ• Ð·Ð°Ð¿ÑƒÑ‰ÐµÐ½ â€” Ð½Ðµ Ñ…Ð²Ð°Ñ‚Ð°ÐµÑ‚ Ñ„Ð°Ð¹Ð»Ð¾Ð² Ð² ${CONF_DIR}:"
  echo "  - ${CONF_DIR}/oci.config"
  echo "  - ${CONF_DIR}/oci_api_key.pem"
  echo "  - ${CONF_DIR}/ssh_public_key.pub"
  echo "ÐŸÐ¾ÑÐ»Ðµ Ð¸Ñ… Ð·Ð°Ð¿Ð¾Ð»Ð½ÐµÐ½Ð¸Ñ Ð²Ñ‹Ð¿Ð¾Ð»Ð½Ð¸Ñ‚Ðµ: systemctl enable --now oci-a1-flex.timer"
fi

