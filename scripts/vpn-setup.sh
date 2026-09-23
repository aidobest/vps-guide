#!/usr/bin/env bash
# =============================================================================
#  vpn-setup.sh — поднимает свой VPN на сервере за один запуск
#
#  Технология: Xray, протокол VLESS + Reality на порту 443.
#  Reality работает поверх TLS 1.3 на порту 443. Стабильность соединения
#  зависит от сети и настроек клиента.
#
#  Что делает:
#   1. Ставит Xray (официальный установщик XTLS), сервис работает под отдельным xray-vpn
#   2. Генерирует ключи Reality, UUID первого пользователя
#   3. Пишет конфиг: VLESS/Reality на 443, блок приватных сетей и торрентов
#   4. Открывает 443/tcp в файрволе, включает BBR (быстрее на дальних серверах)
#   5. Ставит команды управления: vpn-add, vpn-del, vpn-list, vpn-show
#   6. Показывает ссылку и QR-код для приложения
#
#  Запуск:   sudo bash vpn-setup.sh
#  Опции:    CLIENT_NAME=iphone  REALITY_SNI=www.samsung.com  sudo -E bash vpn-setup.sh
#
#  Требует: Ubuntu 22.04/24.04 или Debian 12/13. Порт 443 должен быть свободен.
# =============================================================================
set -Eeuo pipefail
umask 077

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
cat <<'HELP'
Использование:  sudo bash vpn-setup.sh
                CLIENT_NAME=iphone REALITY_SNI=www.samsung.com VPN_PORT=443 sudo -E bash vpn-setup.sh

Что делает: ставит Xray (VLESS + Reality на 443) под отдельным пользователем xray-vpn,
открывает порт в UFW, включает BBR, показывает ссылку и QR для приложения.

После установки:  sudo vpn-add ИМЯ   — новый пользователь, ссылка и QR
                  sudo vpn-show ИМЯ  — показать ссылку ещё раз
                  sudo vpn-list      — список и активные соединения
                  sudo vpn-del ИМЯ   — удалить
Лог: /var/log/vpn-setup.log
HELP
exit 0
fi

VERSION="0.4"
XRAY_DIR=/usr/local/etc/xray
XRAY_CONF=$XRAY_DIR/config.json
XRAY_USER=xray-vpn
XRAY_GROUP=xray-vpn
VPN_ENV=/etc/vpn/reality.env
LOG=/var/log/vpn-setup.log

