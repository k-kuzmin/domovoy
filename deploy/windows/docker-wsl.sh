#!/usr/bin/env bash
# docker из Git Bash в движок дистрибутива domovoy-engine (#6).
#
#   bash deploy/windows/docker-wsl.sh compose ps
#
# Выполняет docker с теми же аргументами внутри дистрибутива, в текущем
# каталоге: каталог Windows wsl.exe открывает как /mnt/<диск>/…, поэтому
# относительные пути compose (./config) движок находит. Для ~/.bashrc:
#
#   docker() { bash "<клон>/deploy/windows/docker-wsl.sh" "$@"; }
#
# Пределы:
#   - абсолютные пути Windows в аргументах (D:\…, /d/…) не переводятся —
#     внутри дистрибутива их нет; относительные пути работают;
#   - функция из ~/.bashrc есть только в интерактивной оболочке; сценарии
#     ops/backup/*.sh запускаются внутри дистрибутива (README, «Автозапуск»),
#     а не через обёртку;
#   - -it у docker exec зависит от TTY Git Bash (mintty без winpty его не даёт).
#
# DOMOVOY_ENGINE_DISTRO — другое имя дистрибутива, по умолчанию domovoy-engine.

set -euo pipefail

# Git Bash переписывает аргументы вида /app/config в пути Windows раньше,
# чем их увидит wsl.exe; движок должен получить их как есть.
export MSYS_NO_PATHCONV=1

distro="${DOMOVOY_ENGINE_DISTRO:-domovoy-engine}"

if ! command -v cygpath >/dev/null 2>&1; then
  echo "docker-wsl: нужен Git Bash (cygpath) — внутри дистрибутива вызывайте docker напрямую" >&2
  exit 2
fi
here="$(cygpath -w "$PWD")"

# --exec: аргументы уходят в docker как есть, без разбора оболочкой Linux.
exec wsl.exe -d "$distro" --cd "$here" --exec docker "$@"
