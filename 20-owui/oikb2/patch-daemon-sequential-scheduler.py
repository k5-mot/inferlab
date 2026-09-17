from pathlib import Path

import oikb.daemon as daemon_module
import oikb.sync as sync_module


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


def _load_sync_path() -> Path:
    """patch対象のsync.pyをimport結果から解決する。

    Args:
        なし。

    Returns:
        install済みのoikb.sync module file path。

    Raises:
        RuntimeError: module file pathを解決できない場合。
    """
    if sync_module.__file__ is None:
        raise RuntimeError("oikb.sync module path was not found")
    return Path(sync_module.__file__)


def _patch_sync_source(source: str) -> str:
    """dry-run詳細を追加し未登録file発生時に後続uploadを止める。

    Args:
        source: patch前のsync.py source code。

    Returns:
        dry-run結果へfile詳細を保持し逐次uploadをfail-fastにするsource code。

    Raises:
        RuntimeError: 想定したpatch対象が存在しない場合。
    """
    field_before = """    warnings: list[str] | None = None

    @property
"""
    field_after = """    warnings: list[str] | None = None
    files: list[dict[str, str]] | None = None

    @property
"""
    result_before = """        result.dirs_removed = len(rmdir)

        if added:
"""
    result_after = """        result.dirs_removed = len(rmdir)
        result.files = [
            {
                "action": action,
                "path": f"{entry.get('path')}/{entry['filename']}".lstrip("/"),
            }
            for action, entries in (("added", added), ("modified", modified))
            for entry in entries
        ]

        if added:
"""
    upload_targets = (
        (
            """                    _tally(_upload_one(i, entry, change_type, progress, task_id))
""",
            """                    outcome = _upload_one(i, entry, change_type, progress, task_id)
                    _tally(outcome)
                    if outcome[0] not in ("added", "modified"):
                        break
""",
        ),
        (
            """                _tally(_upload_one(i, entry, change_type, None, None))
""",
            """                outcome = _upload_one(i, entry, change_type, None, None)
                _tally(outcome)
                if outcome[0] not in ("added", "modified"):
                    break
""",
        ),
    )
    if field_before not in source:
        raise RuntimeError("oikb.sync result field patch target was not found")
    if result_before not in source:
        raise RuntimeError("oikb.sync dry-run detail patch target was not found")
    source = source.replace(field_before, field_after, 1).replace(
        result_before,
        result_after,
        1,
    )
    for before, after in upload_targets:
        if before not in source:
            raise RuntimeError("oikb.sync sequential upload patch target was not found")
        source = source.replace(before, after, 1)
    return source


def _patch_source(source: str) -> str:
    """daemonのscheduler逐次化、dry-run補強、処理中file表示を追加する。

    Args:
        source: patch前のdaemon.py source code。

    Returns:
        内蔵schedulerがsourceを設定順に処理し、source metadataと
        処理中fileを公開するsource code。

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
    dry_run_before = """        if dry_run:
            return {
                "added": result.added,
                "modified": result.modified,
                "deleted": result.deleted,
                "unmodified": result.unmodified,
                "warnings": result.warnings or [],
                "errors": result.errors or [],
                "summary": result.summary(),
            }
"""
    dry_run_after = """        if dry_run:
            _scheduler_state[source] = {
                **_scheduler_state.get(source, {}),
                "name": entry.get("name", source),
                "kb_id": kb_id,
                "status": "idle",
            }
            return {
                "added": result.added,
                "modified": result.modified,
                "deleted": result.deleted,
                "unmodified": result.unmodified,
                "warnings": result.warnings or [],
                "errors": result.errors or [],
                "files": result.files or [],
                "summary": result.summary(),
            }
"""
    client_before = """        client = _make_client(
            url=entry.get("url"),
            token=entry.get("token"),
        )

        mf = None
