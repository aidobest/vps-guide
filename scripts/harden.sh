#!/usr/bin/env bash
# =============================================================================
#  harden.sh — первичная настройка и защита нового VPS за один запуск
#
#  Что делает:
#   1. Обновляет систему и ставит пакеты (пропуск обновления: UPGRADE_SYSTEM=0)
#   2. Создаёт обычного пользователя с sudo (работать под root — плохая идея)
#   3. Ставит «страховку»: если за 20 минут вы не подтвердите новый вход
#      командой `sudo vps-confirm`, SSH и файрвол откатятся к прежним
#   4. Настраивает вход по SSH-ключу и отключает вход по паролю
#   5. Запрещает вход под root, переносит SSH на другой порт
#   6. Включает UFW; действующие правила/политики сохраняет
#   7. Ставит fail2ban — блокирует подбор паролей
#   8. Включает автоматические обновления безопасности
#   9. Ужесточает сетевые настройки ядра (sysctl), синхронизирует время
#
#  Запуск (под root):    bash harden.sh
#  Без вопросов:         NEW_USER=admin SSH_PORT=48222 SSH_PUBKEY="ssh-ed25519 AAAA..." bash harden.sh
#
#  Поддерживается: Ubuntu 22.04 / 24.04, Debian 12 / 13
# =============================================================================
set -Eeuo pipefail
umask 077

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
cat <<'HELP'
Использование:  bash harden.sh            (под root, задаст 3 вопроса)
                NEW_USER=admin SSH_PORT=48222 SSH_PUBKEY="ssh-ed25519 AAAA..." bash harden.sh

Что делает: обновление системы, установка пакетов, пользователь с sudo, SSH только по ключу на новом порту,
UFW, fail2ban, автообновления, sysctl, chrony. Порт 22 остаётся открытым, пока
вы не подтвердите новый вход командой  sudo vps-confirm  (иначе откат через 20 мин).

После установки:  vps-status   — сводка защиты
                  sudo cat /root/vps-access.txt — данные для входа
Лог: /var/log/vps-harden.log
HELP
exit 0
fi

VERSION="0.4"
LOG=/var/log/vps-harden.log
ROLLBACK_MINUTES=20
BACKUP_DIR="/root/vps-harden-backup-$(date +%Y%m%d-%H%M%S)"
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-vps-hardening.conf
ACCESS_FILE=/root/vps-access.txt

# ---------- вывод ----------
if [ -t 1 ]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi
step() { echo; echo "${C_BLU}${C_BLD}==> $*${C_RST}"; }
ok()   { echo "${C_GRN}    ✔ $*${C_RST}"; }
warn() { echo "${C_YEL}    ! $*${C_RST}"; }
die()  { echo "${C_RED}${C_BLD}ОШИБКА: $*${C_RST}" >&2; exit 1; }
# секреты — только на экран, мимо лога
HAVE_TTY=0; { : >/dev/tty; } 2>/dev/null && HAVE_TTY=1
tty_only() { [ "$HAVE_TTY" = 1 ] && printf '%s\n' "$*" >/dev/tty || true; }

[ "$(id -u)" -eq 0 ] || die "Запускайте под root:  sudo bash harden.sh"
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export LC_ALL=C
[[ "${UPGRADE_SYSTEM:-1}" =~ ^[01]$ ]] || die "UPGRADE_SYSTEM: только 0 или 1"
command -v flock >/dev/null || die "Нужен flock (пакет util-linux)"
if systemctl is-active --quiet vps-harden-rollback.timer; then
  die "Уже работает таймер предыдущей настройки: сначала подтвердите её или дождитесь отката"
fi
exec 9>/run/lock/vps-harden.lock
flock -n 9 || die "Другой процесс настройки/подтверждения/отката уже работает"
[ ! -e /var/lib/vps-harden/pending ] || die "Есть неподтверждённая настройка: сначала vps-confirm или vps-harden-rollback"
ARMED=0
finish() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && ARMED == 1 )); then
    echo "Настройка прервана; выполняю откат SSH и UFW" >&2
    flock -u 9
    /usr/local/sbin/vps-harden-rollback || echo "Откат не завершён; таймер/сервис повторит попытку. Нужна проверка через консоль VPS." >&2
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
touch "$LOG"; chmod 600 "$LOG"
# 3/4 — исходный терминал: в конце через них печатаются пароль и порт, мимо лога.
exec 3>&1 4>&2
exec > >(tee -a "$LOG") 2>&1
TEE_PID=$!
echo "----- harden.sh v$VERSION  $(date -Is) -----"

