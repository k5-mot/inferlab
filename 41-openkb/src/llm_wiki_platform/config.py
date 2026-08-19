"""config.yamlの読込、型検証、環境変数参照の検証を提供する。"""

from __future__ import annotations

import os
import re
from collections.abc import Mapping
from datetime import timedelta
from pathlib import Path
from typing import Annotated, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import yaml
from apscheduler.triggers.cron import CronTrigger
from pydantic import (
    AnyHttpUrl,
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    ValidationError,
    field_validator,
    model_validator,
)

SUPPORTED_SOURCES = frozenset({"gitlab", "zulip", "nextcloud", "kaneo"})
_DURATION_PATTERN = re.compile(r"^(?P<value>[1-9][0-9]*)(?P<unit>s|m|h|d)$")


class ConfigLoadError(RuntimeError):
    """設定ファイルが不正な場合に発生する例外。"""


def parse_duration(value: object) -> timedelta:
    """短いduration表記をtimedeltaへ変換する。

    Args:
        value: `30s`、`10m`、`2h`、`1d`のいずれか、またはtimedelta。

    Returns:
        変換後のtimedelta。

    Raises:
        ValueError: 対応していないduration表記が渡された場合。
    """
    if isinstance(value, timedelta):
        return value
    if not isinstance(value, str):
        raise ValueError("durationは文字列で指定してください")
    match = _DURATION_PATTERN.fullmatch(value)
    if match is None:
        raise ValueError("durationは正の整数とs/m/h/dの組合せで指定してください")
    amount = int(match.group("value"))
    unit = match.group("unit")
    multipliers = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    return timedelta(seconds=amount * multipliers[unit])


Duration = Annotated[timedelta, BeforeValidator(parse_duration)]


class StrictModel(BaseModel):
    """未知の設定項目を拒否する設定モデルの基底。"""

    model_config = ConfigDict(extra="forbid", frozen=True)


class SchedulerConfig(StrictModel):
    """スケジューラ共通設定。"""

    timezone: str

    @field_validator("timezone")
    @classmethod
    def validate_timezone(cls, value: str) -> str:
        """IANA timezoneが解決可能か検証する。

        Args:
            value: IANA timezone名。

        Returns:
            検証済みtimezone名。

        Raises:
            ValueError: timezoneが存在しない場合。
        """
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError as error:
            raise ValueError(f"未知のtimezoneです: {value}") from error
        return value


class RetryConfig(StrictModel):
    """外部API呼出しのretry既定値。"""

    max_attempts: int = Field(ge=1)
    backoff: Literal["constant", "exponential"]
    initial_delay: Duration
    max_delay: Duration

    @model_validator(mode="after")
    def validate_delays(self) -> RetryConfig:
        """retry delayの大小関係を検証する。

        Returns:
            検証済み設定自身。

        Raises:
            ValueError: initial delayがmax delayを超える場合。
        """
        if self.initial_delay > self.max_delay:
            raise ValueError("initial_delayはmax_delay以下である必要があります")
        return self


class RetryOverride(StrictModel):
    """source単位で上書きするretry設定。"""

    max_attempts: int | None = Field(default=None, ge=1)
    backoff: Literal["constant", "exponential"] | None = None
    initial_delay: Duration | None = None
    max_delay: Duration | None = None


class RateLimitConfig(StrictModel):
    """1分当たりの外部API request上限。"""

    requests_per_minute: int = Field(ge=1)


class RateLimitOverride(StrictModel):
    """source単位で上書きするrate limit設定。"""

    requests_per_minute: int | None = Field(default=None, ge=1)


class DefaultIngestConfig(StrictModel):
    """すべてのsourceへ適用するingest既定値。"""

    retry: RetryConfig
    rate_limit: RateLimitConfig


class DefaultsConfig(StrictModel):
    """source共通の既定値。"""

    ingest: DefaultIngestConfig


