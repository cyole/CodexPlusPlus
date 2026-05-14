import json
import sqlite3

from codex_session_delete.provider_sync import ProviderSyncStatus, run_provider_sync


def write_rollout(path, provider="openai", thread_id="thread-1", cwd="C:/old"):
    path.parent.mkdir(parents=True, exist_ok=True)
    first = {
        "type": "session_meta",
        "payload": {
            "id": thread_id,
            "model_provider": provider,
            "cwd": cwd,
        },
    }
    path.write_text(json.dumps(first) + "\n" + json.dumps({"type": "event_msg", "payload": {"type": "user_message"}}) + "\n", encoding="utf-8")


def create_state_db(path):
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT, archived INTEGER, has_user_event INTEGER, cwd TEXT)")
    con.execute("INSERT INTO threads VALUES ('thread-1', 'old-provider', 0, 0, 'C:/old')")
    con.commit()
    con.close()


def test_provider_sync_updates_rollout_and_sqlite_to_current_provider(tmp_path):
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text('model_provider = "apigather"\n', encoding="utf-8")
    rollout = codex_home / "sessions" / "2026" / "rollout-abc.jsonl"
    write_rollout(rollout, provider="openai", thread_id="thread-1", cwd="C:/workspace")
    create_state_db(codex_home / "state_5.sqlite")

    result = run_provider_sync(codex_home)

    assert result.status == ProviderSyncStatus.SYNCED
    first = json.loads(rollout.read_text(encoding="utf-8").splitlines()[0])
    assert first["payload"]["model_provider"] == "apigather"
    con = sqlite3.connect(codex_home / "state_5.sqlite")
    row = con.execute("SELECT model_provider, has_user_event, cwd FROM threads WHERE id = 'thread-1'").fetchone()
    con.close()
    assert row == ("apigather", 1, "C:/workspace")
    assert result.changed_session_files == 1
    assert result.sqlite_rows_updated == 1
    assert result.backup_dir is not None
    assert (result.backup_dir / "session-meta-backup.json").exists()


def test_provider_sync_repairs_sqlite_visibility_when_rollout_provider_already_matches(tmp_path):
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text('model_provider = "apigather"\n', encoding="utf-8")
    write_rollout(codex_home / "sessions" / "rollout-current.jsonl", provider="apigather", thread_id="thread-1", cwd="C:/workspace")
    create_state_db(codex_home / "state_5.sqlite")

    result = run_provider_sync(codex_home)

    assert result.status == ProviderSyncStatus.SYNCED
    con = sqlite3.connect(codex_home / "state_5.sqlite")
    row = con.execute("SELECT model_provider, has_user_event, cwd FROM threads WHERE id = 'thread-1'").fetchone()
    con.close()
    assert row == ("apigather", 1, "C:/workspace")
    assert result.changed_session_files == 0
    assert result.sqlite_rows_updated == 1


def test_provider_sync_normalizes_sqlite_cwd_to_desktop_path(tmp_path):
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text('model_provider = "apigather"\n', encoding="utf-8")
    write_rollout(codex_home / "sessions" / "rollout-current.jsonl", provider="apigather", thread_id="thread-1", cwd="\\\\?\\C:\\workspace")
    create_state_db(codex_home / "state_5.sqlite")

    result = run_provider_sync(codex_home)

    assert result.status == ProviderSyncStatus.SYNCED
    con = sqlite3.connect(codex_home / "state_5.sqlite")
    row = con.execute("SELECT cwd FROM threads WHERE id = 'thread-1'").fetchone()
    con.close()
    assert row == ("C:/workspace",)


def test_provider_sync_normalizes_existing_global_state_roots(tmp_path):
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text('model_provider = "apigather"\n', encoding="utf-8")
    (codex_home / ".codex-global-state.json").write_text(
        json.dumps(
            {
                "electron-saved-workspace-roots": ["\\\\?\\C:\\workspace"],
                "project-order": ["\\\\?\\C:\\workspace"],
                "active-workspace-roots": ["\\\\?\\C:\\workspace"],
                "electron-workspace-root-labels": {"\\\\?\\C:\\workspace": "Workspace"},
            }
        ),
        encoding="utf-8",
    )
    write_rollout(codex_home / "sessions" / "rollout-current.jsonl", provider="apigather", thread_id="thread-1", cwd="C:/workspace")
    create_state_db(codex_home / "state_5.sqlite")

    result = run_provider_sync(codex_home)

    assert result.status == ProviderSyncStatus.SYNCED
    state = json.loads((codex_home / ".codex-global-state.json").read_text(encoding="utf-8"))
    assert state["electron-saved-workspace-roots"] == ["C:/workspace"]
    assert state["project-order"] == ["C:/workspace"]
    assert state["active-workspace-roots"] == ["C:/workspace"]
    assert state["electron-workspace-root-labels"] == {"C:/workspace": "Workspace"}