# ---------- проверки ----------
[ -r /etc/os-release ] || die "Не удалось определить ОС"
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ok "ОС: $PRETTY_NAME" ;;
  *) die "Поддерживаются Ubuntu 22.04/24.04 и Debian 12/13" ;;
esac
command -v systemctl >/dev/null || die "Нужен systemd"
command -v sshd >/dev/null || die "Не найден sshd"
if [ -f "$SSHD_DROPIN" ]; then
  warn "Похоже, скрипт уже запускался ($SSHD_DROPIN существует)."
  read -r -p "    Запустить заново поверх? [y/N] " a; [[ "${a,,}" == y* ]] || exit 1
fi

# ---------- параметры ----------
step "Параметры"

valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$1" != root ]; }
# Только публичные ключи: ssh-keygen -l принимает и приватный ключ, поэтому проверяем формат строк.
# Перед типом ключа допускаются опции authorized_keys (их иногда ставит хостер у root).
pubkeys_ok() {
  local f="$1"
  grep -q 'PRIVATE KEY' "$f" && return 1
  grep -vE '^[[:space:]]*(#|$)' "$f" | grep -qvE '(^|[[:space:],"])(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+AAAA[A-Za-z0-9+/]+={0,3}([[:space:]]|$)' && return 1
  grep -qvE '^[[:space:]]*(#|$)' "$f"
}
NEW_USER="${NEW_USER:-}"
while ! valid_user "$NEW_USER"; do
  [ -n "$NEW_USER" ] && warn "«$NEW_USER» не годится: строчные латинские буквы, цифры, - и _, не root"
  read -r -p "    Имя нового пользователя (латиницей, например admin): " NEW_USER
done

SSH_PORT="${SSH_PORT:-}"
if [ -z "$SSH_PORT" ]; then
  SUGGEST=$(( (RANDOM % 40000) + 20000 ))
  read -r -p "    Порт SSH [Enter = случайный $SUGGEST]: " SSH_PORT
  SSH_PORT="${SSH_PORT:-$SUGGEST}"
