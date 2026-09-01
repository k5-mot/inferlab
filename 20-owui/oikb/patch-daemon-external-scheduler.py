from pathlib import Path

import oikb.daemon as daemon_module


def _load_daemon_path() -> Path:
    """patch対象のdaemon.pyをimport結果から解決する。

    Args:
        なし。

    Returns:
        install済みのoikb.daemon module file path。

    Raises:
        RuntimeError: module file pathを解決できない場合。
    """
    if daemon_module.__file__ is None:
        raise RuntimeError("oikb.daemon module path was not found")
    return Path(daemon_module.__file__)


def _patch_source(source: str) -> str:
    """daemonを外部scheduler専用APIとして動作させる。

    Args:
        source: patch前のdaemon.py source code。

    Returns:
        内蔵schedulerを停止しsource metadataを公開するsource code。

    Raises:
        RuntimeError: 想定したpatch対象が存在しない場合。
    """
    initialization_before = """    global _history, _entries

    from oikb.logging import configure_logging
    configure_logging(log_format=log_format)

    _entries = entries
    _history = SyncHistory()
"""
    initialization_after = """    global _history, _entries, _scheduler_state

    from oikb.logging import configure_logging
    configure_logging(log_format=log_format)

    _entries = entries
    _scheduler_state = {
        entry["source"]: {
            "name": entry.get("name", entry["source"]),
            "kb_id": entry["kb-id"],
            "status": "idle",
        }
        for entry in entries
    }
    _history = SyncHistory()
"""
    startup_before = """        @app.on_event("startup")
        async def _startup():
            app.state.scheduler_task = asyncio.create_task(_run_scheduler(entries))
"""
    startup_after = """        @app.on_event("startup")
        async def _startup():
            app.state.scheduler_task = None
"""
    state_before = """        _scheduler_state[source] = {
            "name": entry.get("name", source),
            "status": {status},
"""

    if initialization_before not in source:
        raise RuntimeError("oikb.daemon initialization patch target was not found")
    if startup_before not in source:
        raise RuntimeError("oikb.daemon scheduler patch target was not found")

    for status in ("status", '"cancelled"', '"error"'):
        target = state_before.replace("{status}", status)
        if target not in source:
            raise RuntimeError(f"oikb.daemon {status} state patch target was not found")
        source = source.replace(
            target,
            target.replace(
                '            "status":',
                '            "kb_id": kb_id,\n            "status":',
            ),
            1,
        )

    return source.replace(
        initialization_before,
        initialization_after,
    ).replace(startup_before, startup_after)


path = _load_daemon_path()
path.write_text(_patch_source(path.read_text()))
