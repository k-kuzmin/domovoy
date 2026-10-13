#!/usr/bin/env bash
# Провижининг дистрибутива domovoy-engine: Docker Engine под systemd.
#
#   wsl.exe -d domovoy-engine -u root --cd <клон> --exec bash deploy/windows/provision-engine.sh [<клон>]
#
# Запускает deploy/windows/engine-setup.ps1 -Install, внутри дистрибутива и
# под root. Повторный запуск ничего не дублирует:
#   1. /etc/wsl.conf — [boot] systemd=true; прочие строки файла остаются;
#   2. репозиторий apt Docker по официальной инструкции для Ubuntu
#      (https://docs.docker.com/engine/install/ubuntu/): ключ в
#      /etc/apt/keyrings/docker.asc, источник /etc/apt/sources.list.d/docker.list;
#   3. пакеты docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin,
#      docker-compose-plugin и git;
#   4. systemctl enable docker.service и containerd.service — автозапуск
#      движка вместе с systemd дистрибутива;
#   5. юнит domovoy-mss-clamp.service: правило iptables (mangle FORWARD)
#      TCPMSS --clamp-mss-to-pmtu. Без него HTTPS из контейнеров в сети моста
#      (MTU 1500) через интерфейс хоста с MTU меньше (VPN) висит: крупные
#      пакеты TLS теряются, nuget при сборке api не отвечает. Сеть хоста
#      (--network host) этим не страдает;
#   6. git safe.directory (--system) для клона: клон лежит на диске Windows
#      (/mnt/<диск>/…) и принадлежит не root, а ops/backup/*.sh вызывают git;
#   7. журнал systemd на диске со сбросом раз в 10 с — drop-in
#      /etc/systemd/journald.conf.d/domovoy-journal.conf (Storage=persistent,
#      SyncIntervalSec=10s), и драйвер логов движка journald —
#      /etc/docker/daemon.json {"log-driver": "journald"}. Перезапуск или
#      выключение Windows гасит ВМ без остановки контейнеров (запись 0028):
#      json-file терял последние минуты логов, журнал — не больше 10 с.
#      Чужой daemon.json не переписывается — отказ с кодом 1. Драйвер
#      действует на контейнеры, созданные после перезапуска docker:
#      существующие пересоздаются (README, «Логи и хронология загрузки»).
#
# systemd начинает работать только после перезапуска дистрибутива. Если он
# ещё не PID 1, сценарий записывает wsl.conf и выходит с кодом 3:
# engine-setup.ps1 выполняет wsl --terminate domovoy-engine и запускает
# провижининг повторно — пакеты ставятся и службы включаются уже под
# systemd, как у обычной Ubuntu.

set -euo pipefail

# ensure_wsl_conf <файл> — [boot] systemd=true; прочее содержимое не трогается.
ensure_wsl_conf() {
  local file="$1"
  if [ -f "$file" ] && grep -Eq '^[[:blank:]]*systemd[[:blank:]]*=[[:blank:]]*true[[:blank:]]*$' "$file"; then
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  if [ -f "$file" ] && grep -Eq '^[[:blank:]]*systemd[[:blank:]]*=' "$file"; then
    # systemd=false или иное значение — заменить строку.
    sed -E 's/^[[:blank:]]*systemd[[:blank:]]*=.*/systemd=true/' "$file" >"$tmp"
  elif [ -f "$file" ] && grep -Eq '^[[:blank:]]*\[boot\][[:blank:]]*$' "$file"; then
    sed -E '/^[[:blank:]]*\[boot\][[:blank:]]*$/a systemd=true' "$file" >"$tmp"
  else
    if [ -s "$file" ]; then
      cat "$file" >"$tmp"
      [ -z "$(tail -c 1 "$file")" ] || printf '\n' >>"$tmp"
      printf '\n' >>"$tmp"
    fi
    printf '[boot]\nsystemd=true\n' >>"$tmp"
  fi
  cat "$tmp" >"$file"
  rm -f -- "$tmp"
}

# apt_get <аргументы> — apt-get, ждущий чужую блокировку dpkg, а не падающий
# сразу. После старта дистрибутива apt-daily-upgrade.service запускает
# unattended-upgrades, и тот держит /var/lib/dpkg/lock-frontend минутами:
# apt-get install без ожидания выходит с кодом 100 «Could not get lock».
# DPkg::Lock::Timeout — штатный ключ apt (configure-index: dpkg::lock::timeout);
# по истечении apt-get падает так же, как без ключа. Блокировку списков
# /var/lib/apt/lists/lock у apt-get update ключ не ждёт — проверено на apt 2.8.
apt_get() {
  apt-get -o DPkg::Lock::Timeout=900 "$@"
}

