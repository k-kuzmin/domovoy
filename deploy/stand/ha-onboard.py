#!/usr/bin/env python3
"""Онбординг Home Assistant стенда агента и отчёт о нём (scripts/stand.sh).

Исполняется python3 внутри контейнера HA стенда: aiohttp в образе HA уже
есть, новой зависимости нет. Адрес — HA того же контейнера, 127.0.0.1:8123.

    python3 ha-onboard.py onboard <id реестра-примера>...
        Онбординг чистого HA: пользователь, токен доступа, долгоживущий токен
        (WebSocket auth/long_lived_access_token), переименование сущностей
        demo в id реестра-примера (config/entity_registry/update).
        stdout — только долгоживущий токен, одной строкой: его перехватывает
        stand.sh и пишет в .env стенда. Ход работы — в stderr, без секретов.

    python3 ha-onboard.py report <id реестра-примера>...
        Токен — первой строкой stdin (не аргументом: аргументы видны в списке
        процессов). stdout — три строки:
            http <HTTP-код GET /api/ с токеном>
            renamed <число сущностей demo под id реестра-примера>
            missing <id реестра-примера, которых нет в HA, через пробел>

Код возврата: 0 — успех, 1 — отказ (причина в stderr), 2 — ошибка вызова.
Пароль пользователя онбординга случайный и нигде не сохраняется: стенду
нужен только долгоживущий токен.
"""

import asyncio
import secrets
import sys

import aiohttp

BASE = "http://127.0.0.1:8123"
WS_URL = BASE + "/api/websocket"
CLIENT_ID = BASE + "/"
WAIT_SECONDS = 300

# id реестра-примера -> сущности demo, из которых он получается, по порядку
# предпочтения. Домен у пары один: реестр HA меняет только object_id.
# Карта построена по списку сущностей demo в реестре HA 2026.10.1 с первого
# живого прогона стенда (#164), а не по памяти. media_player и lock в
# реестре сущностей demo на этом прогоне не оказалось, окна среди
# binary_sensor demo нет: эти id остаются отсутствующими, их называет status,
# шаблонами они не создаются.
RENAMES = {
    "light.example_kitchen_ceiling": ["light.kitchen_lights"],
    "light.example_living_room_ceiling": [
        "light.living_room_rgbww_lights",
        "light.ceiling_lights",
    ],
    "vacuum.example_living_room_robot": ["vacuum.demo_vacuum_0_ground_floor"],
    "sensor.example_bedroom_temperature": ["sensor.outside_temperature"],
    "sensor.example_bedroom_humidity": ["sensor.outside_humidity"],
    "binary_sensor.example_kitchen_leak": ["binary_sensor.basement_floor_wet"],
    "climate.example_bedroom_ac": ["climate.hvac"],
    "climate.example_kitchen_boiler_thermostat": ["climate.ecobee"],
}


class Refusal(Exception):
    """Отказ по существу: причина уходит в stderr, код 1."""


def log(message):
    print(f"ha-onboard: {message}", file=sys.stderr, flush=True)


async def wait_http(session):
    """Ждёт, пока HTTP-сервер HA начнёт отвечать на /api/onboarding."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + WAIT_SECONDS
    while True:
        try:
            async with session.get(BASE + "/api/onboarding") as response:
                if response.status == 200:
                    return
        except aiohttp.ClientError:
            pass
        if loop.time() > deadline:
            raise Refusal(f"HA стенда не ответил на /api/onboarding за {WAIT_SECONDS} с")
        await asyncio.sleep(2)


class Socket:
    """WebSocket HA: авторизация и вызовы с ожиданием результата по id."""

    def __init__(self, ws):
        self._ws = ws
        self._next = 1

    async def auth(self, token):
        hello = await self._ws.receive_json()
        if hello.get("type") != "auth_required":
            raise Refusal(f"WebSocket: неожиданное приветствие {hello.get('type')}")
        await self._ws.send_json({"type": "auth", "access_token": token})
        answer = await self._ws.receive_json()
        if answer.get("type") != "auth_ok":
            raise Refusal(f"WebSocket: авторизация не прошла ({answer.get('type')})")

    async def call(self, payload):
        message_id = self._next
        self._next += 1
        await self._ws.send_json({"id": message_id, **payload})
        while True:
            answer = await self._ws.receive_json()
            if answer.get("id") != message_id or answer.get("type") != "result":
                continue
            if not answer.get("success"):
                error = answer.get("error") or {}
                raise Refusal(f"{payload['type']}: {error.get('code')} {error.get('message')}")
            return answer.get("result")


async def wait_running(sock):
    """Ждёт состояния RUNNING: к нему demo уже зарегистрировал сущности."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + WAIT_SECONDS
    while True:
        config = await sock.call({"type": "get_config"})
        if config.get("state") == "RUNNING":
            return
        if loop.time() > deadline:
            raise Refusal(f"HA стенда не дошёл до RUNNING за {WAIT_SECONDS} с")
        await asyncio.sleep(2)