if [ -t 1 ]; then C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_RED=$'\e[31m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'; else C_GRN=""; C_YEL=""; C_BLU=""; C_RED=""; C_BLD=""; C_RST=""; fi
step() { echo; echo "${C_BLU}${C_BLD}==> $*${C_RST}"; }
ok()   { echo "${C_GRN}    ✔ $*${C_RST}"; }
warn() { echo "${C_YEL}    ! $*${C_RST}"; }
die()  { echo "${C_RED}${C_BLD}ОШИБКА: $*${C_RST}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запускайте:  sudo bash vpn-setup.sh"
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export LC_ALL=C
unset XRAY_LOCATION_CONFDIR XRAY_LOCATION_CONFIG JSON_PATH JSONS_PATH DAT_PATH
command -v flock >/dev/null || die "Нужен flock (util-linux)"
[ ! -e /var/lib/vps-harden/pending ] || die "Сначала подтвердите настройку SSH: sudo vps-confirm"
exec 9>/run/lock/vpn-config.lock
flock -n 9 || die "Другая команда VPN уже выполняется"
WORK=$(mktemp -d)
MUTATED=0
BACKUP=""
cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && MUTATED == 1 )); then
    echo "Ошибка применения; восстанавливаю предыдущую конфигурацию VPN" >&2
    if [ -f "$BACKUP/config.json" ]; then
      cp -a "$BACKUP/config.json" "$XRAY_DIR/.restore.json" && mv -f "$XRAY_DIR/.restore.json" "$XRAY_CONF" || true
    else
      rm -f "$XRAY_CONF"
    fi
    if [ -f "$BACKUP/reality.env" ]; then
      cp -a "$BACKUP/reality.env" /etc/vpn/.restore.env && mv -f /etc/vpn/.restore.env "$VPN_ENV" || true
    else
      rm -f "$VPN_ENV"
    fi
    if [ -f "$BACKUP/override.conf" ]; then
      cp -a "$BACKUP/override.conf" /etc/systemd/system/xray.service.d/90-vps-managed.conf || true
    else
      rm -f /etc/systemd/system/xray.service.d/90-vps-managed.conf
    fi
    if [ -f "$BACKUP/dir-mode" ]; then
      read -r mode owner group < "$BACKUP/dir-mode"
      chown "$owner:$group" "$XRAY_DIR" && chmod "$mode" "$XRAY_DIR" || true
    fi
    for f in /usr/local/lib/vpn-common.sh /usr/local/bin/vpn-{add,del,list,show}; do
      if [ -f "$BACKUP/tools/$(basename "$f")" ]; then
        cp -a "$BACKUP/tools/$(basename "$f")" "$f" || true
      else
        rm -f "$f"
      fi
    done
    systemctl daemon-reload || true
    if [ "$(cat "$BACKUP/was-active")" = active ]; then
      systemctl restart xray || echo "Не удалось восстановить сервис; копия: $BACKUP" >&2
    else
      systemctl stop xray || true
    fi
    case "$(cat "$BACKUP/was-enabled")" in
      disabled) systemctl disable xray >/dev/null 2>&1 || true ;;
    esac
    echo "Проверьте сервис: systemctl status xray; копия: $BACKUP" >&2
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
touch "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "----- vpn-setup.sh v$VERSION $(date -Is) -----"

. /etc/os-release
case "${ID:-}" in ubuntu|debian) ok "ОС: $PRETTY_NAME" ;; *) die "Поддерживаются Ubuntu и Debian" ;; esac
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
  *) die "Поддерживаются Ubuntu 22.04/24.04 и Debian 12/13" ;;
esac