class SourceIngestConfig(StrictModel):
    """source単位のscheduleとoverride。"""

    schedule: str
    retry: RetryOverride | None = None
    rate_limit: RateLimitOverride | None = None

    @field_validator("schedule")
    @classmethod
    def validate_schedule(cls, value: str) -> str:
        """5-field cron式を検証する。

        Args:
            value: cron式。

        Returns:
            検証済みcron式。

        Raises:
            ValueError: cron式が不正な場合。
        """
        try:
            CronTrigger.from_crontab(value)
        except ValueError as error:
            raise ValueError(f"不正なcron式です: {value}") from error
        return value


class CredentialRefs(StrictModel):
    """credential本体を保持する環境変数名の集合。"""

    token_env: str | None = None
    email_env: str | None = None
    api_key_env: str | None = None
    username_env: str | None = None
    password_env: str | None = None
    token_id_env: str | None = None
    token_secret_env: str | None = None

    def environment_names(self) -> tuple[str, ...]:
        """設定された環境変数名を列挙する。

        Returns:
            空値を除外した環境変数名。
        """
        values = self.model_dump().values()
        return tuple(value for value in values if isinstance(value, str))


class SourceConfig(StrictModel):
    """GitLab、Zulip、Nextcloud、Kaneoに共通する設定。"""

    enabled: bool
    base_url: AnyHttpUrl
    credential: CredentialRefs
    ingest: SourceIngestConfig
    include: dict[str, list[str]] = Field(default_factory=dict)
    exclude: dict[str, list[str]] = Field(default_factory=dict)


class StorageConfig(StrictModel):
    """Source Storeと状態DBの保存先。"""

    source_store_path: Path
    state_database_path: Path


class OpenKBCredential(StrictModel):
    """OpenKB bearer tokenの参照。"""

    token_env: str | None = None


class OpenKBLLMConfig(StrictModel):
    """OpenKB knowledge base初期化時のLLM接続設定。"""

    model: str = Field(min_length=1)
    api_key_env: str = Field(min_length=1)
    openai_api_base: AnyHttpUrl


class OpenKBConfig(StrictModel):
    """OpenKB REST APIと生成Wikiの設定。"""

    base_url: AnyHttpUrl
    knowledge_base: str = Field(min_length=1)
    generated_wiki_path: Path
    credential: OpenKBCredential = Field(default_factory=OpenKBCredential)
    llm: OpenKBLLMConfig


class WikiBoundaryConfig(StrictModel):
    """BookStack内のWiki境界をshelf名で表す。"""

    shelf: str = Field(min_length=1)


class LLMWikiBoundaryConfig(WikiBoundaryConfig):
    """LLM Wiki shelfとGenerated Wiki categoryのbook mapping。"""

    books: dict[str, str] = Field(
        default_factory=lambda: {
            "concepts": "Concepts",
            "entities": "Entities",
            "projects": "Projects",
            "systems": "Systems",
            "decisions": "Decisions",
            "sources": "Sources",
            "summaries": "Summaries",
            "syntheses": "Syntheses",
        }
    )


class BookStackIngestConfig(SourceIngestConfig):
    """BookStack Human Wiki取込の有効状態を含む設定。"""

    enabled: bool


class BookStackConfig(StrictModel):
    """BookStackの読取・公開設定。"""

    base_url: AnyHttpUrl
    human_wiki: WikiBoundaryConfig
    llm_wiki: LLMWikiBoundaryConfig
    ingest: BookStackIngestConfig
    reader_credential: CredentialRefs
    publisher_credential: CredentialRefs

    @model_validator(mode="after")
    def validate_wiki_boundary(self) -> BookStackConfig:
        """Human WikiとLLM Wikiが別shelfか検証する。

        Returns:
            検証済み設定自身。

        Raises:
            ValueError: 同一shelfが指定された場合。
        """
        if self.human_wiki.shelf == self.llm_wiki.shelf:
            raise ValueError("Human WikiとLLM Wikiは別shelfにしてください")
        return self


class CompileTriggerConfig(StrictModel):
    """ingest完了を契機とする将来のcompile条件。"""

    on_ingest_batch_completed: bool = False
    min_changed_documents: int = Field(default=1, ge=1)
    max_delay: Duration = timedelta(hours=2)


