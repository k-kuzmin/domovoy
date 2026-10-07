"""Статическая проверка прав .claude/settings.json (#133, пункты 12–14).

Права — страховка, а не граница (запись 0026, «Пределы»): шаблоны команд сопоставляются
целиком, `*` — любая последовательность символов; шаблоны путей — в духе .gitignore,
`**` — любое число каталогов, `*` — в пределах одного имени, `//` в начале — абсолютный путь.
Тест прогоняет обещанные формы против этой модели: живое поведение Claude Code проверяется
только новой сессией, а здесь ловится то, что правило забыли или написали так, что оно
закрывает нужное агенту.
"""

import io
import json
import os
import re
import unittest

HOOK_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(os.path.dirname(HOOK_DIR))
SETTINGS = os.path.join(REPO_ROOT, ".claude", "settings.json")

SHELLS = ("Bash", "PowerShell")
RULE = re.compile(r"^(?P<tool>[A-Za-z]+)(?:\((?P<arg>.*)\))?$", re.S)


def load_rules(kind):
    with io.open(SETTINGS, encoding="utf-8") as fh:
        cfg = json.load(fh)
    out = []
    for raw in cfg.get("permissions", {}).get(kind, []):
        m = RULE.match(raw)
        if m:
            out.append((m.group("tool"), m.group("arg"), raw))
    return out


def command_regex(pattern):
    return re.compile("".join(".*" if ch == "*" else re.escape(ch) for ch in pattern), re.S)


def path_regex(pattern):
    i, out = 0, []
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out), re.S)


def command_hits(rules, tool, command):
    return [raw for t, arg, raw in rules
            if t == tool and (arg is None or command_regex(arg).fullmatch(command))]


def path_hits(rules, tool, path):
    """path — относительный от корня проекта или абсолютный, начинающийся с «/»."""
    hits = []
    for t, arg, raw in rules:
        if t != tool:
            continue
        if arg is None:
            hits.append(raw)
            continue
        if arg.startswith("//"):
            if path.startswith("/") and path_regex(arg[1:]).fullmatch(path):
                hits.append(raw)
        elif not path.startswith("/") and path_regex(arg).fullmatch(path):
            hits.append(raw)
    return hits


SECRET_STORE = (
    "Users/user/AppData/Roaming/Microsoft/UserSecrets/0000-placeholder/secrets.json",
    "home/user/.microsoft/usersecrets/0000-placeholder/secrets.json",
)

ENV_VARIANTS = (".env.local", ".env.production")

LOCAL_CONFIG = (
    "src/Domovoy.Api/appsettings.Development.json",
    "src/Domovoy.Api/appsettings.Production.json",
    "src/Domovoy.Api/appsettings.Local.json",
    "docker-compose.override.yml",
    "docker-compose.override.yaml",
)

TRACKED_CONFIG = (
    "src/Domovoy.Api/appsettings.json",
    "docker-compose.override.example.yml",
    "docker-compose.yml",
)

FILE_TOOLS = ("Read", "Edit")
READ_COMMANDS = ("cat", "type", "Get-Content")


def both_forms(rel):
    """Относительная форма и та же, вынесенная под абсолютный путь клона."""
    return (rel, "/home/user/src/home-agent/" + rel)


