"""Вопросы к тому Home Assistant для бэкапа и проверки восстановления.

Запускается python3 внутри контейнера homeassistant (стандартная
библиотека, без пакетов) и в тестах на хосте:

    count        <реестр>                              число не отключённых записей
    compare      <реестр> <состояния|-> [--expect N]   «N из M» сущностей реестра в /api/states
    sqlite-check <база>                                PRAGMA integrity_check
    sqlite-check-all <каталог>                         integrity_check каждой базы sqlite каталога, число баз
    sqlite-backup <база> <копия>                       онлайн-копия через sqlite3 backup API
    archive      <каталог>                             tar.gz тома в stdout, живые sqlite — онлайн-копией;
                                                       в stderr «registry_enabled N» по реестру из архива
    extract      <каталог>                             tar.gz со stdin в пустой каталог

Вывод — только числа и служебные строки. Ни entity_id, ни содержимое
реестра и состояний не печатаются: вывод уходит в лог CI, в backup.log
и комментарием в issue, а entity_id — приватные данные дома.

Коды: 0 — совпало, 1 — расхождение, 2 — ошибка входных данных.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import sqlite3
import stat
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
# Реестр сущностей в архиве: без него восстановленный HA не знает
# устройств, и бэкап без него — отказ.
REGISTRY_ARCNAME = ".storage/core.entity_registry"


class CheckError(Exception):
    """Ошибка входных данных: ответ — код 2 и сообщение, а не число."""


def load_registry(path: str) -> list:
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as err:
        raise CheckError(f"реестр сущностей не прочитан: {err.strerror}") from err
    return parse_registry(raw)


def parse_registry(raw: bytes) -> list:
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


def integrity_problem(path: str) -> str | None:
    """None, если PRAGMA integrity_check базы ответил «ok», иначе — что не так."""
    name = os.path.basename(path)
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            rows = connection.execute("PRAGMA integrity_check").fetchall()
        finally:
            connection.close()
    except sqlite3.DatabaseError as err:
        return f"{name}: {err}"
    if rows == [("ok",)]:
        return None
    return f"{name}: integrity_check нашёл {len(rows)} нарушений"


def sqlite_check(path: str) -> int:
    # sqlite3.connect создал бы отсутствующий файл и честно сказал бы «ok».
    if not os.path.isfile(path):
        raise CheckError(f"базы {os.path.basename(path)} нет")
    problem = integrity_problem(path)
    print(problem or "ok")
    return EXIT_MISMATCH if problem else 0


def sqlite_check_all(config_dir: str) -> int:
    """integrity_check каждой базы sqlite в каталоге — тех же, что archive
    находит по сигнатуре и кладёт онлайн-копией. Рекордер HA обязателен.
    Печатает число проверенных баз; при сбое — имя базы и нарушения."""
    if not os.path.isfile(os.path.join(config_dir, "home-assistant_v2.db")):
        raise CheckError("базы home-assistant_v2.db нет")
    checked = 0
    failed = False
    for root, dirs, files in os.walk(config_dir):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            if os.path.islink(path) or not is_sqlite(path):
                continue
            checked += 1
            problem = integrity_problem(path)
            if problem:
                print(problem)
                failed = True
    print(checked)
    return EXIT_MISMATCH if failed else 0


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


def add_registry(tar: tarfile.TarFile, path: str, arcname: str) -> int:
    """Реестр сущностей в архив; число его не отключённых записей.

    Файл читается один раз: в архив ложатся те же байты, по которым
    посчитано число. HA переписывает реестр на ходу, и второе чтение того
    же пути могло бы дать манифесту число другой версии.
    """
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
            info = tar.gettarinfo(arcname=arcname, fileobj=handle)
    except OSError as err:
        raise CheckError(f"реестр сущностей HA не прочитан: {err.strerror}") from err
    enabled = len(enabled_entity_ids(parse_registry(raw)))
    info.size = len(raw)
    tar.addfile(info, io.BytesIO(raw))
    return enabled


def check_link(info: tarfile.TarInfo, config_dir: str) -> None:
    """Ссылка проходит то же правило, что у extract (filter="data").

    Ссылку с абсолютной целью или выходящую за пределы тома extract
    отвергает вместе со всем архивом: бэкап с ней записался бы успешным, а
    восстановление из него упало бы. Поэтому отказ — здесь, при снятии.
    Корень — сам том: realpath проходит по его настоящим ссылкам, то есть
    по тому дереву, которое распаковка воссоздаёт. Имя ссылки в сообщение
    не пишется: str(FilterError) его содержит. OSError — сбой realpath
    (петля ссылок при строгом realpath): распаковку такой ссылки никто не
    обещает, отказ осторожный; общий обработчик main напечатал бы путь.
    """
    try:
        tarfile.data_filter(info, config_dir)
    except (tarfile.FilterError, OSError) as err:
        raise CheckError(
            f"в томе HA ссылка, которую восстановление не распакует ({type(err).__name__}): "
            "ссылки тома должны быть относительными и вести внутрь тома"
        ) from None


def add_ordinary(tar: tarfile.TarFile, path: str, arcname: str, config_dir: str) -> None:
    """Обычный файл или ссылка; исчезнувший после обхода — пропуск.

    HA пишет временные файлы рядом с .storage и удаляет их: такой файл
    может пропасть между os.walk и записью. Пропажа обнаруживается при
    lstat или open, до записи заголовка, поэтому поток архива она не портит.

    Обычный файл открывается один раз, и размер в заголовке берётся fstat
    того же открытого файла. HA заменяет .storage/* атомарно (временный
    файл и os.replace): tar.add взял бы размер по пути, а читал бы путь
    заново — уже другой файл, и в архив лёг бы обрезанный JSON.

    Реестр и базы sqlite сюда не попадают — их пропажа остаётся ошибкой.
    Имя файла в предупреждение не пишется: вывод модуля — только числа и
    служебные строки.
    """
    try:
        mode = os.lstat(path).st_mode
        # Сокеты и FIFO в архив не идут: восстанавливать в них нечего.
        if stat.S_ISLNK(mode):
            info = tar.gettarinfo(path, arcname=arcname)
            check_link(info, config_dir)
            tar.addfile(info)
        elif stat.S_ISREG(mode):
            with open(path, "rb") as handle:
                info = tar.gettarinfo(arcname=arcname, fileobj=handle)
                tar.addfile(info, handle)
    except FileNotFoundError:
        print("предупреждение: файл исчез во время архивации и пропущен", file=sys.stderr)


def archive(config_dir: str) -> int:
    """tar.gz каталога в stdout; каждая база sqlite — онлайн-копией.

    Копия файла живой базы в режиме WAL неконсистентна: часть транзакций
    лежит в -wal. Поэтому базы (рекордер HA, zigbee.db и любые другие)
    находятся по сигнатуре sqlite и кладутся в архив копией через backup
    API, а их -wal/-shm/-journal не кладутся вовсе.

    Число не отключённых записей реестра, попавшего в архив, печатается в
    stderr строкой «registry_enabled N»: stdout занят архивом.
    """
    config_dir = os.path.abspath(config_dir)
    staging = tempfile.mkdtemp(prefix="domovoy-backup-")
    registry_enabled = None
    try:
        with tarfile.open(fileobj=sys.stdout.buffer, mode="w|gz") as tar:
            for root, dirs, files in os.walk(config_dir):
                dirs.sort()
                relative_root = os.path.relpath(root, config_dir)
                if relative_root != ".":
                    try:
                        tar.add(root, arcname=relative_root.replace(os.sep, "/"), recursive=False)
                    except FileNotFoundError:
                        # Каталог удалён после обхода: его файлов тоже нет.
                        print("предупреждение: каталог исчез во время архивации и пропущен", file=sys.stderr)
                        dirs[:] = []
                        continue
                # Ссылку на каталог os.walk кладёт в dirs и в неё не
                # спускается: в архив она идёт ссылкой, а не пропадает.
                for name in dirs:
                    path = os.path.join(root, name)
                    if os.path.islink(path):
                        arcname = os.path.normpath(os.path.join(relative_root, name)).replace(os.sep, "/")
                        add_ordinary(tar, path, arcname, config_dir)
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
                    elif arcname == REGISTRY_ARCNAME:
                        registry_enabled = add_registry(tar, path, arcname)
                    else:
                        add_ordinary(tar, path, arcname, config_dir)
            if registry_enabled is None:
                raise CheckError(f"реестр сущностей HA: в томе нет {REGISTRY_ARCNAME}")
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    print(f"registry_enabled {registry_enabled}", file=sys.stderr)
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
    "sqlite-check <база> | sqlite-check-all <каталог> | sqlite-backup <база> <копия> | "
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
        if len(argv) == 2 and argv[0] == "sqlite-check-all":
            return sqlite_check_all(argv[1])
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