def test_provider_sync_does_not_create_workspace_roots_from_historical_thread_cwds(tmp_path):
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text('model_provider = "apigather"\n', encoding="utf-8")
    (codex_home / ".codex-global-state.json").write_text(
        json.dumps(
            {
                "electron-saved-workspace-roots": [],
                "project-order": [],
                "active-workspace-roots": [],
            }
        ),
        encoding="utf-8",
    )
    write_rollout(
        codex_home / "sessions" / "rollout-current.jsonl",
        provider="apigather",
        thread_id="thread-1",
        cwd="C:/Users/shallfun/.codex/plugins/example-plugin",
    )
    create_state_db(codex_home / "state_5.sqlite")

    result = run_provider_sync(codex_home)

    assert result.status == ProviderSyncStatus.SYNCED
    state = json.loads((codex_home / ".codex-global-state.json").read_text(encoding="utf-8"))
    assert state["electron-saved-workspace-roots"] == []
    assert state["project-order"] == []
    assert state["active-workspace-roots"] == []


def test_provider_sync_does_not_reintroduce_removed_roots_from_other_lists(tmp_path):
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text('model_provider = "apigather"\n', encoding="utf-8")
    (codex_home / ".codex-global-state.json").write_text(
        json.dumps(
            {
                "electron-saved-workspace-roots": [],
                "project-order": ["\\\\?\\C:\\ghost-plugin"],
                "active-workspace-roots": ["\\\\?\\C:\\ghost-plugin"],
            }
        ),
        encoding="utf-8",
    )
    write_rollout(codex_home / "sessions" / "rollout-current.jsonl", provider="apigather", thread_id="thread-1", cwd="C:/workspace")
    create_state_db(codex_home / "state_5.sqlite")

    result = run_provider_sync(codex_home)

    assert result.status == ProviderSyncStatus.SYNCED
    state = json.loads((codex_home / ".codex-global-state.json").read_text(encoding="utf-8"))
    assert state["electron-saved-workspace-roots"] == []
    assert state["project-order"] == ["C:/ghost-plugin"]
    assert state["active-workspace-roots"] == ["C:/ghost-plugin"]


def test_provider_sync_normalizes_scalar_active_workspace_root(tmp_path):
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text('model_provider = "apigather"\n', encoding="utf-8")
    (codex_home / ".codex-global-state.json").write_text(
        json.dumps(
            {
                "active-workspace-roots": "\\\\?\\C:\\workspace",
            }
        ),
        encoding="utf-8",
    )
    write_rollout(codex_home / "sessions" / "rollout-current.jsonl", provider="apigather", thread_id="thread-1", cwd="C:/workspace")
    create_state_db(codex_home / "state_5.sqlite")

    result = run_provider_sync(codex_home)

    assert result.status == ProviderSyncStatus.SYNCED
    state = json.loads((codex_home / ".codex-global-state.json").read_text(encoding="utf-8"))
    assert state["active-workspace-roots"] == "C:/workspace"


def test_provider_sync_skips_when_lock_exists(tmp_path):
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    (codex_home / "tmp" / "provider-sync.lock").mkdir(parents=True)
    (codex_home / "config.toml").write_text('model_provider = "apigather"\n', encoding="utf-8")

    result = run_provider_sync(codex_home)

    assert result.status == ProviderSyncStatus.SKIPPED
    assert "lock" in result.message.lower()


def test_provider_sync_prunes_backups_to_five(tmp_path):
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text('model_provider = "apigather"\n', encoding="utf-8")
    backup_root = codex_home / "backups_state" / "provider-sync"
    for index in range(6):
        backup = backup_root / f"2000010100000{index}"
        backup.mkdir(parents=True)
        (backup / "metadata.json").write_text(json.dumps({"managedBy": "Codex++ provider sync"}), encoding="utf-8")
    write_rollout(codex_home / "sessions" / "rollout-new.jsonl", provider="openai")

    result = run_provider_sync(codex_home)

    assert result.status == ProviderSyncStatus.SYNCED
    backups = [path for path in backup_root.iterdir() if path.is_dir()]
    assert len(backups) == 5