CLIENT_NAME="${CLIENT_NAME:-${SUDO_USER:-main}}"
REALITY_SNI="${REALITY_SNI:-www.samsung.com}"
VPN_PORT="${VPN_PORT:-443}"
[[ "$CLIENT_NAME" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "CLIENT_NAME: латиница, цифры, . _ - (до 32 символов)"
[[ "$REALITY_SNI" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "REALITY_SNI должен быть доменом, например www.samsung.com"
[[ "$VPN_PORT" =~ ^[0-9]{1,5}$ ]] || die "Некорректный VPN_PORT"
VPN_PORT=$((10#$VPN_PORT))
[[ "$VPN_PORT" =~ ^[0-9]+$ ]] && [ "$VPN_PORT" -ge 1 ] && [ "$VPN_PORT" -le 65535 ] || die "VPN_PORT: число 1–65535"

if [ -f "$VPN_ENV" ] || [ -f "$XRAY_CONF" ]; then
  warn "VPN уже настроен ($VPN_ENV). Для новых пользователей используйте: sudo vpn-add ИМЯ"
  if [ "${RESET_VPN:-0}" != 1 ]; then
    read -r -p "    Создать VPN заново, заменив всех клиентов и ключи? [y/N] " a
    [[ "${a,,}" == y ]] || exit 1
  fi
fi
if ss -H -tlnp "sport = :$VPN_PORT" | grep . >/dev/null; then
  if ss -H -tlnp "sport = :$VPN_PORT" | grep -v '"xray"' >/dev/null; then
    die "Порт $VPN_PORT занят другой программой"
  fi
fi

# ---------- 1. пакеты и Xray ----------
step "1/6 Установка Xray"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get -y -q install curl jq qrencode openssl ca-certificates unzip python3 util-linux
if ! id "$XRAY_USER" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin "$XRAY_USER"
fi
[ "$(id -u "$XRAY_USER")" -ne 0 ] || die "Служебный пользователь не должен иметь UID 0"
[ "$(id -gn "$XRAY_USER")" = "$XRAY_GROUP" ] || die "Неожиданная основная группа $XRAY_USER"
case "$(getent passwd "$XRAY_USER" | cut -d: -f7)" in */nologin|*/false) ;; *) die "$XRAY_USER должен быть служебной учётной записью без shell" ;; esac
install -d -m 700 /var/backups/vpn
BACKUP=$(mktemp -d /var/backups/vpn/setup.XXXXXXXX)
[ ! -f "$XRAY_CONF" ] || { cp -a "$XRAY_CONF" "$BACKUP/config.json"; }
[ ! -f "$VPN_ENV" ] || cp -a "$VPN_ENV" "$BACKUP/reality.env"
[ ! -f /etc/systemd/system/xray.service.d/90-vps-managed.conf ] || cp -a /etc/systemd/system/xray.service.d/90-vps-managed.conf "$BACKUP/override.conf"
if [ -d "$XRAY_DIR" ]; then stat -c '%a %u %g' "$XRAY_DIR" > "$BACKUP/dir-mode"; fi
mkdir -p "$BACKUP/tools"
for f in /usr/local/lib/vpn-common.sh /usr/local/bin/vpn-{add,del,list,show}; do
  [ ! -f "$f" ] || cp -a "$f" "$BACKUP/tools/$(basename "$f")"
done
systemctl is-active xray > "$BACKUP/was-active" 2>/dev/null || true
systemctl is-enabled xray > "$BACKUP/was-enabled" 2>/dev/null || true
# Не обновляем существующий бинарник во время изменения конфигурации.
if [ ! -x /usr/local/bin/xray ]; then
  INSTALLER_REF=e741a4f56d368afbb9e5be3361b40c4552d3710d
  curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 120 \
    "https://raw.githubusercontent.com/XTLS/Xray-install/$INSTALLER_REF/install-release.sh" -o "$WORK/installer.sh"
  bash -n "$WORK/installer.sh"
  # Не передаём установщику переменные альтернативных путей конфигурации.
  # Вывод установщика — только в лог: его «Failed to enable and start» до появления конфига
  # нормален (сервис запускаем на шаге 5), но пугает. При ошибке показываем хвост.
  echo "    Официальный установщик XTLS, подробности в $LOG"
  if ! env -u JSON_PATH -u JSONS_PATH -u DAT_PATH bash "$WORK/installer.sh" install -u "$XRAY_USER" \
       >>"$LOG" 2>&1 </dev/null; then
    tail -n 20 "$LOG" >&2
    die "Установщик Xray завершился с ошибкой"
  fi
fi
[ -x /usr/local/bin/xray ] || die "Xray не установлен"
ok "$(xray version | sed -n '1p')"

# ---------- 2. ключи ----------
step "2/6 Ключи"
KEYS=$(xray x25519)
# Форматы разных версий: "Private key: X" / "Public key: Y" (до 25.x) и "PrivateKey: X" / "Password (PublicKey): Y" (26.x)
PRIV=$(printf '%s\n' "$KEYS" | awk 'tolower($0) ~ /^private[[:space:]]*key:/ {print $NF; exit}')
PUB=$(printf '%s\n' "$KEYS"  | awk 'tolower($0) ~ /^(public[[:space:]]*key|publickey|password( \(publickey\))?):/ {print $NF; exit}')
[[ "$PRIV" =~ ^[A-Za-z0-9_-]{43}$ && "$PUB" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "Неизвестный формат xray x25519"
printf '%s' "$PRIV" > "$WORK/private-key"
SID=$(openssl rand -hex 8)
UUID=$(xray uuid)
[ -n "$PRIV" ] && [ -n "$PUB" ] && [ -n "$UUID" ] || die "Не удалось сгенерировать ключи Reality"
PUBLIC_IP="${VPN_HOST:-}"
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP=$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org) || die "Не удалось определить адрес; задайте VPN_HOST"
fi
python3 - "$PUBLIC_IP" <<'PYIP'
import ipaddress, sys
try:
    addr = ipaddress.IPv4Address(sys.argv[1])
    assert addr.is_global
except (ValueError, AssertionError):
    sys.exit('VPN_HOST должен быть публичным IPv4-адресом')
PYIP
ok "Ключи Reality, UUID для «$CLIENT_NAME»"

# Проверка сайта для Reality НАСТОЯЩИМ рукопожатием: поднимаем на локальном порту временный сервер с этими же
# ключами и клиента к нему. Проверка через openssl не годится: сайт может отвечать по TLS 1.3, а Reality
# всё равно не сможет скопировать его рукопожатие (так было с www.microsoft.com из Сингапура).
# Ждём, пока временный xray начнёт слушать порт (до 5 с), вместо фиксированной паузы.
wait_port() { local i; for i in $(seq 1 50); do ss -Hltn "sport = :$1" 2>/dev/null | grep -q . && return 0; sleep 0.1; done; return 1; }
reality_ok() {
  local t="$1" sport cport sp cp out
  sport=$(( (RANDOM % 10000) + 40000 )); cport=$(( sport + 1 ))
  jq -n --arg t "$t" --arg u "$UUID" --rawfile priv "$WORK/private-key" --arg sid "$SID" --arg p "$sport" '{
    log:{loglevel:"error"},
    inbounds:[{listen:"127.0.0.1",port:($p|tonumber),protocol:"vless",
      settings:{clients:[{id:$u,flow:"xtls-rprx-vision"}],decryption:"none"},
      streamSettings:{network:"tcp",security:"reality",
        realitySettings:{target:($t+":443"),serverNames:[$t],privateKey:$priv,shortIds:[$sid]}}}],
    outbounds:[{protocol:"freedom"}]}' > "$WORK/t_server.json"
  jq -n --arg t "$t" --arg u "$UUID" --arg pub "$PUB" --arg sid "$SID" --arg sp "$sport" --arg cp "$cport" '{
    log:{loglevel:"error"},
    inbounds:[{listen:"127.0.0.1",port:($cp|tonumber),protocol:"socks"}],
    outbounds:[{protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:($sp|tonumber),
      users:[{id:$u,encryption:"none",flow:"xtls-rprx-vision"}]}]},
      streamSettings:{network:"tcp",security:"reality",
        realitySettings:{serverName:$t,fingerprint:"chrome",publicKey:$pub,shortId:$sid}}}]}' > "$WORK/t_client.json"
  xray run -c "$WORK/t_server.json" >/dev/null 2>&1 & sp=$!
  wait_port "$sport" || true
  xray run -c "$WORK/t_client.json" >/dev/null 2>&1 & cp=$!
  wait_port "$cport" || true
  out=$(curl -s -m 10 --socks5-hostname "127.0.0.1:$cport" https://api.ipify.org 2>/dev/null || true)
  kill "$sp" "$cp" 2>/dev/null; wait "$sp" "$cp" 2>/dev/null || true
  [ -n "$out" ]
}
if reality_ok "$REALITY_SNI"; then
  ok "Сайт для Reality $REALITY_SNI: рукопожатие прошло"
else
  warn "$REALITY_SNI не подходит для Reality с этого сервера, подбираю другой"
  FOUND=""
  for cand in www.samsung.com dl.google.com www.yahoo.com www.cloudflare.com www.apple.com www.speedtest.net; do
    [ "$cand" = "$REALITY_SNI" ] && continue
    if reality_ok "$cand"; then FOUND="$cand"; break; fi
  done
  [ -n "$FOUND" ] || die "Ни один сайт не прошёл проверку Reality. Проверьте исходящий интернет: curl -I https://www.google.com"
  REALITY_SNI="$FOUND"; ok "Сайт для Reality: $REALITY_SNI"
fi

# ---------- 3. конфиг ----------
step "3/6 Конфигурация"
TMPCONF="$WORK/config.json"
jq -n --arg port "$VPN_PORT" --arg uuid "$UUID" --arg name "$CLIENT_NAME" --arg sni "$REALITY_SNI" --rawfile priv "$WORK/private-key" --arg sid "$SID" '{
  log: { loglevel: "warning" },
  inbounds: [{
    tag: "vless-reality", listen: "0.0.0.0", port: ($port|tonumber), protocol: "vless",
    settings: { clients: [ { id: $uuid, flow: "xtls-rprx-vision", email: $name } ], decryption: "none" },
    streamSettings: {
      network: "tcp", security: "reality",
      realitySettings: { show: false, target: ($sni + ":443"), xver: 0, serverNames: [ $sni ], privateKey: $priv, shortIds: [ $sid ] }
    },
    sniffing: { enabled: true, destOverride: [ "http", "tls", "quic" ], routeOnly: true }
  }],
  outbounds: [ { protocol: "freedom", tag: "direct" }, { protocol: "blackhole", tag: "block" } ],
  routing: { domainStrategy: "IPIfNonMatch", rules: [
    { type: "field", ip: [ "geoip:private" ], outboundTag: "block" },
    { type: "field", protocol: [ "bittorrent" ], outboundTag: "block" }
  ] }
}' > "$TMPCONF"
xray run -test -format json -config "$TMPCONF" >/dev/null || { rm -f "$TMPCONF"; die "Xray не принял конфиг"; }
MUTATED=1
install -d -m 750 -o root -g "$XRAY_GROUP" "$XRAY_DIR"
install -d -m 700 /etc/vpn
NEXT=$(mktemp "$XRAY_DIR/.config.XXXXXXXX")
install -m 640 -o root -g "$XRAY_GROUP" "$TMPCONF" "$NEXT"
mv -f "$NEXT" "$XRAY_CONF"
runuser -u "$XRAY_USER" -- /usr/local/bin/xray run -test -format json -config "$XRAY_CONF" >/dev/null
cat > /etc/vpn/.reality.env.new <<EOF
# Параметры VPN (создано vpn-setup.sh $(date -Is)). Приватный ключ — только в $XRAY_CONF
VPN_HOST=$PUBLIC_IP
VPN_PORT=$VPN_PORT
REALITY_SNI=$REALITY_SNI
REALITY_PUB=$PUB
REALITY_SID=$SID
XRAY_USER=$XRAY_USER
XRAY_GROUP=$XRAY_GROUP
EOF
chmod 600 /etc/vpn/.reality.env.new
mv -f /etc/vpn/.reality.env.new "$VPN_ENV"
install -d -m 755 /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/90-vps-managed.conf <<'EOF'
[Service]
User=xray-vpn
Group=xray-vpn
ExecStart=
ExecStart=/usr/local/bin/xray run -format json -config /usr/local/etc/xray/config.json
Environment=XRAY_LOCATION_CONFIG=/usr/local/etc/xray
UnsetEnvironment=XRAY_LOCATION_CONFDIR xray.location.confdir
CapabilityBoundingSet=
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/usr/local/etc/xray
UMask=0077
EOF
chmod 644 /etc/systemd/system/xray.service.d/90-vps-managed.conf
systemctl daemon-reload
[ "$(systemctl show xray -p User --value)" = "$XRAY_USER" ] || die "Другой systemd override меняет пользователя Xray"
[ "$(systemctl show xray -p Group --value)" = "$XRAY_GROUP" ] || die "Другой systemd override меняет группу Xray"
ok "Конфиг проверен, сервис закреплён за $XRAY_USER"