install_docker() {
  export DEBIAN_FRONTEND=noninteractive
  apt_get update
  apt_get install -y ca-certificates curl git
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -s /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  fi
  chmod a+r /etc/apt/keyrings/docker.asc
  local codename arch line
  # shellcheck source=/dev/null
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
  arch="$(dpkg --print-architecture)"
  line="deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable"
  if [ "$(cat /etc/apt/sources.list.d/docker.list 2>/dev/null || true)" != "$line" ]; then
    printf '%s\n' "$line" >/etc/apt/sources.list.d/docker.list
  fi
  apt_get update
  apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# ensure_mss_clamp — юнит systemd, ставящий правило при каждом старте
# дистрибутива (правила iptables не переживают перезапуск). -C перед -A —
# повторный старт правило не дублирует. Путь юнита — аргументом, для теста.
ensure_mss_clamp() {
  local unit="${1:-/etc/systemd/system/domovoy-mss-clamp.service}"
  local rule='-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
  local content
  content="[Unit]
Description=domovoy: TCP MSS clamp to PMTU for container traffic
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t mangle -C FORWARD $rule 2>/dev/null || iptables -t mangle -A FORWARD $rule'

[Install]
WantedBy=multi-user.target"
  if [ "$(cat "$unit" 2>/dev/null || true)" != "$content" ]; then
    printf '%s\n' "$content" >"$unit"
    systemctl daemon-reload
  fi
  systemctl enable domovoy-mss-clamp.service
  systemctl start domovoy-mss-clamp.service
}

# ensure_journald [<каталог drop-in>] — журнал systemd на диске
# (Storage=persistent) со сбросом раз в 10 с (SyncIntervalSec, по умолчанию
# 5 мин). Файл пишется, только если отличается; прочие файлы каталога не
# трогаются. Каталог — аргументом, для теста.
ensure_journald() {
  local dir="${1:-/etc/systemd/journald.conf.d}"
  local file="$dir/domovoy-journal.conf"
  local content='[Journal]
Storage=persistent
SyncIntervalSec=10s'
  if [ "$(cat "$file" 2>/dev/null || true)" != "$content" ]; then
    mkdir -p "$dir"
    printf '%s\n' "$content" >"$file"
    systemctl restart systemd-journald.service
  fi
}

# ensure_docker_log_driver [<daemon.json>] — драйвер логов движка journald.
# Файла нет — пишется; log-driver уже journald — не трогается; иной
# log-driver или чужие ключи без него — отказ с кодом 1: настройка, которую
# сценарий не писал, не переписывается и не объединяется (как .wslconfig в
# engine-setup.ps1). Действует после перезапуска docker. Путь — аргументом,
# для теста.
ensure_docker_log_driver() {
  local file="${1:-/etc/docker/daemon.json}"
  local want='"log-driver": "journald"'
  if [ ! -e "$file" ]; then
    mkdir -p "$(dirname "$file")"
    printf '{%s}\n' "$want" >"$file"
    return 0
  fi
  if grep -Eq '"log-driver"[[:space:]]*:[[:space:]]*"journald"' "$file"; then
    return 0
  fi
  local current
  current="$(grep -Eo '"log-driver"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" | head -n 1 || true)"
  if [ -n "$current" ]; then
    echo "provision-engine: $file задаёт $current — чужая настройка не переписывается; движку нужен $want (запись 0028): поправьте файл руками и повторите" >&2
  else
    echo "provision-engine: $file уже есть и не задаёт log-driver — чужие настройки не объединяются; добавьте в объект JSON ключ $want руками и повторите" >&2
  fi
  return 1
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "provision-engine: нужен root — wsl.exe -d domovoy-engine -u root …" >&2
    exit 1
  fi
  local clone="${1:-}"
  if [ -z "$clone" ]; then
    clone="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
  fi
  [ -d "$clone" ] || { echo "provision-engine: каталога клона нет: $clone" >&2; exit 1; }

  ensure_wsl_conf /etc/wsl.conf
  if [ "$(cat /proc/1/comm 2>/dev/null || true)" != systemd ]; then
    echo "provision-engine: systemd включён в /etc/wsl.conf, но ещё не запущен — перезапустите дистрибутив (wsl --terminate) и повторите" >&2
    exit 3
  fi
  install_docker
  systemctl enable docker.service containerd.service
  ensure_mss_clamp
  ensure_journald
  ensure_docker_log_driver
  if ! git config --system --get-all safe.directory 2>/dev/null | grep -qxF "$clone"; then
    git config --system --add safe.directory "$clone"
  fi
  echo "provision-engine: готово — systemd включён в /etc/wsl.conf, docker, containerd и MSS clamp в автозапуске, журнал systemd на диске (сброс 10 с), драйвер логов docker journald (после перезапуска дистрибутива), safe.directory: $clone"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
