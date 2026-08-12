# Hermes cron scripts

このdirectoryは、Hermes-Agent container内の`/opt/data/scripts`へbind mountする。

Hermesのscript-only cronは、script pathを`/opt/data/scripts`配下へ制限する。現時点のCouchDB to LLMwiki pipelineはagent cronで実行するため、このdirectoryにはscriptを置かない。将来、LLM不要のwatchdogや通知処理を追加する場合だけ、`.sh`または`.py`をここへ追加する。
