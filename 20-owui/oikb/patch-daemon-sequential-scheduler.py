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
    """daemon内蔵schedulerがsourceを設定順に処理するよう変更する。

    Args:
        source: patch前のdaemon.py source code。

    Returns:
        内蔵schedulerがsourceを設定順に処理し、source metadataを
        公開するsource code。

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
    scheduler_before = '''async def _run_scheduler(entries: list[dict], handle_signals: bool = False) -> None:
    """Start all sync tasks and wait for shutdown."""
    global _shutdown_event
    _shutdown_event = asyncio.Event()

    if handle_signals:
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, _request_shutdown)

    tasks = [asyncio.create_task(_schedule_entry(e)) for e in entries]

    await _shutdown_event.wait()
    await asyncio.gather(*tasks, return_exceptions=True)
'''
    scheduler_after = '''async def _run_scheduler(entries: list[dict], handle_signals: bool = False) -> None:
    """OIKB sourceを設定順に1周期ずつ同期する。

    Args:
        entries: 設定順のOIKB source。
        handle_signals: SIGINTとSIGTERMをscheduler内で処理するか。

    Returns:
        なし。scheduler停止まで待機する。

    Raises:
        ValueError: sourceごとの同期間隔が一致しない場合。

    Side Effects:
        sourceを1件ずつ同期し、先行sourceの失敗時は後続sourceを開始しない。
    """
    global _shutdown_event
    _shutdown_event = asyncio.Event()

    if handle_signals:
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, _request_shutdown)

    configured_intervals = {
        str(entry.get("interval", "30m"))
        for entry in entries
    }
    if len(configured_intervals) > 1:
        raise ValueError("Sequential scheduler requires one shared interval")
    raw_interval = next(iter(configured_intervals), "30m")
    use_cron = _is_cron(raw_interval)
    interval = None if use_cron else parse_interval(raw_interval)

    while not _shutdown_event.is_set():
        for entry in entries:
            if _shutdown_event.is_set():
                break
            await _run_entry(entry)
            source = entry.get("source", "unknown")
            status = _scheduler_state.get(source, {}).get("status")
            if status != "success":
                log.error(
                    f"Stopping sequential sync cycle after {source}: {status}"
                )
                break

        if use_cron:
            delay = _next_cron_delay(raw_interval)
        else:
            delay = float(interval)
        for entry in entries:
            source = entry.get("source", "unknown")
            _scheduler_state.setdefault(source, {})["next_sync_in"] = (
                f"{int(delay)}s"
            )

        try:
            await asyncio.wait_for(_shutdown_event.wait(), timeout=delay)
            break
        except asyncio.TimeoutError:
            pass
'''
    state_before = """        _scheduler_state[source] = {
            "name": entry.get("name", source),
            "status": {status},
"""

    if initialization_before not in source:
        raise RuntimeError("oikb.daemon initialization patch target was not found")
    if scheduler_before not in source:
        raise RuntimeError("oikb.daemon sequential scheduler patch target was not found")

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
    ).replace(scheduler_before, scheduler_after, 1)


path = _load_daemon_path()
path.write_text(_patch_source(path.read_text()))