# ---------- 5. команды управления ----------
step "4/6 Команды управления"
# общая библиотека для команд
install -d -m 755 /usr/local/lib /usr/local/bin
cat > /usr/local/lib/vpn-common.sh <<'EOF'
# Общая библиотека команд VPN. Вызывается только после проверки root.
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export LC_ALL=C
CONF=/usr/local/etc/xray/config.json
LOCK=/run/lock/vpn-config.lock
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]; }
client_uuid() { jq -r --arg n "$1" '.inbounds[0].settings.clients[] | select(.email==$n) | .id' "$CONF"; }
lock_config() { exec 9>"$LOCK"; flock 9; . /etc/vpn/reality.env; }
# Вывод использует уже взятую вызывающей командой блокировку.
show_client() {
  local name="$1" uuid link
  uuid=$(client_uuid "$name")
  [ -n "$uuid" ] || { echo "Пользователь «$name» не найден"; return 1; }
  link="vless://$uuid@$VPN_HOST:$VPN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID&type=tcp#VPN-$name"
  printf '\nПользователь: %s\n\nСсылка:\n%s\n\nQR:\n' "$name" "$link"
  if ! qrencode -t ANSIUTF8 -m 2 "$link"; then
    echo "ВНИМАНИЕ: QR не построен; используйте ссылку выше." >&2
  fi
  echo
}
healthy() {
  local i
  for i in 1 2 3 4 5; do
    sleep 1
    if systemctl is-active --quiet xray && ss -H -tlnp "sport = :$VPN_PORT" | grep '"xray"' >/dev/null; then
      sleep 1
      systemctl is-active --quiet xray && return 0
    fi
  done
  return 1
}
# Вызывается после lock_config; проверка предусловий тоже должна быть под lock.
write_conf() {
  local filter="$1"; shift
  local tmp backup
  tmp=$(mktemp "$(dirname "$CONF")/.config.XXXXXXXX")
  install -d -m 700 /var/backups/vpn
  backup=$(mktemp /var/backups/vpn/config.XXXXXXXX)
  cp "$CONF" "$backup"
  chmod 600 "$backup"
  # Локальная EXIT-ловушка остаётся до конца команды: ошибку после записи
  # восстанавливаем атомарно. SIGKILL/потеря питания не обрабатываются shell.
  VPN_TMP="$tmp"; VPN_BACKUP="$backup"; VPN_APPLIED=0
  trap 'rc=$?; trap - EXIT; if (( rc != 0 && VPN_APPLIED == 1 )); then
    install -m 640 -o root -g "$XRAY_GROUP" "$VPN_BACKUP" "$VPN_TMP" && mv -f "$VPN_TMP" "$CONF"
    systemctl restart xray || echo "Не удалось запустить прежний конфиг; копия: $VPN_BACKUP" >&2
  fi; rm -f "$VPN_TMP"; exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  jq "$@" "$filter" "$CONF" > "$tmp"
  chown root:"$XRAY_GROUP" "$tmp"; chmod 640 "$tmp"
  runuser -u "$XRAY_USER" -- /usr/local/bin/xray run -test -format json -config "$tmp" >/dev/null
  VPN_APPLIED=1
  mv -f "$tmp" "$CONF"
  systemctl restart xray
  healthy || { echo "Новый конфиг не запустился; восстанавливаю предыдущий" >&2; exit 1; }
  VPN_APPLIED=0
  # Блокировка удерживается до завершения процесса.
}
EOF
chmod 644 /usr/local/lib/vpn-common.sh

