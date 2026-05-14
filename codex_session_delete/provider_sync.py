from __future__ import annotations

import json
import os
import shutil
import sqlite3
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

DEFAULT_PROVIDER = "openai"
BACKUP_KEEP_COUNT = 5
SESSION_DIRS = ("sessions", "archived_sessions")


class ProviderSyncStatus(str, Enum):
    DISABLED = "disabled"
    SKIPPED = "skipped"
    SYNCED = "synced"


@dataclass(frozen=True)
class ProviderSyncResult:
    status: ProviderSyncStatus
    message: str
    target_provider: str = DEFAULT_PROVIDER
    backup_dir: Path | None = None
    changed_session_files: int = 0
    sqlite_rows_updated: int = 0


@dataclass(frozen=True)
class SessionChange:
    path: Path
    original_first_line: str
    next_first_line: str
    separator: str
    thread_id: str | None
    cwd: str | None
    has_user_event: bool
    rewrite_needed: bool


def default_codex_home() -> Path:
    return Path.home() / ".codex"


def run_provider_sync(codex_home: Path | None = None) -> ProviderSyncResult:
    home = codex_home or default_codex_home()
    if not home.exists():
        return ProviderSyncResult(ProviderSyncStatus.SKIPPED, f"Codex home not found: {home}")
    target_provider = read_current_provider(home / "config.toml")
    lock_dir = home / "tmp" / "provider-sync.lock"
    try:
        acquire_lock(lock_dir)
    except FileExistsError:
        return ProviderSyncResult(ProviderSyncStatus.SKIPPED, f"Provider sync lock exists: {lock_dir}", target_provider)
    try:
        changes = collect_session_changes(home, target_provider)
        rewrite_changes = [change for change in changes if change.rewrite_needed]
        thread_ids_with_user_events = {change.thread_id for change in changes if change.thread_id and change.has_user_event}
        cwd_by_thread_id = {change.thread_id: change.cwd for change in changes if change.thread_id and change.cwd}
        sqlite_update_count = count_sqlite_updates(home / "state_5.sqlite", target_provider, thread_ids_with_user_events, cwd_by_thread_id)
        global_state_update_count = count_global_state_updates(home / ".codex-global-state.json")
        if not rewrite_changes and sqlite_update_count == 0 and global_state_update_count == 0:
            return ProviderSyncResult(ProviderSyncStatus.SYNCED, "Provider sync already up to date", target_provider)
        backup_dir = create_backup(home, target_provider, rewrite_changes)
        try:
            apply_session_changes(rewrite_changes)
            sqlite_rows_updated = apply_sqlite_update(home / "state_5.sqlite", target_provider, thread_ids_with_user_events, cwd_by_thread_id)
            apply_global_state_update(home / ".codex-global-state.json")
            prune_backups(home)
        except Exception:
            restore_session_changes(rewrite_changes)
            raise
        return ProviderSyncResult(
            ProviderSyncStatus.SYNCED,
            "Provider sync complete",
            target_provider,
            backup_dir,
            len(rewrite_changes),
            sqlite_rows_updated,
        )
    except (sqlite3.OperationalError, OSError) as exc:
        return ProviderSyncResult(ProviderSyncStatus.SKIPPED, f"Provider sync skipped: {exc}", target_provider)
    finally:
        release_lock(lock_dir)


def read_current_provider(config_path: Path) -> str:
    try:
        lines = config_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return DEFAULT_PROVIDER
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("model_provider") and "=" in stripped:
            raw = stripped.split("=", 1)[1].strip()
            if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
                return raw[1:-1] or DEFAULT_PROVIDER
    return DEFAULT_PROVIDER


def acquire_lock(lock_dir: Path) -> None:
    lock_dir.parent.mkdir(parents=True, exist_ok=True)
    lock_dir.mkdir()
    (lock_dir / "owner.json").write_text(json.dumps({"pid": os.getpid(), "startedAt": time.time()}), encoding="utf-8")


def release_lock(lock_dir: Path) -> None:
    shutil.rmtree(lock_dir, ignore_errors=True)


def rollout_files(home: Path) -> list[Path]:
    files: list[Path] = []
    for dirname in SESSION_DIRS:
        root = home / dirname
        if root.exists():
            files.extend(sorted(path for path in root.rglob("rollout-*.jsonl") if path.is_file()))
    return files


def split_first_line(text: str) -> tuple[str, str]:
    if "\n" not in text:
        return text, ""
    first, rest = text.split("\n", 1)
    return first, "\n" + rest


def to_desktop_workspace_path(value: str | None) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    if not stripped:
        return None
    if stripped.lower().startswith("\\\\?\\unc\\"):
        return "\\\\" + stripped[8:].replace("/", "\\")
    if stripped.startswith("\\\\?\\"):
        return stripped[4:].replace("\\", "/")
    return stripped