async def rename(sock, wanted):
    registry = await sock.call({"type": "config/entity_registry/list"})
    demo = sorted(e["entity_id"] for e in registry if e.get("platform") == "demo")
    log("сущности demo: " + " ".join(demo))

    present = {e["entity_id"] for e in registry}
    used = set()
    renamed = 0
    for target in wanted:
        if target not in RENAMES:
            continue
        if target in present:
            renamed += 1
            continue
        source = next((c for c in RENAMES[target] if c in present and c not in used), None)
        if source is None:
            log(f"нет пары в demo: {target}")
            continue
        used.add(source)
        try:
            await sock.call(
                {"type": "config/entity_registry/update", "entity_id": source, "new_entity_id": target}
            )
        except Refusal as error:
            # Без unique_id реестр сущность не переименует: она уходит в
            # отсутствующие, up при этом не падает.
            log(f"не переименована {source} -> {target}: {error}")
            continue
        renamed += 1
        log(f"переименована {source} -> {target}")
    log(f"переименовано сущностей demo: {renamed}")


async def onboard(wanted):
    async with aiohttp.ClientSession() as session:
        await wait_http(session)

        async with session.post(
            BASE + "/api/onboarding/users",
            json={
                "client_id": CLIENT_ID,
                "name": "Стенд агента",
                "username": "stand",
                # Случайный и нигде не сохраняется: нужен только токен.
                "password": secrets.token_urlsafe(32),
                "language": "ru",
            },
        ) as response:
            if response.status != 200:
                raise Refusal(f"онбординг пользователя: HTTP {response.status} (HA уже прошёл онбординг?)")
            auth_code = (await response.json())["auth_code"]

        async with session.post(
            BASE + "/auth/token",
            data={"grant_type": "authorization_code", "code": auth_code, "client_id": CLIENT_ID},
        ) as response:
            if response.status != 200:
                raise Refusal(f"обмен кода онбординга: HTTP {response.status}")
            access = (await response.json())["access_token"]

        headers = {"Authorization": f"Bearer {access}"}
        # Остальные шаги онбординга нужны только интерфейсу HA; их отказ
        # стенду не мешает и up не роняет.
        for step, body in (
            ("core_config", {}),
            ("analytics", {}),
            ("integration", {"client_id": CLIENT_ID, "redirect_uri": CLIENT_ID}),
        ):
            async with session.post(f"{BASE}/api/onboarding/{step}", json=body, headers=headers) as response:
                if response.status != 200:
                    log(f"шаг онбординга {step}: HTTP {response.status}, пропущен")

        async with session.ws_connect(WS_URL) as ws:
            sock = Socket(ws)
            await sock.auth(access)
            await wait_running(sock)
            token = await sock.call(
                {"type": "auth/long_lived_access_token", "client_name": "domovoy-stand", "lifespan": 3650}
            )
            await rename(sock, wanted)

    if not isinstance(token, str) or not token:
        raise Refusal("HA не выдал долгоживущий токен")
    print(token, flush=True)


async def report(wanted):
    token = sys.stdin.readline().strip()
    async with aiohttp.ClientSession() as session:
        async with session.get(BASE + "/api/", headers={"Authorization": f"Bearer {token}"}) as response:
            code = response.status
        print(f"http {code}", flush=True)
        if code != 200 or not token:
            print("renamed 0")
            print("missing " + " ".join(wanted))
            return

        async with session.ws_connect(WS_URL) as ws:
            sock = Socket(ws)
            await sock.auth(token)
            registry = await sock.call({"type": "config/entity_registry/list"})
            states = await sock.call({"type": "get_states"})

    demo = {e["entity_id"] for e in registry if e.get("platform") == "demo"}
    present = {s["entity_id"] for s in states}
    print(f"renamed {sum(1 for target in wanted if target in demo)}")
    print("missing " + " ".join(target for target in wanted if target not in present))


def main(argv):
    if len(argv) < 2 or argv[1] not in ("onboard", "report"):
        print("usage: ha-onboard.py onboard|report <entity_id>...", file=sys.stderr)
        return 2
    mode, wanted = argv[1], argv[2:]
    try:
        asyncio.run(onboard(wanted) if mode == "onboard" else report(wanted))
    except Refusal as error:
        log(f"отказ: {error}")
        return 1
    except aiohttp.ClientError as error:
        # Текст исключения aiohttp не несёт заголовков запроса: токена в нём нет.
        log(f"отказ: HA стенда недоступен: {type(error).__name__}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
