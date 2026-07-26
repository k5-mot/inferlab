#!/usr/bin/env python3
"""Grafanaのサービス別dashboard JSONを生成する。"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent / "dashboards" / "services"
DATASOURCE = "Prometheus"


def target(expr: str, ref_id: str, legend: str = "") -> dict[str, Any]:
    """Prometheus query targetを作成する。

    Args:
        expr: PromQL式。
        ref_id: Grafana panel内で使うquery ID。
        legend: 時系列表示で使うlegend文字列。

    Returns:
        Grafana dashboard JSON内のtarget定義。
    """
    result: dict[str, Any] = {
        "datasource": DATASOURCE,
        "editorMode": "code",
        "expr": expr,
        "range": True,
        "refId": ref_id,
    }
    if legend:
        result["legendFormat"] = legend
    return result


def grid(panel_id: int) -> dict[str, int]:
    """panel IDから固定grid位置を計算する。

    Args:
        panel_id: 1始まりのpanel ID。

    Returns:
        Grafana dashboard JSONのgridPos定義。
    """
    index = panel_id - 1
    row = index // 3
    col = index % 3
    return {"h": 8, "w": 8, "x": col * 8, "y": row * 8}


def stat_panel(panel_id: int, title: str, expr: str, unit: str = "short") -> dict[str, Any]:
    """stat panelを作成する。

    Args:
        panel_id: Grafana panel ID。
        title: panel title。
        expr: PromQL式。
        unit: Grafana field unit。

    Returns:
        Grafana dashboard JSONのstat panel定義。
    """
    return {
        "datasource": DATASOURCE,
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "thresholds"},
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": "red", "value": None},
                        {"color": "green", "value": 1},
                    ],
                },
                "unit": unit,
            },
            "overrides": [],
        },
        "gridPos": grid(panel_id),
        "id": panel_id,
        "options": {
            "colorMode": "background",
            "graphMode": "area",
            "justifyMode": "center",
            "orientation": "auto",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "textMode": "auto",
            "wideLayout": True,
        },
        "pluginVersion": "13.1.1",
        "targets": [target(expr, "A")],
        "title": title,
        "type": "stat",
    }


def timeseries_panel(panel_id: int, title: str, queries: list[dict[str, str]], unit: str = "short") -> dict[str, Any]:
    """time series panelを作成する。

    Args:
        panel_id: Grafana panel ID。
        title: panel title。
        queries: `expr`と`legend`を含むquery定義の配列。
        unit: Grafana field unit。

    Returns:
        Grafana dashboard JSONのtime series panel定義。
    """
    return {
        "datasource": DATASOURCE,
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "palette-classic"},
                "custom": {
                    "axisBorderShow": False,
                    "axisCenteredZero": False,
                    "axisColorMode": "text",
                    "axisLabel": "",
                    "axisPlacement": "auto",
                    "barAlignment": 0,
                    "drawStyle": "line",
                    "fillOpacity": 12,
                    "gradientMode": "none",
                    "hideFrom": {"legend": False, "tooltip": False, "viz": False},
                    "insertNulls": False,
                    "lineInterpolation": "linear",
                    "lineWidth": 1,
                    "pointSize": 4,
                    "scaleDistribution": {"type": "linear"},
                    "showPoints": "never",
                    "spanNulls": False,
                    "stacking": {"group": "A", "mode": "none"},
                    "thresholdsStyle": {"mode": "off"},
                },
                "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
                "unit": unit,
            },
            "overrides": [],
        },
        "gridPos": grid(panel_id),
        "id": panel_id,
        "options": {
            "legend": {"calcs": ["lastNotNull"], "displayMode": "list", "placement": "bottom", "showLegend": True},
            "tooltip": {"hideZeros": False, "mode": "multi", "sort": "none"},
        },
        "pluginVersion": "13.1.1",
        "targets": [target(query["expr"], chr(65 + index), query.get("legend", "")) for index, query in enumerate(queries)],
        "title": title,
        "type": "timeseries",
    }


def table_panel(panel_id: int, title: str, expr: str) -> dict[str, Any]:
    """table panelを作成する。

    Args:
        panel_id: Grafana panel ID。
        title: panel title。
        expr: PromQL式。

    Returns:
        Grafana dashboard JSONのtable panel定義。
    """
    return {
        "datasource": DATASOURCE,
        "fieldConfig": {"defaults": {"custom": {"align": "auto", "cellOptions": {"type": "auto"}}}, "overrides": []},
        "gridPos": grid(panel_id),
        "id": panel_id,
        "options": {
            "cellHeight": "sm",
            "footer": {"countRows": False, "fields": "", "reducer": ["sum"], "show": False},
            "showHeader": True,
        },
        "pluginVersion": "13.1.1",
        "targets": [target(expr, "A")],
        "title": title,
        "type": "table",
    }


def base_panels(job: str) -> list[dict[str, Any]]:
    """全サービスに共通するscrape状態panelを作成する。

    Args:
        job: Prometheusのjob label値。

    Returns:
        共通panel定義の配列。
    """
    return [
        stat_panel(1, "Targets Up", f"sum(up{{job=\"{job}\"}})", "short"),
        stat_panel(2, "Target Count", f"count(up{{job=\"{job}\"}})", "short"),
        stat_panel(3, "Scraped Samples", f"sum(scrape_samples_scraped{{job=\"{job}\"}})", "short"),
        timeseries_panel(
            4,
            "Scrape Duration",
            [{"expr": f"scrape_duration_seconds{{job=\"{job}\"}}", "legend": "{{instance}}"}],
            "s",
        ),
        timeseries_panel(
            5,
            "Scrape Samples",
            [{"expr": f"scrape_samples_scraped{{job=\"{job}\"}}", "legend": "{{instance}}"}],
            "short",
        ),
        table_panel(6, "Target Status", f"up{{job=\"{job}\"}}"),
    ]


def dashboard(config: dict[str, Any]) -> dict[str, Any]:
    """service dashboardを作成する。

    Args:
        config: dashboard title、uid、job、追加panelを含む設定。

    Returns:
        Grafana dashboard JSON。
    """
    panels = base_panels(config["job"])
    for offset, panel in enumerate(config.get("panels", []), start=7):
        panel = dict(panel)
        panel["id"] = offset
        panel["gridPos"] = grid(offset)
        panels.append(panel)

    return {
        "annotations": {
            "list": [
                {
                    "builtIn": 1,
                    "datasource": {"type": "grafana", "uid": "-- Grafana --"},
                    "enable": True,
                    "hide": True,
                    "iconColor": "rgba(0, 211, 255, 1)",
                    "name": "Annotations & Alerts",
                    "type": "dashboard",
                }
            ]
        },
        "editable": True,
        "fiscalYearStartMonth": 0,
        "graphTooltip": 1,
        "links": [],
        "panels": panels,
        "refresh": "30s",
        "schemaVersion": 42,
        "tags": ["o11y", "service", config["job"]],
        "templating": {"list": []},
        "time": {"from": "now-6h", "to": "now"},
        "timepicker": {},
        "timezone": "browser",
        "title": config["title"],
        "uid": config["uid"],
        "version": 1,
        "weekStart": "",
    }


def service_panel(title: str, queries: list[dict[str, str]], unit: str = "short") -> dict[str, Any]:
    """サービス固有のtime series panel雛形を作成する。

    Args:
        title: panel title。
        queries: `expr`と`legend`を含むquery定義の配列。
        unit: Grafana field unit。

    Returns:
        IDと配置を後で設定するtime series panel定義。
    """
    panel = timeseries_panel(1, title, queries, unit)
    panel.pop("id")
    panel.pop("gridPos")
    return panel


def service_table(title: str, expr: str) -> dict[str, Any]:
    """サービス固有のtable panel雛形を作成する。

    Args:
        title: panel title。
        expr: PromQL式。

    Returns:
        IDと配置を後で設定するtable panel定義。
    """
    panel = table_panel(1, title, expr)
    panel.pop("id")
    panel.pop("gridPos")
    return panel


def write_dashboard(config: dict[str, Any]) -> None:
    """dashboard JSONをファイルへ書き出す。

    Args:
        config: dashboard title、uid、job、出力file名を含む設定。

    Returns:
        None。

    Side Effects:
        `50-o11y/grafana/dashboards/services`配下へJSON fileを書き込む。
    """
    ROOT.mkdir(parents=True, exist_ok=True)
    ROOT.chmod(0o755)
    path = ROOT / config["file"]
    path.write_text(json.dumps(dashboard(config), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o644)


def main() -> None:
    """サービス別dashboardをまとめて生成する。

    Args:
        None。

    Returns:
        None。

    Side Effects:
        複数のdashboard JSON fileを作成または上書きする。
    """
    services = [
        {
            "file": "open-webui.json",
            "title": "Open-WebUI",
            "uid": "svc-open-webui",
            "job": "open-webui",
            "panels": [
                service_panel("HTTP Requests", [{"expr": 'sum by (http_method, http_route, http_status_code) (rate(http_server_requests_total{job="open-webui"}[5m]))', "legend": "{{http_method}} {{http_route}} {{http_status_code}}"}], "reqps"),
                service_panel("HTTP Duration p95", [{"expr": 'histogram_quantile(0.95, sum by (le, http_route) (rate(http_server_duration_milliseconds_bucket{job="open-webui"}[5m])))', "legend": "{{http_route}}"}], "ms"),
                service_panel("Users", [{"expr": 'webui_users_total{job="open-webui"}', "legend": "total"}, {"expr": 'webui_users_active{job="open-webui"}', "legend": "active"}, {"expr": 'webui_users_active_today{job="open-webui"}', "legend": "active today"}], "short"),
            ],
        },
        {
            "file": "cloudflared.json",
            "title": "Cloudflared",
            "uid": "svc-cloudflared",
            "job": "cloudflared",
            "panels": [
                service_panel("Tunnel Connections", [{"expr": 'cloudflared_tunnel_ha_connections{job="cloudflared"}', "legend": "ha connections"}]),
                service_panel("Tunnel Requests", [{"expr": 'rate(cloudflared_tunnel_total_requests{job="cloudflared"}[5m])', "legend": "requests"}, {"expr": 'rate(cloudflared_tunnel_request_errors{job="cloudflared"}[5m])', "legend": "errors"}], "reqps"),
                service_panel("Active Sessions", [{"expr": 'cloudflared_tcp_active_sessions{job="cloudflared"}', "legend": "tcp"}, {"expr": 'cloudflared_udp_active_sessions{job="cloudflared"}', "legend": "udp"}]),
            ],
        },
        {
            "file": "keycloak.json",
            "title": "Keycloak",
            "uid": "svc-keycloak",
            "job": "keycloak",
            "panels": [
                service_panel("HTTP Activity", [{"expr": 'http_server_active_requests{job="keycloak"}', "legend": "{{instance}} requests"}, {"expr": 'http_server_active_connections{job="keycloak"}', "legend": "{{instance}} connections"}]),
                service_panel("Database Pool", [{"expr": 'agroal_active_count{job="keycloak"}', "legend": "{{instance}} active"}, {"expr": 'agroal_available_count{job="keycloak"}', "legend": "{{instance}} available"}, {"expr": 'agroal_awaiting_count{job="keycloak"}', "legend": "{{instance}} awaiting"}]),
                service_panel("Cache Gets", [{"expr": 'sum by (cache, result) (rate(cache_gets_total{job="keycloak"}[5m]))', "legend": "{{cache}} {{result}}"}]),
            ],
        },
        {
            "file": "couchdb.json",
            "title": "CouchDB",
            "uid": "svc-couchdb",
            "job": "couchdb",
            "panels": [
                service_panel("HTTP Requests", [{"expr": 'rate(couchdb_httpd_requests{job="couchdb"}[5m])', "legend": "{{instance}}"}], "reqps"),
                service_panel("Database Reads/Writes", [{"expr": 'rate(couchdb_database_reads{job="couchdb"}[5m])', "legend": "reads"}, {"expr": 'rate(couchdb_database_writes{job="couchdb"}[5m])', "legend": "writes"}]),
                service_panel("Open Databases", [{"expr": 'couchdb_open_databases{job="couchdb"}', "legend": "{{instance}}"}]),
            ],
        },
        {
            "file": "nextcloud.json",
            "title": "Nextcloud",
            "uid": "svc-nextcloud",
            "job": "nextcloud",
            "panels": [
                service_panel("Users", [{"expr": 'nextcloud_users{job="nextcloud"}', "legend": "{{instance}}"}]),
                service_panel("Shares", [{"expr": 'nextcloud_shares{job="nextcloud"}', "legend": "{{instance}}"}]),
                service_panel("Storage", [{"expr": 'nextcloud_storage_free_bytes{job="nextcloud"}', "legend": "free"}, {"expr": 'nextcloud_storage_used_bytes{job="nextcloud"}', "legend": "used"}], "bytes"),
            ],
        },
        {
            "file": "text-embeddings-inference.json",
            "title": "Text Embeddings Inference",
            "uid": "svc-tei",
            "job": "text-embeddings-inference",
            "panels": [
                service_panel("HTTP Requests", [{"expr": 'sum by (instance) (rate(http_requests_total{job="text-embeddings-inference"}[5m]))', "legend": "{{instance}}"}], "reqps"),
                service_panel("Request Duration", [{"expr": 'histogram_quantile(0.95, sum by (le, instance) (rate(http_request_duration_seconds_bucket{job="text-embeddings-inference"}[5m])))', "legend": "{{instance}} p95"}], "s"),
                service_panel("Queue", [{"expr": 'queue_size{job="text-embeddings-inference"}', "legend": "{{instance}}"}]),
            ],
        },
        {
            "file": "litellm.json",
            "title": "LiteLLM",
            "uid": "svc-litellm",
            "job": "litellm",
            "panels": [
                service_panel("Requests", [{"expr": 'sum(rate(litellm_requests_metric{job="litellm"}[5m]))', "legend": "requests"}], "reqps"),
                service_panel("Tokens", [{"expr": 'sum(rate(litellm_total_tokens{job="litellm"}[5m]))', "legend": "tokens"}]),
                service_panel("Responses", [{"expr": 'sum(rate(litellm_deployment_success_responses_total{job="litellm"}[5m]))', "legend": "success"}, {"expr": 'sum(rate(litellm_deployment_failure_responses_total{job="litellm"}[5m]))', "legend": "failure"}]),
            ],
        },
        {
            "file": "searxng.json",
            "title": "SearXNG",
            "uid": "svc-searxng",
            "job": "searxng",
            "panels": [
                service_panel("Metric Handler Samples", [{"expr": 'scrape_samples_scraped{job="searxng"}', "legend": "{{instance}}"}]),
                service_panel("Metric Handler Duration", [{"expr": 'scrape_duration_seconds{job="searxng"}', "legend": "{{instance}}"}], "s"),
            ],
        },
        {
            "file": "gitea.json",
            "title": "Gitea",
            "uid": "svc-gitea",
            "job": "gitea",
            "panels": [
                service_panel("HTTP Requests", [{"expr": 'sum by (method, status) (rate(gitea_http_request_duration_seconds_count{job="gitea"}[5m]))', "legend": "{{method}} {{status}}"}], "reqps"),
                service_panel("HTTP Duration p95", [{"expr": 'histogram_quantile(0.95, sum by (le, method) (rate(gitea_http_request_duration_seconds_bucket{job="gitea"}[5m])))', "legend": "{{method}}"}], "s"),
                service_panel("Process", [{"expr": 'process_resident_memory_bytes{job="gitea"}', "legend": "rss"}], "bytes"),
            ],
        },
        {
            "file": "qdrant.json",
            "title": "Qdrant",
            "uid": "svc-qdrant",
            "job": "qdrant",
            "panels": [
                service_panel("REST Responses", [{"expr": 'sum by (method, status) (rate(rest_responses_total{job="qdrant"}[5m]))', "legend": "{{method}} {{status}}"}], "reqps"),
                service_panel("gRPC Responses", [{"expr": 'sum by (method, status) (rate(grpc_responses_total{job="qdrant"}[5m]))', "legend": "{{method}} {{status}}"}], "reqps"),
                service_table("App Info", 'app_info{job="qdrant"}'),
            ],
        },
        {
            "file": "postgres-exporters.json",
            "title": "PostgreSQL Exporters",
            "uid": "svc-postgres-exporters",
            "job": "postgres-exporters",
            "panels": [
                service_panel("PostgreSQL Up", [{"expr": 'pg_up{job="postgres-exporters"}', "legend": "{{instance}}"}]),
                service_panel("Connections", [{"expr": 'sum by (instance, datname) (pg_stat_database_numbackends{job="postgres-exporters"})', "legend": "{{instance}} {{datname}}"}]),
                service_panel("Database Size", [{"expr": 'pg_database_size_bytes{job="postgres-exporters"}', "legend": "{{instance}} {{datname}}"}], "bytes"),
            ],
        },
        {
            "file": "redis-exporters.json",
            "title": "Redis Exporters",
            "uid": "svc-redis-exporters",
            "job": "redis-exporters",
            "panels": [
                service_panel("Redis Up", [{"expr": 'redis_up{job="redis-exporters"}', "legend": "{{instance}}"}]),
                service_panel("Connected Clients", [{"expr": 'redis_connected_clients{job="redis-exporters"}', "legend": "{{instance}}"}]),
                service_panel("Memory", [{"expr": 'redis_memory_used_bytes{job="redis-exporters"}', "legend": "{{instance}}"}], "bytes"),
            ],
        },
        {
            "file": "mysqld-exporters.json",
            "title": "MySQL Exporters",
            "uid": "svc-mysqld-exporters",
            "job": "mysqld-exporters",
            "panels": [
                service_panel("MySQL Up", [{"expr": 'mysql_up{job="mysqld-exporters"}', "legend": "{{instance}}"}]),
                service_panel("Connections", [{"expr": 'mysql_global_status_threads_connected{job="mysqld-exporters"}', "legend": "{{instance}}"}]),
                service_panel("Queries", [{"expr": 'rate(mysql_global_status_queries{job="mysqld-exporters"}[5m])', "legend": "{{instance}}"}], "qps"),
            ],
        },
        {
            "file": "rabbitmq.json",
            "title": "RabbitMQ",
            "uid": "svc-rabbitmq",
            "job": "rabbitmq",
            "panels": [
                service_panel("RabbitMQ Up", [{"expr": 'rabbitmq_up{job="rabbitmq"}', "legend": "{{instance}}"}]),
                service_panel("Queue Messages", [{"expr": 'sum by (queue) (rabbitmq_queue_messages{job="rabbitmq"})', "legend": "{{queue}}"}]),
                service_panel("Connections", [{"expr": 'rabbitmq_connections{job="rabbitmq"}', "legend": "{{instance}}"}]),
            ],
        },
        {
            "file": "clickhouse.json",
            "title": "ClickHouse",
            "uid": "svc-clickhouse",
            "job": "clickhouse",
            "panels": [
                service_panel("Queries", [{"expr": 'ClickHouseMetrics_Query{job="clickhouse"}', "legend": "{{instance}}"}]),
                service_panel("Uptime", [{"expr": 'ClickHouseAsyncMetrics_Uptime{job="clickhouse"}', "legend": "{{instance}}"}], "s"),
                service_panel("Memory", [{"expr": 'ClickHouseMetrics_MemoryTracking{job="clickhouse"}', "legend": "{{instance}}"}], "bytes"),
            ],
        },
        {
            "file": "minio.json",
            "title": "MinIO",
            "uid": "svc-minio",
            "job": "minio",
            "panels": [
                service_panel("S3 Requests", [{"expr": 'sum by (api) (rate(minio_s3_requests_total{job="minio"}[5m]))', "legend": "{{api}}"}], "reqps"),
                service_panel("Usage", [{"expr": 'minio_cluster_usage_total_bytes{job="minio"}', "legend": "used"}, {"expr": 'minio_cluster_capacity_usable_total_bytes{job="minio"}', "legend": "usable"}], "bytes"),
                service_panel("Online Disks", [{"expr": 'minio_cluster_nodes_online_total{job="minio"}', "legend": "nodes"}]),
            ],
        },
        {
            "file": "http-probes.json",
            "title": "HTTP Probes",
            "uid": "svc-http-probes",
            "job": "blackbox-http",
            "panels": [
                service_panel("Probe Success", [{"expr": 'probe_success{job="blackbox-http"}', "legend": "{{instance}}"}]),
                service_panel("Probe Duration", [{"expr": 'probe_duration_seconds{job="blackbox-http"}', "legend": "{{instance}}"}], "s"),
                service_table("Probe Targets", 'probe_success{job="blackbox-http"}'),
            ],
        },
    ]

    for config in services:
        write_dashboard(config)


if __name__ == "__main__":
    main()