class CompileConfig(StrictModel):
    """compileの有効状態とschedule。"""

    enabled: bool
    schedule: str
    trigger: CompileTriggerConfig = Field(default_factory=CompileTriggerConfig)

    @field_validator("schedule")
    @classmethod
    def validate_schedule(cls, value: str) -> str:
        """compile scheduleのcron式を検証する。

        Args:
            value: cron式。

        Returns:
            検証済みcron式。

        Raises:
            ValueError: cron式が不正な場合。
        """
        return SourceIngestConfig.validate_schedule(value)


class PublishConfig(StrictModel):
    """publishの起動条件と削除方針。"""

    enabled: bool
    mode: Literal["after_successful_compile", "manual"]
    require_validation: Literal[False] = False
    dry_run: bool = False
    deletion_policy: Literal["mark_unavailable"] = "mark_unavailable"


class PipelineConfig(StrictModel):
    """compileとpublishのパイプライン設定。"""

    compile: CompileConfig
    publish: PublishConfig


class EffectiveIngestConfig(StrictModel):
    """共通既定値とsource overrideを解決した設定。"""

    schedule: str
    retry: RetryConfig
    rate_limit: RateLimitConfig


class AppConfig(StrictModel):
    """config.yaml全体の設定モデル。"""

    version: Literal[1]
    scheduler: SchedulerConfig
    storage: StorageConfig
    defaults: DefaultsConfig
    sources: dict[str, SourceConfig]
    openkb: OpenKBConfig
    bookstack: BookStackConfig
    pipeline: PipelineConfig

    @field_validator("sources")
    @classmethod
    def validate_source_names(cls, value: dict[str, SourceConfig]) -> dict[str, SourceConfig]:
        """source名が実装済み集合に含まれるか検証する。

        Args:
            value: source名と設定の対応。

        Returns:
            検証済みsource設定。

        Raises:
            ValueError: 未対応sourceが含まれる場合。
        """
        unsupported = sorted(set(value) - SUPPORTED_SOURCES)
        if unsupported:
            raise ValueError(f"未対応sourceです: {', '.join(unsupported)}")
        return value

    @model_validator(mode="after")
    def validate_credential_shapes(self) -> AppConfig:
        """有効機能に必要なcredential参照fieldを検証する。

        Returns:
            検証済み設定自身。

        Raises:
            ValueError: source固有の参照fieldが不足する場合。
        """
        requirements = {
            "gitlab": ("token_env",),
            "zulip": ("email_env", "api_key_env"),
            "nextcloud": ("username_env", "password_env"),
            "kaneo": ("token_env",),
        }
        for source_name, source in self.sources.items():
            if not source.enabled:
                continue
            missing = [
                field_name
                for field_name in requirements[source_name]
                if getattr(source.credential, field_name) is None
            ]
            if missing:
                raise ValueError(
                    f"{source_name} credential参照が不足しています: {', '.join(missing)}"
                )
        if self.bookstack.ingest.enabled:
            _require_fields(
                self.bookstack.reader_credential,
                ("token_id_env", "token_secret_env"),
                "bookstack reader",
            )
        if self.pipeline.publish.enabled:
            _require_fields(
                self.bookstack.publisher_credential,
                ("token_id_env", "token_secret_env"),
                "bookstack publisher",
            )
        return self

    def effective_ingest(self, source_name: str) -> EffectiveIngestConfig:
        """source共通既定値へsource別overrideを適用する。

        Args:
            source_name: `sources`のkey、または`bookstack`。

        Returns:
            解決済みingest設定。

        Raises:
            KeyError: source名が設定に存在しない場合。
            ValueError: 解決後のretry delayが不正な場合。
        """
        source_ingest = (
            self.bookstack.ingest
            if source_name == "bookstack"
            else self.sources[source_name].ingest
        )
        retry_update = _defined_values(source_ingest.retry)
        rate_limit_update = _defined_values(source_ingest.rate_limit)
        retry = self.defaults.ingest.retry.model_copy(update=retry_update)
        retry = RetryConfig.model_validate(retry.model_dump())
        rate_limit = self.defaults.ingest.rate_limit.model_copy(update=rate_limit_update)
        return EffectiveIngestConfig(
            schedule=source_ingest.schedule,
            retry=retry,
            rate_limit=rate_limit,
        )

    def enabled_source_names(self) -> tuple[str, ...]:
        """ingestが有効なsource名を列挙する。

        Returns:
            config順を維持したsource名。
        """
        names = [name for name, source in self.sources.items() if source.enabled]
        if self.bookstack.ingest.enabled:
            names.append("bookstack")
        return tuple(names)