"""
    client_after = '''        client = _make_client(
            url=entry.get("url"),
            token=entry.get("token"),
        )
        original_upload_file = client.upload_file

        def upload_file_with_state(
            file_content: bytes,
            filename: str,
            kb_id: str,
            file_hash: str,
            directory_id: str | None = None,
        ) -> dict[str, Any]:
            """処理中file名を公開し、元のupload処理を実行する。

            Args:
                file_content: uploadするfile内容。
                filename: Open WebUIへ登録するfile名。
                kb_id: 登録先Knowledge Base ID。
                file_hash: 差分判定に使うfile hash。
                directory_id: 登録先directory ID。rootの場合はNone。

            Returns:
                元のupload処理が返すOpen WebUI response。

            Side Effects:
                処理中だけscheduler stateへbasenameを設定する。
            """
            current_file = filename.replace("\\\\", "/").rsplit("/", 1)[-1]
            _scheduler_state.setdefault(source, {})["current_file"] = current_file
            try:
                return original_upload_file(
                    file_content,
                    filename,
                    kb_id,
                    file_hash,
                    directory_id,
                )
            finally:
                _scheduler_state.setdefault(source, {}).pop("current_file", None)

        client.upload_file = upload_file_with_state

        mf = None
'''
    dashboard_style_before = """.row{padding:.5rem 0;border-bottom:1px solid #222;display:flex;gap:1rem;align-items:baseline}
"""
    dashboard_style_after = """.source{border-bottom:1px solid #222}
.row{padding:.5rem 0;display:flex;gap:1rem;align-items:baseline}
.current-file{color:#aaa;font-size:12px;margin:0 0 .5rem 28px;overflow-wrap:anywhere}
"""
    dashboard_script_before = """function ago(t){if(!t)return'-';const s=Math.floor(Date.now()/1000-t);if(s<60)return s+'s ago';if(s<3600)return(s/60|0)+'m ago';if(s<86400)return(s/3600|0)+'h ago';return(s/86400|0)+'d ago'}
async function poll(){
"""
    dashboard_script_after = """function ago(t){if(!t)return'-';const s=Math.floor(Date.now()/1000-t);if(s<60)return s+'s ago';if(s<3600)return(s/60|0)+'m ago';if(s<86400)return(s/3600|0)+'h ago';return(s/86400|0)+'d ago'}
/**
 * dashboardへ表示する値をHTMLとして解釈されない文字列へ変換する。
 * @param {*} value 表示する値。
 * @returns {string} HTML特殊文字をescapeした文字列。
 */
function escapeHtml(value){return String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
async function poll(){
"""
    dashboard_row_before = """   const e=s.errors&&s.errors.length?'<div class="error">'+s.errors[0]+'</div>':'';
   return '<div class="row"><span class="dot '+c+'"></span><span class="name">'+(s.name||k)+'</span>'
    +'<span class="dim">'+ago(s.last_sync)+'</span>'
    +'<span class="dim">'+(s.duration_ms?s.duration_ms+'ms':'-')+'</span>'
    +'<span class="dim">+'+( s.files_added||0)+' ~'+(s.files_modified||0)+' -'+(s.files_deleted||0)+'</span>'
    +'<span class="dim">'+(s.next_sync_in||'')+'</span></div>'+e
"""
    dashboard_row_after = """   const e=s.errors&&s.errors.length?'<div class="error">'+s.errors[0]+'</div>':'';
   const f=s.current_file?'<div class="current-file">└ '+escapeHtml(s.current_file)+'</div>':'';
   return '<div class="source"><div class="row"><span class="dot '+c+'"></span><span class="name">'+(s.name||k)+'</span>'
    +'<span class="dim">'+ago(s.last_sync)+'</span>'
    +'<span class="dim">'+(s.duration_ms?s.duration_ms+'ms':'-')+'</span>'
    +'<span class="dim">+'+( s.files_added||0)+' ~'+(s.files_modified||0)+' -'+(s.files_deleted||0)+'</span>'
    +'<span class="dim">'+(s.next_sync_in||'')+'</span></div>'+f+e+'</div>'
"""

    if initialization_before not in source:
        raise RuntimeError("oikb.daemon initialization patch target was not found")
    if scheduler_before not in source:
        raise RuntimeError("oikb.daemon sequential scheduler patch target was not found")
    if dry_run_before not in source:
        raise RuntimeError("oikb.daemon dry-run patch target was not found")
    if client_before not in source:
        raise RuntimeError("oikb.daemon client patch target was not found")
    if dashboard_style_before not in source:
        raise RuntimeError("oikb.daemon dashboard style patch target was not found")
    if dashboard_script_before not in source:
        raise RuntimeError("oikb.daemon dashboard script patch target was not found")
    if dashboard_row_before not in source:
        raise RuntimeError("oikb.daemon dashboard row patch target was not found")

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

    return (
        source.replace(
            initialization_before,
            initialization_after,
        )
        .replace(scheduler_before, scheduler_after, 1)
        .replace(
            dry_run_before,
            dry_run_after,
            1,
        )
        .replace(client_before, client_after, 1)
        .replace(dashboard_style_before, dashboard_style_after, 1)
        .replace(dashboard_script_before, dashboard_script_after, 1)
        .replace(dashboard_row_before, dashboard_row_after, 1)
    )


path = _load_daemon_path()
path.write_text(_patch_source(path.read_text()))
sync_path = _load_sync_path()
sync_path.write_text(_patch_sync_source(sync_path.read_text()))