cat > /usr/local/bin/vpn-show <<'EOF'
#!/usr/bin/env bash
# vpn-show ИМЯ — ссылка и QR для пользователя
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
. /usr/local/lib/vpn-common.sh
lock_config
NAME="${1:-}"; valid_name "$NAME" || { echo "Использование: vpn-show ИМЯ"; exit 1; }
show_client "$NAME"
EOF
cat > /usr/local/bin/vpn-add <<'EOF'
#!/usr/bin/env bash
# vpn-add ИМЯ — новый пользователь VPN
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
. /usr/local/lib/vpn-common.sh
lock_config
NAME="${1:-}"; valid_name "$NAME" || { echo "Использование: vpn-add ИМЯ  (латиница, цифры, - _ . до 32 символов)"; exit 1; }
[ -z "$(client_uuid "$NAME")" ] || { echo "«$NAME» уже есть. Показать: vpn-show $NAME"; exit 1; }
UUID=$(xray uuid)
write_conf '.inbounds[0].settings.clients += [{"id":$u,"flow":"xtls-rprx-vision","email":$n}]' --arg n "$NAME" --arg u "$UUID"
echo "Добавлен: $NAME"
show_client "$NAME"
EOF
cat > /usr/local/bin/vpn-del <<'EOF'
#!/usr/bin/env bash
# vpn-del ИМЯ — удалить пользователя VPN
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
. /usr/local/lib/vpn-common.sh
lock_config
NAME="${1:-}"; valid_name "$NAME" || { echo "Использование: vpn-del ИМЯ"; exit 1; }
[ -n "$(client_uuid "$NAME")" ] || { echo "«$NAME» не найден"; exit 1; }
[ "$(jq '.inbounds[0].settings.clients | length' "$CONF")" -gt 1 ] || { echo "Нельзя удалить последнего пользователя"; exit 1; }
write_conf '.inbounds[0].settings.clients |= map(select(.email!=$n))' --arg n "$NAME"
echo "Удалён: $NAME"
EOF
cat > /usr/local/bin/vpn-list <<'EOF'
#!/usr/bin/env bash
# vpn-list — пользователи и состояние VPN
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
. /usr/local/lib/vpn-common.sh
lock_config
echo "Сервер: $VPN_HOST:$VPN_PORT  SNI: $REALITY_SNI  xray: $(systemctl is-active xray || true)"
echo "Пользователи:"
jq -r '.inbounds[0].settings.clients[].email' "$CONF" | sed 's/^/  • /'
echo "Активных соединений: $(ss -Htn state established "( sport = :$VPN_PORT )" | wc -l)"
EOF
chmod 755 /usr/local/bin/vpn-show /usr/local/bin/vpn-add /usr/local/bin/vpn-del /usr/local/bin/vpn-list
ok "vpn-add ИМЯ · vpn-del ИМЯ · vpn-list · vpn-show ИМЯ"