fi
[[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] || die "Некорректный SSH_PORT"
SSH_PORT=$((10#$SSH_PORT))
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ] || die "Порт должен быть числом 1024–65535"
[ "$SSH_PORT" = 443 ] && die "Порт 443 оставьте для VPN"
if ss -H -tlnp "sport = :$SSH_PORT" | grep . >/dev/null; then
  if ss -H -tlnp "sport = :$SSH_PORT" | grep -vE '"sshd"|"systemd"' >/dev/null; then
    die "SSH_PORT занят посторонним процессом"
  fi
  sshd -T | awk '$1=="port" {print $2}' | grep -Fx "$SSH_PORT" >/dev/null || die "Порт занят и не указан в текущем sshd_config"
fi

SSH_PUBKEY="${SSH_PUBKEY:-}"
ROOT_KEYS=/root/.ssh/authorized_keys
if [ -z "$SSH_PUBKEY" ] && [ -s "$ROOT_KEYS" ]; then
  echo "    У root уже есть SSH-ключи (их положил хостер при создании сервера):"
  awk '{print "      • "$1" ..."substr($2,length($2)-15)" "$3}' "$ROOT_KEYS"
  read -r -p "    Использовать их для нового пользователя? [Y/n] " a
  if [[ -z "$a" || "${a,,}" == y* ]]; then SSH_PUBKEY="$(cat "$ROOT_KEYS")"; fi
fi
while [ -z "$SSH_PUBKEY" ]; do
  echo "    Вставьте ваш ПУБЛИЧНЫЙ ключ (одна строка, начинается с ssh-ed25519 или ssh-rsa)."
  echo "    На вашем компьютере он лежит в файле ~/.ssh/id_ed25519.pub"
  read -r -p "    Ключ: " SSH_PUBKEY
done
TMPKEY=$(mktemp); printf '%s\n' "$SSH_PUBKEY" > "$TMPKEY"
if ! ssh-keygen -l -f "$TMPKEY" >/dev/null 2>&1 || ! pubkeys_ok "$TMPKEY"; then
  rm -f "$TMPKEY"; die "Это не похоже на публичный SSH-ключ. Нужна строка вида: ssh-ed25519 AAAAC3... comment"
fi
rm -f "$TMPKEY"

PUBLIC_IP=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
# Как SSH работает СЕЙЧАС — это вернёт откат
OLD_PORTS=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u | tr '\n' ' ')
OLD_PORTS="${OLD_PORTS:-22 }"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then UFW_WAS_ACTIVE=1; else UFW_WAS_ACTIVE=0; fi

echo
echo "    Пользователь: ${C_BLD}$NEW_USER${C_RST}"
echo "    Порт SSH:     ${C_BLD}$SSH_PORT${C_RST}  (сейчас SSH на: ${OLD_PORTS})"
echo "    IP сервера:   ${C_BLD}$PUBLIC_IP${C_RST}"
if [ -z "${NONINTERACTIVE:-}" ] && [ -t 0 ]; then
  read -r -p "    Поехали? [Y/n] " a; [[ -z "$a" || "${a,,}" == y* ]] || exit 1
fi

# ---------- бэкап ----------
BACKUP_DIR=$(mktemp -d /root/vps-harden-backup.XXXXXXXX)
mkdir -p /var/lib/vps-harden
chmod 700 /var/lib/vps-harden
[ ! -f "$ACCESS_FILE" ] || cp -a "$ACCESS_FILE" "$BACKUP_DIR/vps-access.txt"
[ ! -f /etc/default/ufw ] || cp -a /etc/default/ufw "$BACKUP_DIR/ufw-default"
[ ! -f /etc/fail2ban/jail.local ] || cp -a /etc/fail2ban/jail.local "$BACKUP_DIR/jail.local"
for unit in ssh.service ssh.socket fail2ban.service; do
  load_state=$(systemctl show "$unit" --property=LoadState --value 2>/dev/null || true)
  [ -n "$load_state" ] || die "Не удалось прочитать LoadState для $unit"
  printf '%s\n' "$load_state" > "$BACKUP_DIR/$unit.load"
  systemctl is-enabled "$unit" > "$BACKUP_DIR/$unit.enabled" 2>/dev/null || true
  systemctl is-active "$unit" > "$BACKUP_DIR/$unit.active" 2>/dev/null || true
done
cp -a /etc/ssh/sshd_config "$BACKUP_DIR/"
if [ -d /etc/ssh/sshd_config.d ]; then cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/"; fi
if [ -d /etc/ufw ]; then cp -a /etc/ufw "$BACKUP_DIR/"; fi
if systemctl is-active --quiet ssh.socket; then echo socket > "$BACKUP_DIR/ssh-mode"; else echo service > "$BACKUP_DIR/ssh-mode"; fi
echo "$OLD_PORTS" > "$BACKUP_DIR/old-ports"
echo "$UFW_WAS_ACTIVE" > "$BACKUP_DIR/ufw-was-active"
ok "Резервная копия настроек: $BACKUP_DIR"

# ---------- 1. обновление ----------
step "1/9 Пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
if [ "${UPGRADE_SYSTEM:-1}" = 1 ]; then
  apt-get -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade
fi
apt-get -y -q install sudo ufw fail2ban unattended-upgrades apt-listchanges chrony curl ca-certificates \
  python3-systemd openssh-server openssl jq nano
ok "Необходимые пакеты установлены"

# ---------- 2. пользователь ----------
step "2/9 Пользователь $NEW_USER с правами sudo"
if id "$NEW_USER" >/dev/null 2>&1; then
  warn "Пользователь уже существует, пароль не меняю"
  USER_PASS="(не менялся; используйте существующий пароль sudo)"
  status=$(passwd -S "$NEW_USER" | awk '{print $2}')
  [ "$status" = P ] || die "У существующего пользователя нет активного пароля. Сначала выполните passwd $NEW_USER и повторите запуск"
  case "$(getent passwd "$NEW_USER" | cut -d: -f7)" in */nologin|*/false) die "У пользователя запрещён интерактивный вход" ;; esac
