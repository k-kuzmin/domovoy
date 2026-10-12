"""Вопросы к тому Home Assistant для бэкапа и проверки восстановления.

Запускается python3 внутри контейнера homeassistant (стандартная
библиотека, без пакетов) и в тестах на хосте:

    count        <реестр>                              число не отключённых записей
    compare      <реестр> <состояния|-> [--expect N]   «N из M» сущностей реестра в /api/states
    sqlite-check <база>                                PRAGMA integrity_check
    sqlite-backup <база> <копия>                       онлайн-копия через sqlite3 backup API
    archive      <каталог>                             tar.gz тома в stdout, живые sqlite — онлайн-копией
    extract      <каталог>                             tar.gz со stdin в пустой каталог

Вывод — только числа и служебные строки. Ни entity_id, ни содержимое
реестра и состояний не печатаются: вывод уходит в лог CI, в backup.log
и комментарием в issue, а entity_id — приватные данные дома.

Коды: 0 — совпало, 1 — расхождение, 2 — ошибка входных данных.
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import sys
import tarfile
import tempfile

EXIT_MISMATCH = 1
EXIT_ERROR = 2

SQLITE_MAGIC = b"SQLite format 3\x00"
# Спутники базы sqlite: в архив идёт онлайн-копия самой базы, а эти файлы
# описывают её живое состояние и рядом с копией смысла не имеют.
SQLITE_SIDECARS = ("-wal", "-shm", "-journal")
# Журнал HA дописывается непрерывно и для восстановления не нужен.
SKIPPED_PREFIXES = ("home-assistant.log",)


class CheckError(Exception):
    """Ошибка входных данных: ответ — код 2 и сообщение, а не число."""


def load_registry(path: str) -> list:
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as err:
        raise CheckError(f"реестр сущностей не прочитан: {err.strerror}") from err
    if not raw.strip():
        raise CheckError("реестр сущностей пуст")
    try:
        document = json.loads(raw)
    except ValueError as err:
        raise CheckError("реестр сущностей не разбирается как JSON") from err
    data = document.get("data") if isinstance(document, dict) else None
    entities = data.get("entities") if isinstance(data, dict) else None
    if not isinstance(entities, list):
        raise CheckError("в реестре сущностей нет списка data.entities")
    return entities


def enabled_entity_ids(entities: list) -> set:
    """entity_id записей без disabled_by — тех, что HA обязан показать."""
    ids = set()
    for entry in entities:
        if not isinstance(entry, dict) or not isinstance(entry.get("entity_id"), str):
            raise CheckError("в реестре запись без entity_id")
        if entry.get("disabled_by") is None:
            ids.add(entry["entity_id"])
    return ids


def load_states(path: str) -> set:
    try:
        if path == "-":
            raw = sys.stdin.buffer.read()
        else:
            with open(path, "rb") as handle:
                raw = handle.read()
    except OSError as err:
        raise CheckError(f"ответ /api/states не прочитан: {err.strerror}") from err
    try:
        states = json.loads(raw)
    except ValueError as err:
        raise CheckError("ответ /api/states не разбирается как JSON") from err
    if not isinstance(states, list):
        raise CheckError("ответ /api/states — не список состояний")
    return {item.get("entity_id") for item in states if isinstance(item, dict)}


def count(registry_path: str) -> int:
    print(len(enabled_entity_ids(load_registry(registry_path))))
    return 0


def compare(registry_path: str, states_path: str, expect: int | None) -> int:
    enabled = enabled_entity_ids(load_registry(registry_path))
    present = enabled & load_states(states_path)
    print(f"{len(present)} из {len(enabled)}")
    if expect is not None and len(enabled) != expect:
        print(f"в реестре {len(enabled)} не отключённых записей, в манифесте {expect}")
        return EXIT_MISMATCH
    return 0 if present == enabled else EXIT_MISMATCH


def is_sqlite(path: str) -> bool:
    try:
        with open(path, "rb") as handle:
            return handle.read(len(SQLITE_MAGIC)) == SQLITE_MAGIC
    except OSError:
        return False


def sqlite_check(path: str) -> int:
    # sqlite3.connect создал бы отсутствующий файл и честно сказал бы «ok».
    if not os.path.isfile(path):
        raise CheckError(f"базы {os.path.basename(path)} нет")
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            rows = connection.execute("PRAGMA integrity_check").fetchall()
        finally:
            connection.close()
    except sqlite3.DatabaseError as err:
        print(f"{os.path.basename(path)}: {err}")
        return EXIT_MISMATCH
    if rows == [("ok",)]:
        print("ok")
        return 0
    print(f"{os.path.basename(path)}: integrity_check нашёл {len(rows)} нарушений")
    return EXIT_MISMATCH


def sqlite_backup(source_path: str, target_path: str) -> None:
    """Консистентная копия живой базы, без остановки того, кто в неё пишет."""
    if not is_sqlite(source_path):
        raise CheckError(f"{os.path.basename(source_path)} — не база sqlite")
    source = sqlite3.connect(source_path, timeout=60)
    target = sqlite3.connect(target_path)
    try:
        source.backup(target)
        # Копия — самостоятельный файл: без -wal рядом и в обычном режиме
        # журнала. HA при старте сам переведёт её в WAL.
        target.execute("PRAGMA journal_mode=DELETE")
        target.commit()
    finally:
        target.close()
        source.close()


def archive(config_dir: str) -> int:
    """tar.gz каталога в stdout; каждая база sqlite — онлайн-копией.

    Копия файла живой базы в режиме WAL неконсистентна: часть транзакций
    лежит в -wal. Поэтому базы (рекордер HA, zigbee.db и любые другие)
    находятся по сигнатуре sqlite и кладутся в архив копией через backup
    API, а их -wal/-shm/-journal не кладутся вовсе.
    """
    config_dir = os.path.abspath(config_dir)
    staging = tempfile.mkdtemp(prefix="domovoy-backup-")
    try:
        with tarfile.open(fileobj=sys.stdout.buffer, mode="w|gz") as tar:
            for root, dirs, files in os.walk(config_dir):
                dirs.sort()
                relative_root = os.path.relpath(root, config_dir)
                if relative_root != ".":
                    tar.add(root, arcname=relative_root.replace(os.sep, "/"), recursive=False)
                names = set(files)
                databases = {name for name in names if is_sqlite(os.path.join(root, name))}
                sidecars = {db + suffix for db in databases for suffix in SQLITE_SIDECARS}
                for name in sorted(names):
                    path = os.path.join(root, name)
                    arcname = os.path.normpath(os.path.join(relative_root, name)).replace(os.sep, "/")
                    if name in sidecars or (relative_root == "." and name.startswith(SKIPPED_PREFIXES)):
                        continue
                    if name in databases:
                        snapshot = os.path.join(staging, "snapshot.db")
                        sqlite_backup(path, snapshot)
                        tar.add(snapshot, arcname=arcname, recursive=False)
                        os.remove(snapshot)
                    elif os.path.islink(path) or os.path.isfile(path):
                        tar.add(path, arcname=arcname, recursive=False)
            # Сокеты и FIFO в архив не идут: восстанавливать в них нечего.
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return 0


def extract(config_dir: str) -> int:
    if not os.path.isdir(config_dir):
        raise CheckError("каталога назначения нет")
    if os.listdir(config_dir):
        raise CheckError("каталог назначения не пуст — восстановление не перезаписывает данные")
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|gz") as tar:
        # filter="data" отказывает на абсолютных путях и ссылках за пределы
        # каталога: архив с внешнего носителя — чужие данные.
        tar.extractall(config_dir, filter="data")
    return 0


USAGE = (
    "использование: ha_registry_check.py "
    "count <реестр> | compare <реестр> <состояния|-> [--expect N] | "
    "sqlite-check <база> | sqlite-backup <база> <копия> | "
    "archive <каталог> | extract <каталог>"
)


def main(argv: list) -> int:
    # Вывод читают сценарии bash и сравнивают с «N из M» побайтно: кодировка
    # не должна зависеть от локали контейнера или консоли Windows.
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    try:
        if len(argv) == 2 and argv[0] == "count":
            return count(argv[1])
        if len(argv) in (3, 5) and argv[0] == "compare":
            expect = None
            if len(argv) == 5:
                if argv[3] != "--expect" or not argv[4].isdigit():
                    raise CheckError(USAGE)
                expect = int(argv[4])
            return compare(argv[1], argv[2], expect)
        if len(argv) == 2 and argv[0] == "sqlite-check":
            return sqlite_check(argv[1])
        if len(argv) == 3 and argv[0] == "sqlite-backup":
            sqlite_backup(argv[1], argv[2])
            return 0
        if len(argv) == 2 and argv[0] == "archive":
            return archive(argv[1])
        if len(argv) == 2 and argv[0] == "extract":
            return extract(argv[1])
        raise CheckError(USAGE)
    except CheckError as err:
        print(err, file=sys.stderr)
        return EXIT_ERROR
    except (OSError, sqlite3.Error, tarfile.TarError) as err:
        print(f"ошибка: {type(err).__name__}: {err}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