# ---------- 6. запуск ----------
step "5/6 Запуск"
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1
systemctl is-active xray >/dev/null || { journalctl -u xray -n 20 --no-pager; die "xray не запустился"; }
ss -H -tlnp "sport = :$VPN_PORT" | grep '"xray"' >/dev/null || die "xray не слушает $VPN_PORT"
ok "xray работает, порт $VPN_PORT"
# Конфигурация работает. Ошибки сети дальше сообщаются отдельно.
MUTATED=0
# ---------- 4. сеть ----------
step "6/6 Файрвол и BBR"
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  if ufw allow "$VPN_PORT/tcp" comment 'VPN (Reality)' >/dev/null; then
    ok "UFW: разрешён $VPN_PORT/tcp"
  else
    die "VPN запущен, но UFW не обновлён. Выполните: ufw allow $VPN_PORT/tcp"
  fi
else
  warn "UFW не активен. Доступность порта зависит от других файрволов и панели хостинга"
fi
cat > /etc/sysctl.d/98-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
chmod 644 /etc/sysctl.d/98-bbr.conf
sysctl --system >/dev/null 2>&1 || true
sysctl net.ipv4.tcp_congestion_control | grep -q bbr && ok "BBR включён" || warn "BBR недоступен в этом ядре, работаем без него"



echo
echo "${C_GRN}${C_BLD}================  VPN ГОТОВ  ================${C_RST}"
echo
echo "  Приложения:  iPhone — V2Box, Happ, Streisand (бесплатные) или Shadowrocket"
echo "               Android — Hiddify или v2rayNG"
echo "               Mac — Happ, V2Box, Hiddify, Shadowrocket;  Windows — Happ, Hiddify, v2rayN"
echo "  В приложении: «+» → «Добавить из буфера» (вставить ссылку) или сканировать QR."
echo
echo "  Если хостер даёт свой облачный файрвол (панель хостера), откройте там TCP $VPN_PORT."
echo
# ссылка и QR — только на экран, мимо лога
flock -u 9
if { : >/dev/tty; } 2>/dev/null; then vpn-show "$CLIENT_NAME" >/dev/tty; else echo "  Ссылка и QR: sudo vpn-show $CLIENT_NAME"; fi
echo "  Новый пользователь (телефон, ноутбук, родственник):  ${C_BLD}sudo vpn-add ИМЯ${C_RST}"
echo "  Список:                                              ${C_BLD}sudo vpn-list${C_RST}"
echo