else
  useradd -m -s /bin/bash "$NEW_USER"
  USER_PASS=$(openssl rand -base64 45 | tr -dc 'A-Za-z0-9'); USER_PASS="${USER_PASS:0:20}"
  [ ${#USER_PASS} -eq 20 ] || die "Не удалось сгенерировать пароль"
  echo "$NEW_USER:$USER_PASS" | chpasswd
fi
if [ "$USER_PASS" != "(не менялся; используйте существующий пароль sudo)" ]; then
  printf 'Пользователь: %s\nПароль sudo: %s\nSSH-порт: %s\n' "$NEW_USER" "$USER_PASS" "$SSH_PORT" > "$ACCESS_FILE"
  chmod 600 "$ACCESS_FILE"
fi
usermod -aG sudo "$NEW_USER"
HOME_DIR=$(getent passwd "$NEW_USER" | cut -d: -f6)
[ ! -L "$HOME_DIR/.ssh" ] || die ".ssh не должен быть символической ссылкой"
install -d -m 700 -o "$NEW_USER" -g "$(id -gn "$NEW_USER")" "$HOME_DIR/.ssh"
[ ! -L "$HOME_DIR/.ssh/authorized_keys" ] || die "authorized_keys не должен быть символической ссылкой"
touch "$HOME_DIR/.ssh/authorized_keys"
printf '%s\n' "$SSH_PUBKEY" | while read -r line; do
  [ -z "$line" ] && continue
  grep -qxF -- "$line" "$HOME_DIR/.ssh/authorized_keys" || echo "$line" >> "$HOME_DIR/.ssh/authorized_keys"
done
chmod 600 "$HOME_DIR/.ssh/authorized_keys"; chown "$NEW_USER:$(id -gn "$NEW_USER")" "$HOME_DIR/.ssh" "$HOME_DIR/.ssh/authorized_keys"
ok "Ключ добавлен в $HOME_DIR/.ssh/authorized_keys"

# ---------- 3. Постоянный таймер и сериализованный откат ----------
step "3/9 Страховка от потери доступа"
printf '%s\n' "$BACKUP_DIR" > /var/lib/vps-harden/backup-path
cat > /usr/local/sbin/vps-harden-rollback <<'EOF'
#!/usr/bin/env bash
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export LC_ALL=C
[ "$(id -u)" -eq 0 ] || { echo "Запустите через sudo"; exit 1; }
exec 9>/run/lock/vps-harden.lock; flock 9
[ -e /var/lib/vps-harden/pending ] || exit 0
B=$(cat /var/lib/vps-harden/backup-path) || exit 1
[[ "$B" == /root/vps-harden-backup.* && -d "$B" ]] || exit 1
rc=0
cp -a "$B/sshd_config" /etc/ssh/sshd_config || rc=1
rm -rf /etc/ssh/sshd_config.d
if [ -d "$B/sshd_config.d" ]; then cp -a "$B/sshd_config.d" /etc/ssh/ || rc=1; fi
# UFW: восстанавливаем и правила, и политики, и прежнее состояние.
ufw --force disable >/dev/null 2>&1 || rc=1
if [ -d "$B/ufw" ]; then
  rm -rf /etc/ufw
  cp -a "$B/ufw" /etc/ufw || rc=1
fi
if [ -f "$B/ufw-default" ]; then cp -a "$B/ufw-default" /etc/default/ufw || rc=1; fi
if [ "$(cat "$B/ufw-was-active")" = 1 ]; then ufw --force enable >/dev/null 2>&1 || rc=1; fi
if [ -f "$B/jail.local" ]; then
  cp -a "$B/jail.local" /etc/fail2ban/jail.local || rc=1
else
  rm -f /etc/fail2ban/jail.local
fi
if [ "$(cat "$B/fail2ban.service.active")" = active ]; then
  systemctl restart fail2ban.service || rc=1
else
  systemctl stop fail2ban.service || rc=1
fi
if sshd -t; then
  systemctl daemon-reload || rc=1
  if [ "$(cat "$B/ssh-mode")" = socket ]; then
    systemctl stop ssh.service || rc=1
    systemctl restart ssh.socket || rc=1
  else
    systemctl stop ssh.socket >/dev/null 2>&1 || true
    systemctl restart ssh.service || rc=1
  fi
else
  rc=1
fi
for unit in ssh.service ssh.socket fail2ban.service; do
  # Установленный этим запуском fail2ban оставляем на диске, но не запускаем
  # и не включаем автозапуск, если до настройки службы не существовало.
  if [ "$unit" = fail2ban.service ] && [ "$(cat "$B/$unit.load")" = not-found ]; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || rc=1
    continue
  fi
  case "$(cat "$B/$unit.enabled")" in
    enabled) systemctl enable "$unit" >/dev/null 2>&1 || rc=1 ;;
    enabled-runtime) systemctl enable --runtime "$unit" >/dev/null 2>&1 || rc=1 ;;
    disabled) systemctl disable "$unit" >/dev/null 2>&1 || rc=1 ;;
  esac