def _defined_values(override: StrictModel | None) -> dict[str, object]:
    """overrideからNoneではないfieldだけを抽出する。

    Args:
        override: source別override。

    Returns:
        model_copyへ渡せる更新値。
    """
    if override is None:
        return {}
    return {key: value for key, value in override.model_dump().items() if value is not None}


def _require_fields(
    refs: CredentialRefs,
    field_names: tuple[str, ...],
    context: str,
) -> None:
    """credential参照の必須fieldが設定済みか検証する。

    Args:
        refs: 検証対象credential参照。
        field_names: 必須field名。
        context: errorへ含める機能名。

    Returns:
        なし。

    Raises:
        ValueError: 必須fieldが不足する場合。
    """
    missing = [field_name for field_name in field_names if getattr(refs, field_name) is None]
    if missing:
        raise ValueError(f"{context} credential参照が不足しています: {', '.join(missing)}")


def load_config(path: Path, environ: Mapping[str, str] | None = None) -> AppConfig:
    """YAML設定を読み、schemaと環境変数参照を検証する。

    Args:
        path: config.yamlのpath。
        environ: credential参照を検証する環境変数。省略時はprocess環境。

    Returns:
        検証済みAppConfig。

    Raises:
        ConfigLoadError: 読込、YAML parse、schema、環境変数参照が不正な場合。
    """
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise ConfigLoadError(f"設定ファイルを読み込めません: {path}: {error}") from error
    if not isinstance(raw, dict):
        raise ConfigLoadError("config.yamlのrootはmappingである必要があります")
    try:
        config = AppConfig.model_validate(raw)
    except ValidationError as error:
        raise ConfigLoadError(f"config.yamlがschemaに適合しません:\n{error}") from error
    validate_environment(config, os.environ if environ is None else environ)
    return config


def validate_environment(config: AppConfig, environ: Mapping[str, str]) -> None:
    """有効機能が参照するcredential環境変数の存在を検証する。

    Args:
        config: 検証済み設定。
        environ: process環境変数。

    Returns:
        なし。

    Raises:
        ConfigLoadError: 必要な環境変数が未設定または空の場合。
    """
    required: set[str] = set()
    for source in config.sources.values():
        if source.enabled:
            required.update(source.credential.environment_names())
    if config.bookstack.ingest.enabled:
        required.update(config.bookstack.reader_credential.environment_names())
    if config.pipeline.publish.enabled:
        required.update(config.bookstack.publisher_credential.environment_names())
    if config.enabled_source_names() or config.pipeline.compile.enabled:
        token_env = config.openkb.credential.token_env
        if token_env:
            required.add(token_env)
    if config.pipeline.compile.enabled:
        required.add(config.openkb.llm.api_key_env)
    missing = sorted(name for name in required if not environ.get(name))
    if missing:
        raise ConfigLoadError(f"credential環境変数が未設定です: {', '.join(missing)}")


def resolve_credential(refs: CredentialRefs, environ: Mapping[str, str]) -> dict[str, str]:
    """環境変数参照を実際のcredential値へ解決する。

    Args:
        refs: credential環境変数名の集合。
        environ: 値を取得する環境変数。

    Returns:
        `_env`を除いたfield名とcredential値の対応。

    Raises:
        ConfigLoadError: 参照先が未設定の場合。
    """
    resolved: dict[str, str] = {}
    for field_name, env_name in refs.model_dump().items():
        if env_name is None:
            continue
        value = environ.get(env_name)
        if not value:
            raise ConfigLoadError(f"credential環境変数が未設定です: {env_name}")
        resolved[field_name.removesuffix("_env")] = value
    return resolved