class SettingsPermissions(unittest.TestCase):

    def setUp(self):
        self.deny = load_rules("deny")
        self.ask = load_rules("ask")

    def assertCommandDenied(self, tool, command):
        self.assertTrue(command_hits(self.deny, tool, command),
                        "%s(%s) не закрыта ни одним правилом deny" % (tool, command))

    def assertCommandOpen(self, tool, command):
        hits = command_hits(self.deny, tool, command) + command_hits(self.ask, tool, command)
        self.assertEqual(hits, [], "%s(%s) задета правилами" % (tool, command))

    def assertPathDenied(self, tool, path):
        self.assertTrue(path_hits(self.deny, tool, path),
                        "%s(%s) не закрыт ни одним правилом deny" % (tool, path))

    def assertPathOpen(self, tool, path):
        self.assertEqual(path_hits(self.deny, tool, path), [],
                         "%s(%s) закрыт правилом deny" % (tool, path))

    # Пункт 14.
    def test_ef_destructive_forms_denied(self):
        forms = (
            "dotnet ef --project src/Domovoy.Data database update",
            "dotnet ef -v database update",
            "dotnet-ef database update",
            "dotnet tool run dotnet-ef database update",
            "dotnet ef database drop --force",
            "dotnet-ef database drop",
            "dotnet tool run dotnet-ef database drop",
            "dotnet ef migrations remove",
            "dotnet ef --project src/Domovoy.Data migrations remove",
            "dotnet-ef migrations remove",
            "dotnet tool run dotnet-ef migrations remove",
        )
        for shell in SHELLS:
            for command in forms:
                with self.subTest(shell=shell, command=command):
                    self.assertCommandDenied(shell, command)

    def test_ef_agent_commands_open(self):
        commands = (
            "dotnet ef migrations add Initial --project src/Domovoy.Data --startup-project src/Domovoy.Api",
            "dotnet ef migrations script    --project src/Domovoy.Data --startup-project src/Domovoy.Api",
            # Рабочий набор оркестратора не должен задевать ни одно правило.
            "dotnet restore",
            "dotnet build --no-restore -c Release",
            "dotnet test --no-build -c Release",
            "dotnet format --verify-no-changes --no-restore",
            "git status",
            "git commit -m \"fix: placeholder\"",
            "gh issue view 133 --comments",
            "gh pr view 1 --json state",
        )
        for shell in SHELLS:
            for command in commands:
                with self.subTest(shell=shell, command=command):
                    self.assertCommandOpen(shell, command)

    # Пункт 12.
    def test_user_secrets_store_write_denied(self):
        for rel in SECRET_STORE:
            for path in (rel, "/" + rel):
                with self.subTest(path=path):
                    self.assertPathDenied("Edit", path)

    # Пункт 13.
    def test_env_variants_read_denied(self):
        for name in ENV_VARIANTS:
            for path in both_forms(name) + both_forms("deploy/" + name):
                with self.subTest(tool="Read", path=path):
                    self.assertPathDenied("Read", path)
            for shell in SHELLS:
                for cmd in READ_COMMANDS:
                    for arg in (name, "./" + name, "/home/user/src/home-agent/" + name):
                        command = "%s %s" % (cmd, arg)
                        with self.subTest(shell=shell, command=command):
                            self.assertCommandDenied(shell, command)
        # Критерий п.13 — «на чтение и правку»; базовый .env на чтение закрыт давно,
        # на правку — вместе с вариантами.
        for name in (".env",) + ENV_VARIANTS:
            for path in both_forms(name) + both_forms("deploy/" + name):
                with self.subTest(tool="Edit", path=path):
                    self.assertPathDenied("Edit", path)

    def test_env_example_open(self):
        for path in both_forms(".env.example"):
            for tool in FILE_TOOLS:
                with self.subTest(tool=tool, path=path):
                    self.assertPathOpen(tool, path)
        for shell in SHELLS:
            for cmd in READ_COMMANDS:
                command = "%s .env.example" % cmd
                with self.subTest(shell=shell, command=command):
                    self.assertCommandOpen(shell, command)

    def test_local_config_denied(self):
        for rel in LOCAL_CONFIG:
            for path in both_forms(rel):
                for tool in FILE_TOOLS:
                    with self.subTest(tool=tool, path=path):
                        self.assertPathDenied(tool, path)
            name = os.path.basename(rel)
            for shell in SHELLS:
                for cmd in READ_COMMANDS:
                    for arg in (name, "./" + name, rel, "/home/user/src/home-agent/" + rel):
                        command = "%s %s" % (cmd, arg)
                        with self.subTest(shell=shell, command=command):
                            self.assertCommandDenied(shell, command)

    def test_tracked_config_open(self):
        for rel in TRACKED_CONFIG:
            for path in both_forms(rel):
                for tool in FILE_TOOLS:
                    with self.subTest(tool=tool, path=path):
                        self.assertPathOpen(tool, path)
        for shell in SHELLS:
            for cmd in READ_COMMANDS:
                for rel in TRACKED_CONFIG:
                    command = "%s %s" % (cmd, rel)
                    with self.subTest(shell=shell, command=command):
                        self.assertCommandOpen(shell, command)


class MatcherModel(unittest.TestCase):
    """Модель сопоставления сама проверяется на известных ответах — иначе зелёный тест выше
    мог бы означать сломанную модель, а не верные правила."""

    def test_command_pattern_is_anchored(self):
        self.assertTrue(command_regex("dotnet*database update*").fullmatch("dotnet-ef database update"))
        self.assertFalse(command_regex("dotnet*database update*").fullmatch("git commit -m dotnet database update"))
        self.assertFalse(command_regex("cat *.env").fullmatch("cat .env.example"))

    def test_path_pattern_depth(self):
        self.assertTrue(path_regex("**/.env").fullmatch(".env"))
        self.assertTrue(path_regex("**/.env").fullmatch("a/b/.env"))
        self.assertFalse(path_regex("**/.env").fullmatch(".env.example"))
        self.assertTrue(path_regex("**/Microsoft/UserSecrets/**").fullmatch("x/Microsoft/UserSecrets/id/secrets.json"))
        self.assertTrue(path_regex("/**/.env").fullmatch("/home/u/.env"))


if __name__ == "__main__":
    unittest.main()