done
if [ "$rc" -eq 0 ]; then
  rm -f /var/lib/vps-harden/pending
  systemctl disable --now vps-harden-rollback.timer >/dev/null 2>&1 || true
  echo "$(date -Is) SSH/UFW/fail2ban restored from $B" >> /var/log/vps-harden.log
else
  echo "Откат завершён с ошибками; резервная копия: $B" >&2
fi
exit "$rc"
EOF
chmod 700 /usr/local/sbin/vps-harden-rollback
cat > /usr/local/sbin/vps-confirm <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export LC_ALL=C
[ "\$(id -u)" -eq 0 ] || { echo "Запустите: sudo vps-confirm"; exit 1; }
exec 9>/run/lock/vps-harden.lock; flock 9
f2b_ready() { local i; for i in \$(seq 1 10); do fail2ban-client ping >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
[ -f /var/lib/vps-harden/pending ] || { echo "Нет ожидающей подтверждения настройки"; exit 1; }
[ -f "$SSHD_DROPIN" ] || exit 1
# Явное подтверждение после проверки НОВОГО SSH-входа.
sed -i '/^Port 22\$/d' "$SSHD_DROPIN"
sshd -t
systemctl reload ssh.service
sleep 1
systemctl is-active --quiet ssh.service
ss -H -tlnp "sport = :$SSH_PORT" | grep '"sshd"' >/dev/null
# Старые пользовательские правила не удаляем: удаляется только наше правило.
if [ "\$(cat /var/lib/vps-harden/added-port22)" = 1 ]; then
  ufw delete allow 22/tcp >/dev/null
fi
if sed -i 's/^port    = .*/port    = $SSH_PORT/' /etc/fail2ban/jail.local &&
   systemctl restart fail2ban && f2b_ready && fail2ban-client status sshd >/dev/null; then
  echo "fail2ban работает"
else
  echo "ВНИМАНИЕ: SSH проверен, но fail2ban требует проверки: sudo systemctl status fail2ban; sudo fail2ban-client status sshd" >&2
fi
rm -f /var/lib/vps-harden/pending
systemctl disable --now vps-harden-rollback.timer >/dev/null
echo "\$(date -Is) CONFIRMED by \${SUDO_USER:-root}" >> "$LOG"
echo "Подтверждено. Порт 22 закрыт, страховка снята."
echo "Вход: ssh -p $SSH_PORT $NEW_USER@$PUBLIC_IP"
EOF
chmod 755 /usr/local/sbin/vps-confirm
cat > /etc/systemd/system/vps-harden-rollback.service <<'EOF'
[Unit]
Description=Restore SSH and UFW if hardening is not confirmed
ConditionPathExists=/var/lib/vps-harden/pending
StartLimitIntervalSec=0
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-harden-rollback
Restart=on-failure
RestartSec=60
EOF
DEADLINE=$(date -u -d "+$ROLLBACK_MINUTES minutes" '+%Y-%m-%d %H:%M:%S UTC')
cat > /etc/systemd/system/vps-harden-rollback.timer <<EOF
[Unit]
Description=Deadline for confirming SSH access
[Timer]
OnCalendar=$DEADLINE
Persistent=true
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF
chmod 644 /etc/systemd/system/vps-harden-rollback.{service,timer}
systemctl daemon-reload
systemctl reset-failed vps-harden-rollback.service >/dev/null 2>&1 || true
touch /var/lib/vps-harden/pending
ARMED=1
systemctl enable --now vps-harden-rollback.timer
systemctl is-active --quiet vps-harden-rollback.timer
ok "Откат запланирован на $DEADLINE; таймер сохраняется после перезагрузки"

# ---------- 4. SSH ----------
step "4/9 SSH: ключи, без root, порт $SSH_PORT (порт 22 остаётся до подтверждения)"
mkdir -p /etc/ssh/sshd_config.d
# Директивы Port/Password в основном файле мешают — гасим (копия уже в бэкапе)
sed -i -E 's/^[[:space:]]*(Port|PasswordAuthentication|PermitRootLogin|ListenAddress)[[:space:]]/#&/' /etc/ssh/sshd_config
grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config || \
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
cat > "$SSHD_DROPIN" <<EOF
# Создано harden.sh $(date -Is). Порт 22 будет убран командой vps-confirm.
Port $SSH_PORT
Port 22
AddressFamily any
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $NEW_USER
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
EOF
chmod 644 "$SSHD_DROPIN"
EFFECTIVE=$(sshd -T -C "user=$NEW_USER,host=localhost,addr=127.0.0.1")
for expected in "permitrootlogin no" "passwordauthentication no" "kbdinteractiveauthentication no" "pubkeyauthentication yes" "authenticationmethods publickey" "allowusers $NEW_USER"; do
  printf '%s\n' "$EFFECTIVE" | grep -Fx "$expected" >/dev/null || die "Конфликт настроек SSH: ожидалось $expected"
done
while read -r p; do
  [[ "$p" = "$SSH_PORT" || "$p" = 22 ]] || die "В других настройках SSH остался порт $p; сначала устраните конфликт"
done < <(printf '%s\n' "$EFFECTIVE" | awk '$1=="port" {print $2}')
sshd -t || die "sshd не принял конфигурацию (см. выше). Работающий SSH не тронут, страховка снимет изменения."
# Ubuntu 24.04 запускает sshd через ssh.socket — там порт задаётся иначе. Переводим на обычный сервис.
if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
  systemctl disable --now ssh.socket >/dev/null 2>&1
fi
systemctl enable ssh.service >/dev/null 2>&1 || true
systemctl restart ssh.service
sleep 1
ss -H -tlnp "sport = :$SSH_PORT" | grep '"sshd"' >/dev/null || die "sshd не слушает порт $SSH_PORT"
ok "sshd слушает порты $SSH_PORT и 22 (только ключ, только $NEW_USER)"

# ---------- 5. UFW ----------
step "5/9 Файрвол UFW"
if [ "$UFW_WAS_ACTIVE" = 0 ]; then
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
else
  warn "UFW уже активен: существующие политики и правила сохранены"
fi
ufw allow "$SSH_PORT/tcp" comment 'SSH' >/dev/null
echo 0 > /var/lib/vps-harden/added-port22
if ! ufw show added | grep -E '^ufw (allow|limit).* (22/tcp|22)( |$)' >/dev/null; then
  ufw allow 22/tcp comment 'vps-harden temporary SSH' >/dev/null
  echo 1 > /var/lib/vps-harden/added-port22
fi
ufw logging low >/dev/null
ufw --force enable >/dev/null
ok "Правила SSH добавлены, прежние правила UFW сохранены"

# ---------- 6. fail2ban ----------
step "6/9 fail2ban"
# Адрес, с которого запущен скрипт, в белый список: администратор не должен забанить сам себя
ADMIN_IP="${SSH_CLIENT:-}"; ADMIN_IP="${ADMIN_IP%% *}"
[[ "$ADMIN_IP" =~ ^[0-9a-fA-F.:]+$ ]] || ADMIN_IP=""
[ -n "$ADMIN_IP" ] && ok "Ваш адрес $ADMIN_IP не будет блокироваться fail2ban" || warn "Не удалось определить ваш IP, ignoreip без него"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w
ignoreip = 127.0.0.1/8 ::1 $ADMIN_IP

[sshd]
enabled = true
port    = $SSH_PORT,22
mode    = aggressive
EOF
chmod 644 /etc/fail2ban/jail.local
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban
for i in $(seq 1 10); do fail2ban-client ping >/dev/null 2>&1 && break; sleep 1; done
fail2ban-client status sshd >/dev/null 2>&1 && ok "fail2ban следит за SSH (5 ошибок за 10 минут → бан на час, дальше дольше)" || warn "fail2ban запущен, но jail sshd не ответил — проверьте: fail2ban-client status"

# ---------- 7. автообновления ----------
step "7/9 Автоматические обновления безопасности"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/52vps-unattended <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
chmod 644 /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/52vps-unattended
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "Обновления безопасности ставятся сами (без автоперезагрузки)"

# ---------- 8. sysctl ----------
step "8/9 Сетевые настройки ядра"
cat > /etc/sysctl.d/99-vps-hardening.conf <<'EOF'
# Защита от спуфинга и редиректов
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
# SYN-flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Ядро
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF
chmod 644 /etc/sysctl.d/99-vps-hardening.conf
sysctl --system >/dev/null 2>&1 || warn "Не все sysctl применились; проверьте sysctl --system"
ok "Обработка sysctl завершена"

# ---------- 9. время + утилиты ----------
step "9/9 Время и утилиты"
systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true
timedatectl set-ntp true >/dev/null 2>&1 || true
if systemctl is-active --quiet chrony; then ok "chrony работает"; else warn "Проверьте службу chrony"; fi

cat > /usr/local/bin/vps-status <<'EOF'
#!/usr/bin/env bash
# Краткая сводка защиты сервера
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
echo "== SSH ==";      ss -tlnp | awk '/sshd/ {print "  слушает", $4}' | sort -u
echo "== Файрвол =="; ufw status | sed 's/^/  /'
echo "== fail2ban =="; fail2ban-client status sshd 2>/dev/null | grep -E 'Currently banned|Total banned' | sed 's/^/  /'
echo "== Последние входы =="; last -n 8 -a 2>/dev/null | head -n 8 | sed 's/^/  /'
echo "== Неудачные попытки за сутки =="; echo "  $(journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep -c 'Failed\|Invalid user')"
echo "== Обновления =="; apt list --upgradable 2>/dev/null | grep -c upgradable | sed 's/^/  ждут установки: /'
echo "== Перезагрузка =="; [ -f /var/run/reboot-required ] && echo "  требуется (sudo reboot)" || echo "  не требуется"
EOF
chmod 755 /usr/local/bin/vps-status
ok "vps-status — сводка защиты"

# ---------- итог ----------
cat > "$ACCESS_FILE" <<EOF
VPS настроен harden.sh $(date -Is)

Сервер:        $PUBLIC_IP
Пользователь:  $NEW_USER
Пароль (для sudo, вход по паролю через SSH ВЫКЛЮЧЕН):  $USER_PASS
SSH-порт:      $SSH_PORT

Подключение:   ssh -p $SSH_PORT $NEW_USER@$PUBLIC_IP
Сводка защиты: vps-status
Лог:           $LOG
Резервная копия старых настроек: $BACKUP_DIR
EOF
chmod 600 "$ACCESS_FILE"

echo
echo "${C_GRN}${C_BLD}=================================================================${C_RST}"
echo "${C_GRN}${C_BLD}  ГОТОВО. Теперь ОБЯЗАТЕЛЬНО, не закрывая это окно:${C_RST}"
echo "${C_GRN}${C_BLD}=================================================================${C_RST}"
echo
echo "  1. Откройте ВТОРОЕ окно терминала и подключитесь:"
echo
echo "       ${C_BLD}ssh -p $SSH_PORT $NEW_USER@$PUBLIC_IP${C_RST}"
echo
echo "  2. Если вошли — выполните там:"
echo
echo "       ${C_BLD}sudo vps-confirm${C_RST}"
echo
echo "     Спросит пароль sudo (он ниже). Это снимет страховку."
echo
echo "  3. После подтверждения перезагрузите сервер, чтобы обновления вступили в силу:"
echo
echo "       ${C_BLD}sudo reboot${C_RST}"
echo
echo "  Если за $ROLLBACK_MINUTES минут подтверждения не будет — SSH и файрвол сами вернутся"
echo "  к сохранённым настройкам. Пакеты и созданный пользователь не удаляются."
echo
if [ "$HAVE_TTY" = 1 ]; then
  # Отключаемся от tee и ждём, пока он допишет, иначе блок с паролем обгонит текст выше.
  exec >&3 2>&4
  for _ in $(seq 1 30); do kill -0 "$TEE_PID" 2>/dev/null || break; sleep 0.1; done
  tty_only "${C_YEL}${C_BLD}  СОХРАНИТЕ СЕЙЧАС в менеджер паролей или защищённую заметку:${C_RST}"
  tty_only ""
  tty_only "    пользователь: ${C_BLD}$NEW_USER${C_RST}"
  tty_only "    пароль sudo:  ${C_BLD}$USER_PASS${C_RST}"
  tty_only "    порт SSH:     ${C_BLD}$SSH_PORT${C_RST}"
  tty_only ""
  tty_only "${C_YEL}  Без пароля не будет работать sudo: ни подтверждение, ни VPN, ни обновления.${C_RST}"
  tty_only "  Копия в $ACCESS_FILE, но прочитать её можно только через тот же sudo."
  tty_only ""
else
  echo "  Данные для входа (пароль sudo, порт): sudo cat $ACCESS_FILE"
  echo
fi
