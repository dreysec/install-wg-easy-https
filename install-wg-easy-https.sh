#!/usr/bin/env bash
# Интерактивная установка wg-easy + Caddy (публичный HTTPS)
# Целевая система: чистый Ubuntu / Debian сервер, root или sudo.
# Никаких изменений до итогового подтверждения.
set -Eeuo pipefail

WG_DIR='/etc/docker/containers/wg-easy'
CADDY_DIR='/opt/caddy'
WG_PORT='51820'

fail() { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
ask_yes() {
  local reply
  read -r -p "${1} [y/N]: " reply
  [[ "${reply,,}" == 'y' || "${reply,,}" == 'yes' || "${reply,,}" == 'д' || "${reply,,}" == 'да' ]]
}

on_error() {
  local status=$?
  printf '\nОшибка на строке %s (код %s). Установка могла завершиться частично.\n' "$1" "$status" >&2
  printf 'Проверьте журнал команд и файлы в %s и %s.\n' "$WG_DIR" "$CADDY_DIR" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
  cat <<'HELP'
Интерактивная установка wg-easy (edge или 15.5.0) + Caddy + HTTPS.
Запуск позднее: sudo bash install-wg-easy-https.sh
Скрипт задаёт вопросы и ничего не меняет до явного подтверждения.
Нужны чистый Ubuntu/Debian, домен с DNS A на VPS и доступные порты:
TCP 80/443, UDP 51820. SSH-порт скрипт не изменяет.
HELP
  exit 0
fi

[[ $# -eq 0 ]] || fail 'Неизвестные аргументы. Используйте --help.'
[[ $EUID -eq 0 ]] || fail 'Запустите от root: sudo bash install-wg-easy-https.sh'
[[ -t 0 ]] || fail 'Нужен интерактивный терминал (stdin/TTY).'
[[ -r /etc/os-release ]] || fail 'Не найден /etc/os-release.'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == 'ubuntu' || "${ID:-}" == 'debian' ]] || fail 'Поддерживаются только Ubuntu и Debian.'
[[ -n "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}" ]] || fail 'Не определён код релиза ОС.'
[[ "$(dpkg --print-architecture)" == 'amd64' || "$(dpkg --print-architecture)" == 'arm64' ]] || fail 'Нужна архитектура amd64 или arm64.'

printf '%s\n' '======================================================'
printf '%s\n' '    wg-easy + Caddy + HTTPS | интерактивная установка'
printf '%s\n' '======================================================'
printf 'Система: %s\n' "${PRETTY_NAME:-$ID}"
printf '%s\n' 'Предназначено для НОВОГО сервера без действующего wg-easy/Caddy.'

while true; do
  read -r -p 'Домен панели и VPN (например vpn.example.com): ' DOMAIN
  DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')"
  if [[ ${#DOMAIN} -le 253 && "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
    break
  fi
  printf '%s\n' 'Некорректный домен. Без https://, портов и путей.'
done

while true; do
  read -r -p 'Email для уведомлений центра сертификации (необязательно, Enter = без email): ' ACME_EMAIL
  if [[ -z "$ACME_EMAIL" || "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    break
  fi
  printf '%s\n' 'Некорректный email. Попробуйте ещё раз или нажмите Enter.'
done

printf '\nВерсия wg-easy:\n  1) edge (как на текущем сервере; тестовая, может меняться)\n  2) 15.5.0 (фиксированный стабильный релиз)\n'
while true; do
  read -r -p 'Выберите [1/2], по умолчанию 1: ' IMAGE_CHOICE
  case "${IMAGE_CHOICE:-1}" in
    1) WG_TAG='edge'; break ;;
    2) WG_TAG='15.5.0'; break ;;
    *) printf '%s\n' 'Введите 1 или 2.' ;;
  esac
done

if [[ "$WG_TAG" == 'edge' ]]; then
  printf '\nВНИМАНИЕ: edge не закреплён за неизменяемой версией и может содержать ошибки.\n'
fi

# Проверки, не изменяющие систему.
[[ ! -e "$WG_DIR/docker-compose.yml" && ! -e "$WG_DIR/compose.yml" ]] || fail "Найдена установка в $WG_DIR; перезапись запрещена."
[[ ! -e "$CADDY_DIR/compose.yml" && ! -e "$CADDY_DIR/Caddyfile" ]] || fail "Найден Caddy в $CADDY_DIR; перезапись запрещена."

if command -v docker >/dev/null 2>&1; then
  if ! docker compose version >/dev/null 2>&1; then
    fail 'Docker найден, но Compose plugin отсутствует. Обновите Docker/Compose вручную перед запуском.'
  fi
  if docker ps -a --format '{{.Names}}' | grep -Eq '^(wg-easy|caddy)$'; then
    fail 'Контейнер wg-easy или caddy уже существует. Установщик не трогает чужие контейнеры.'
  fi
  if docker network inspect caddy >/dev/null 2>&1; then
    fail 'Docker-сеть caddy уже существует. Установщик рассчитан на чистый сервер.'
  fi
  if docker volume inspect wg-easy_etc_wireguard >/dev/null 2>&1; then
    fail 'Том wg-easy_etc_wireguard уже существует. Не рискуем существующими ключами.'
  fi
else
  if dpkg-query -W -f='${Status}' docker.io 2>/dev/null | grep -q 'install ok installed'; then
    fail 'Обнаружен пакет docker.io. Удаление/замену Docker нужно выполнить вручную.'
  fi
fi

if command -v ss >/dev/null 2>&1; then
  if ss -H -ltn 2>/dev/null | grep -Eq ':(80|443)[[:space:]]'; then
    fail 'TCP-порт 80 или 443 уже занят. Проверьте ss -lntp.'
  fi
  if ss -H -lun 2>/dev/null | grep -Eq ":${WG_PORT}[[:space:]]"; then
    fail "UDP-порт ${WG_PORT} уже занят. Проверьте ss -lnup."
  fi
fi

DNS_IPS="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '$2=="STREAM" { print $1 }' | sort -u | paste -sd, - || true)"
PUBLIC_IP=''
if command -v curl >/dev/null 2>&1; then
  PUBLIC_IP="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
fi
printf '\nDNS A сейчас: %s\n' "${DNS_IPS:-не найдено}"
printf 'Публичный IPv4 этого сервера: %s\n' "${PUBLIC_IP:-не удалось определить}"
if [[ -z "$DNS_IPS" ]]; then
  printf '%s\n' 'ВНИМАНИЕ: DNS A ещё не настроен. Caddy не сможет выпустить сертификат до исправления DNS.'
elif [[ -n "$PUBLIC_IP" && ",$DNS_IPS," != *",$PUBLIC_IP,"* ]]; then
  printf '%s\n' 'ВНИМАНИЕ: DNS A не совпадает с публичным IPv4 сервера.'
fi
printf '%s\n' 'Если есть запись AAAA, она тоже должна вести на рабочий IPv6 сервера.'

OPEN_UFW='no'
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  printf '\nUFW активен. Существующие правила и SSH не будут изменены.\n'
  if ask_yes "Добавить разрешения TCP 80,443 и UDP ${WG_PORT} в UFW?"; then
    OPEN_UFW='yes'
  fi
fi

printf '\n================ ПРОВЕРЬТЕ НАСТРОЙКИ ================\n'
printf 'Домен:       %s\n' "$DOMAIN"
printf 'Email ACME:  %s\n' "${ACME_EMAIL:-не задан}"
printf 'Образ:       ghcr.io/wg-easy/wg-easy:%s\n' "$WG_TAG"
printf 'WireGuard:   UDP %s (внешний и внутренний)\n' "$WG_PORT"
printf 'Панель:      https://%s\n' "$DOMAIN"
printf 'Папка WG:    %s\n' "$WG_DIR"
printf 'Папка Caddy: %s\n' "$CADDY_DIR"
printf 'Правка UFW:  %s\n' "$OPEN_UFW"
printf '%s\n' 'Будет установлен Docker (если отсутствует), созданы файлы и запущены контейнеры.'
printf '%s\n' 'В ОБЛАЧНОМ ФАЙРВОЛЕ откройте TCP 80/443 и UDP 51820 отдельно.'
printf '=====================================================\n'

if ! ask_yes 'Начать установку на этом сервере?'; then
  printf '%s\n' 'Отменено. Ничего не изменено.'
  exit 0
fi

install_docker() {
  info 'Установка Docker из официального APT-репозитория'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local suite="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${suite}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

if ! command -v docker >/dev/null 2>&1; then
  install_docker
else
  info 'Используем уже установленный Docker'
fi
systemctl enable --now docker

docker compose version >/dev/null || fail 'Docker Compose недоступен.'
COMPOSE_VERSION="$(docker compose version --short | sed 's/^v//;s/+.*//')"
if ! dpkg --compare-versions "$COMPOSE_VERSION" ge '2.36.0'; then
  fail "Требуется Docker Compose >= 2.36.0 (установлен: $COMPOSE_VERSION)."
fi

# Повторная проверка после установки Docker, перед записью файлов.
[[ ! -e "$WG_DIR/docker-compose.yml" && ! -e "$CADDY_DIR/compose.yml" ]] || fail 'Появилась существующая конфигурация, остановлено.'
if docker network inspect caddy >/dev/null 2>&1; then
  fail 'Сеть caddy уже существует; отмена во избежание конфликта.'
fi

info 'Создаём папки и выделенную сеть Caddy'
install -d -m 0750 "$WG_DIR" "$CADDY_DIR"
docker network create caddy >/dev/null

cat > "$WG_DIR/docker-compose.yml" <<WG_COMPOSE
volumes:
  etc_wireguard:

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:${WG_TAG}
    container_name: wg-easy
    restart: unless-stopped
    environment:
      - PORT=80
      - HOST=0.0.0.0
      - INSECURE=false
    networks:
      wg:
        interface_name: eth0
        gw_priority: 1
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a
      caddy:
        interface_name: eth1
        gw_priority: 0
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "${WG_PORT}:51820/udp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1

networks:
  wg:
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
        - subnet: fdcc:ad94:bacf:61a3::/64
  caddy:
    external: true
WG_COMPOSE

cat > "$CADDY_DIR/compose.yml" <<'CADDY_COMPOSE'
services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80/tcp"
      - "443:443/tcp"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - caddy

volumes:
  caddy_data:
  caddy_config:

networks:
  caddy:
    external: true
CADDY_COMPOSE

if [[ -n "$ACME_EMAIL" ]]; then
  cat > "$CADDY_DIR/Caddyfile" <<CADDY_WITH_EMAIL
{
    email ${ACME_EMAIL}
}

${DOMAIN} {
    encode zstd gzip
    reverse_proxy wg-easy:80
}
CADDY_WITH_EMAIL
else
  cat > "$CADDY_DIR/Caddyfile" <<CADDY_NO_EMAIL
${DOMAIN} {
    encode zstd gzip
    reverse_proxy wg-easy:80
}
CADDY_NO_EMAIL
fi

chmod 0640 "$WG_DIR/docker-compose.yml" "$CADDY_DIR/compose.yml" "$CADDY_DIR/Caddyfile"

info 'Проверяем Compose-конфигурации'
docker compose -f "$WG_DIR/docker-compose.yml" config --quiet
docker compose -f "$CADDY_DIR/compose.yml" config --quiet

if [[ "$OPEN_UFW" == 'yes' ]]; then
  info 'Открываем порты UFW (SSH-правила не трогаем)'
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow "${WG_PORT}/udp"
fi

info 'Запускаем WireGuard'
docker compose -f "$WG_DIR/docker-compose.yml" up -d
info 'Запускаем Caddy'
docker compose -f "$CADDY_DIR/compose.yml" up -d

printf '\n==================== ГОТОВО ====================\n'
printf 'Панель: https://%s\n' "$DOMAIN"
printf 'WireGuard: UDP %s\n' "$WG_PORT"
printf 'После DNS и настройки портов Caddy автоматически запросит TLS-сертификат.\n'
printf 'Завершите первоначальную настройку в веб-панели, включите 2FA.\n'
printf 'В мастере wg-easy укажите публичный endpoint %s и порт %s.\n' "$DOMAIN" "$WG_PORT"
printf '\nПроверка:\n'
printf '  docker logs caddy --tail 50\n'
printf '  docker logs wg-easy --tail 50\n'
printf '  docker exec wg-easy ip -4 route\n'
printf '  docker exec wg-easy iptables -t nat -S POSTROUTING\n'
printf '\nКаталоги: %s и %s\n' "$WG_DIR" "$CADDY_DIR"
printf '================================================\n'
