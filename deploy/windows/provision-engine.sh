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
#   5. git safe.directory (--system) для клона: клон лежит на диске Windows
#      (/mnt/<диск>/…) и принадлежит не root, а ops/backup/*.sh вызывают git.
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

install_docker() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl git
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
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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
  if ! git config --system --get-all safe.directory 2>/dev/null | grep -qxF "$clone"; then
    git config --system --add safe.directory "$clone"
  fi
  echo "provision-engine: готово — systemd включён в /etc/wsl.conf, docker и containerd в автозапуске, safe.directory: $clone"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