def collect_session_changes(home: Path, target_provider: str) -> list[SessionChange]:
    changes: list[SessionChange] = []
    for path in rollout_files(home):
        text = path.read_text(encoding="utf-8")
        first_line, separator = split_first_line(text)
        if not first_line.strip():
            continue
        try:
            record = json.loads(first_line)
        except json.JSONDecodeError:
            continue
        payload = record.get("payload") if isinstance(record, dict) else None
        if not isinstance(payload, dict):
            continue
        thread_id = payload.get("id") if isinstance(payload.get("id"), str) else None
        cwd = to_desktop_workspace_path(payload.get("cwd") if isinstance(payload.get("cwd"), str) else None)
        has_user_event = '"user_message"' in separator or '"user_input"' in separator
        rewrite_needed = payload.get("model_provider") != target_provider
        if rewrite_needed:
            payload["model_provider"] = target_provider
        next_first_line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) if rewrite_needed else first_line
        changes.append(SessionChange(path, first_line, next_first_line, separator, thread_id, cwd, has_user_event, rewrite_needed))
    return changes


def create_backup(home: Path, target_provider: str, changes: list[SessionChange]) -> Path:
    backup_root = home / "backups_state" / "provider-sync"
    backup_dir = backup_root / time.strftime("%Y%m%d%H%M%S")
    suffix = 0
    while backup_dir.exists():
        suffix += 1
        backup_dir = backup_root / f"{time.strftime('%Y%m%d%H%M%S')}-{suffix}"
    backup_dir.mkdir(parents=True)
    for name in ("config.toml", ".codex-global-state.json", ".codex-global-state.json.bak"):
        source = home / name
        if source.exists():
            shutil.copy2(source, backup_dir / name)
    db_dir = backup_dir / "db"
    for name in ("state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"):
        source = home / name
        if source.exists():
            db_dir.mkdir(exist_ok=True)
            shutil.copy2(source, db_dir / name)
    manifest = [
        {"path": str(change.path), "originalFirstLine": change.original_first_line, "separator": change.separator}
        for change in changes
    ]
    (backup_dir / "session-meta-backup.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (backup_dir / "metadata.json").write_text(
        json.dumps({"managedBy": "Codex++ provider sync", "targetProvider": target_provider}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return backup_dir


def apply_session_changes(changes: list[SessionChange]) -> None:
    for change in changes:
        change.path.write_text(change.next_first_line + change.separator, encoding="utf-8")


def restore_session_changes(changes: list[SessionChange]) -> None:
    for change in changes:
        change.path.write_text(change.original_first_line + change.separator, encoding="utf-8")


def table_columns(con: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in con.execute(f'PRAGMA table_info("{table}")')}


def count_sqlite_updates(db_path: Path, target_provider: str, user_event_thread_ids: set[str | None], cwd_by_thread_id: dict[str | None, str]) -> int:
    if not db_path.exists():
        return 0
    con = sqlite3.connect(db_path)
    try:
        columns = table_columns(con, "threads")
        if "model_provider" not in columns:
            return 0
        total = con.execute("SELECT COUNT(*) FROM threads WHERE COALESCE(model_provider, '') <> ?", (target_provider,)).fetchone()[0]
        if "has_user_event" in columns:
            for thread_id in user_event_thread_ids:
                if thread_id:
                    total += con.execute("SELECT COUNT(*) FROM threads WHERE id = ? AND COALESCE(has_user_event, 0) <> 1", (thread_id,)).fetchone()[0]
        if "cwd" in columns:
            for thread_id, cwd in cwd_by_thread_id.items():
                if thread_id and cwd:
                    total += con.execute("SELECT COUNT(*) FROM threads WHERE id = ? AND COALESCE(cwd, '') <> ?", (thread_id, cwd)).fetchone()[0]
        return int(total)
    finally:
        con.close()


def apply_sqlite_update(db_path: Path, target_provider: str, user_event_thread_ids: set[str | None], cwd_by_thread_id: dict[str | None, str]) -> int:
    if not db_path.exists():
        return 0
    con = sqlite3.connect(db_path)
    try:
        columns = table_columns(con, "threads")
        if "model_provider" not in columns:
            return 0
        provider_rows = con.execute("UPDATE threads SET model_provider = ? WHERE COALESCE(model_provider, '') <> ?", (target_provider, target_provider)).rowcount
        if "has_user_event" in columns:
            for thread_id in user_event_thread_ids:
                if thread_id:
                    con.execute("UPDATE threads SET has_user_event = 1 WHERE id = ? AND COALESCE(has_user_event, 0) <> 1", (thread_id,))
        if "cwd" in columns:
            for thread_id, cwd in cwd_by_thread_id.items():
                if thread_id and cwd:
                    con.execute("UPDATE threads SET cwd = ? WHERE id = ? AND COALESCE(cwd, '') <> ?", (cwd, thread_id, cwd))
        con.commit()
        return provider_rows
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()


def load_global_state(global_state_path: Path) -> dict[str, object]:
    if not global_state_path.exists():
        return {}
    data = json.loads(global_state_path.read_text(encoding="utf-8"))
    return data if isinstance(data, dict) else {}


def normalize_comparable_path(value: str | None) -> str | None:
    desktop_path = to_desktop_workspace_path(value)
    if not desktop_path:
        return None
    normalized = desktop_path.replace("/", "\\").rstrip("\\")
    if len(normalized) == 2 and normalized[1] == ":":
        normalized += "\\"
    return normalized.lower()


def dedupe_paths(paths: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for path in paths:
        comparable = normalize_comparable_path(path)
        if not comparable or comparable in seen:
            continue
        seen.add(comparable)
        result.append(to_desktop_workspace_path(path) or path)
    return result


def path_array(value: object) -> list[str]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, str) and item.strip()]
    if isinstance(value, str) and value.strip():
        return [value]
    return []


def resolve_global_state_keyed_paths(value: object) -> object:
    if not isinstance(value, dict):
        return value
    result: dict[str, object] = {}
    for key, item in value.items():
        resolved = to_desktop_workspace_path(key) if isinstance(key, str) else key
        result[resolved] = item
    return result


def count_array_changes(previous: list[str], next_values: list[str]) -> int:
    compared = max(len(previous), len(next_values))
    return sum(1 for index in range(compared) if (previous[index] if index < len(previous) else None) != (next_values[index] if index < len(next_values) else None))


def normalize_active_workspace_roots(value: object) -> object:
    if isinstance(value, list):
        return dedupe_paths(value)
    normalized = dedupe_paths(path_array(value))
    return normalized[0] if normalized else value


def normalized_global_state(state: dict[str, object]) -> dict[str, object]:
    next_state: dict[str, object] = {}
    if "electron-saved-workspace-roots" in state:
        next_state["electron-saved-workspace-roots"] = dedupe_paths(path_array(state.get("electron-saved-workspace-roots")))
    if "project-order" in state:
        next_state["project-order"] = dedupe_paths(path_array(state.get("project-order")))
    if "active-workspace-roots" in state:
        next_state["active-workspace-roots"] = normalize_active_workspace_roots(state.get("active-workspace-roots"))
    if "electron-workspace-root-labels" in state:
        next_state["electron-workspace-root-labels"] = resolve_global_state_keyed_paths(state.get("electron-workspace-root-labels"))
    return next_state


def count_global_state_changes(state: dict[str, object], next_state: dict[str, object]) -> int:
    total = 0
    for key in ("electron-saved-workspace-roots", "project-order"):
        if key in next_state:
            total += count_array_changes(path_array(state.get(key)), next_state[key] if isinstance(next_state[key], list) else path_array(next_state[key]))
    if "active-workspace-roots" in next_state:
        original_active_value = state.get("active-workspace-roots")
        next_active_value = next_state["active-workspace-roots"]
        if isinstance(original_active_value, list):
            total += count_array_changes(path_array(original_active_value), next_active_value if isinstance(next_active_value, list) else path_array(next_active_value))
        elif original_active_value != next_active_value:
            total += 1
    if "electron-workspace-root-labels" in next_state:
        total += 1 if next_state["electron-workspace-root-labels"] != state.get("electron-workspace-root-labels") else 0
    return total


def count_global_state_updates(global_state_path: Path) -> int:
    state = load_global_state(global_state_path)
    next_state = normalized_global_state(state)
    return count_global_state_changes(state, next_state)


def apply_global_state_update(global_state_path: Path) -> int:
    state = load_global_state(global_state_path)
    next_state = normalized_global_state(state)
    total = count_global_state_changes(state, next_state)
    for key, value in next_state.items():
        state[key] = value
    if total:
        global_state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    return total


def prune_backups(home: Path, keep_count: int = BACKUP_KEEP_COUNT) -> None:
    backup_root = home / "backups_state" / "provider-sync"
    if not backup_root.exists():
        return
    managed = []
    for path in backup_root.iterdir():
        if not path.is_dir():
            continue
        try:
            metadata = json.loads((path / "metadata.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if metadata.get("managedBy") == "Codex++ provider sync":
            managed.append(path)
    managed.sort(key=lambda path: path.name, reverse=True)
    for path in managed[keep_count:]:
        shutil.rmtree(path, ignore_errors=True)
