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


def stat_panel(
    panel_id: int,
    title: str,
    expr: str,
    unit: str = "short",
    grid_pos: dict[str, int] | None = None,
) -> dict[str, Any]:
    """stat panelを作成する。

    Args:
        panel_id: Grafana panel ID。
        title: panel title。
        expr: PromQL式。
        unit: Grafana field unit。
        grid_pos: 明示的に配置する場合のgridPos。Noneの場合は標準配置。

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
        "gridPos": grid_pos or grid(panel_id),
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


def timeseries_panel(
    panel_id: int,
    title: str,
    queries: list[dict[str, str]],
    unit: str = "short",
    grid_pos: dict[str, int] | None = None,
) -> dict[str, Any]:
    """time series panelを作成する。

    Args:
        panel_id: Grafana panel ID。
        title: panel title。
        queries: `expr`と`legend`を含むquery定義の配列。
        unit: Grafana field unit。
        grid_pos: 明示的に配置する場合のgridPos。Noneの場合は標準配置。

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
        "gridPos": grid_pos or grid(panel_id),
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


def table_panel(
    panel_id: int,
    title: str,
    expr: str,
    grid_pos: dict[str, int] | None = None,
) -> dict[str, Any]:
    """table panelを作成する。

    Args:
        panel_id: Grafana panel ID。
        title: panel title。
        expr: PromQL式。
        grid_pos: 明示的に配置する場合のgridPos。Noneの場合は標準配置。

    Returns:
        Grafana dashboard JSONのtable panel定義。
    """
    return {
        "datasource": DATASOURCE,
        "fieldConfig": {"defaults": {"custom": {"align": "auto", "cellOptions": {"type": "auto"}}}, "overrides": []},
        "gridPos": grid_pos or grid(panel_id),
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
    panels = base_panels(config["job"]) if config.get("base_panels", True) else []
    start_id = len(panels) + 1
    for offset, panel in enumerate(config.get("panels", []), start=start_id):
        panel = dict(panel)
        panel.setdefault("id", offset)
        panel.setdefault("gridPos", grid(offset))
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
            "file": "cloudflared.json",
            "title": "Cloudflared",
            "uid": "svc-cloudflared",
            "job": "cloudflared",
            "panels": [
                service_panel("Tunnel Connections", [{"expr": 'cloudflared_tunnel_ha_connections{job="cloudflared"}', "legend": "ha connections"}]),
                service_panel("Concurrent Requests Per Tunnel", [{"expr": 'cloudflared_tunnel_concurrent_requests_per_tunnel{job="cloudflared"}', "legend": "{{instance}}"}]),
                service_panel("Request and Origin Error Rate", [{"expr": 'rate(cloudflared_tunnel_total_requests{job="cloudflared"}[5m])', "legend": "requests"}, {"expr": 'rate(cloudflared_tunnel_request_errors{job="cloudflared"}[5m])', "legend": "origin errors"}], "reqps"),
                service_panel("Response Codes", [{"expr": 'sum by (status_code) (rate(cloudflared_tunnel_response_by_code{job="cloudflared"}[5m]))', "legend": "{{status_code}}"}], "reqps"),
                service_panel("Origin Error Ratio", [{"expr": '100 * sum(rate(cloudflared_tunnel_request_errors{job="cloudflared"}[5m])) / clamp_min(sum(rate(cloudflared_tunnel_total_requests{job="cloudflared"}[5m])), 1)', "legend": "origin error ratio"}], "percent"),
                service_panel("TCP/UDP Active Sessions", [{"expr": 'cloudflared_tcp_active_sessions{job="cloudflared"}', "legend": "tcp"}, {"expr": 'cloudflared_udp_active_sessions{job="cloudflared"}', "legend": "udp"}]),
                service_panel("TCP/UDP Session Rate", [{"expr": 'rate(cloudflared_tcp_total_sessions{job="cloudflared"}[5m])', "legend": "tcp"}, {"expr": 'rate(cloudflared_udp_total_sessions{job="cloudflared"}[5m])', "legend": "udp"}], "ops"),
                service_panel("Tunnel Registration Events", [{"expr": 'rate(cloudflared_tunnel_tunnel_register_success{job="cloudflared"}[5m])', "legend": "success"}, {"expr": 'rate(cloudflared_tunnel_tunnel_register_fail{job="cloudflared"}[5m])', "legend": "fail"}], "ops"),
                service_panel("Edge Locations", [{"expr": 'cloudflared_tunnel_server_locations{job="cloudflared"}', "legend": "{{edge_location}}"}]),
                service_panel("RPC Operations and Failures", [{"expr": 'rate(cloudflared_rpc_client_operations{job="cloudflared"}[5m])', "legend": "operations"}, {"expr": 'rate(cloudflared_rpc_client_failures{job="cloudflared"}[5m])', "legend": "failures"}], "ops"),
                service_panel("RPC Latency p95", [{"expr": 'histogram_quantile(0.95, sum by (le) (rate(cloudflared_rpc_client_latency_secs_bucket{job="cloudflared"}[5m])))', "legend": "p95"}], "s"),
                service_panel("Proxy Connect Latency p95", [{"expr": 'histogram_quantile(0.95, sum by (le) (rate(cloudflared_proxy_connect_latency_bucket{job="cloudflared"}[5m])))', "legend": "p95"}], "s"),
                service_panel("Process Memory", [{"expr": 'process_resident_memory_bytes{job="cloudflared"}', "legend": "rss"}, {"expr": 'go_memstats_heap_inuse_bytes{job="cloudflared"}', "legend": "heap in-use"}], "bytes"),
                service_panel("Process Concurrency", [{"expr": 'go_goroutines{job="cloudflared"}', "legend": "goroutines"}, {"expr": 'promhttp_metric_handler_requests_in_flight{job="cloudflared"}', "legend": "metrics in flight"}]),
                service_table("Build Info", 'build_info{job="cloudflared"}'),
            ],
        },
        {
            "file": "couchdb.json",
            "title": "CouchDB",
            "uid": "svc-couchdb",
            "job": "couchdb",
            "panels": [
                service_panel("HTTP Methods", [{"expr": 'sum by (method) (rate(couchdb_httpd_request_methods{job="couchdb"}[5m]))', "legend": "{{method}}"}], "reqps"),
                service_panel("Database Reads/Writes", [{"expr": 'rate(couchdb_database_reads{job="couchdb"}[5m])', "legend": "reads"}, {"expr": 'rate(couchdb_database_writes{job="couchdb"}[5m])', "legend": "writes"}]),
                service_panel("Document Activity", [{"expr": 'rate(couchdb_document_inserts_total{job="couchdb"}[5m])', "legend": "inserts"}, {"expr": 'rate(couchdb_document_writes_total{job="couchdb"}[5m])', "legend": "writes"}], "ops"),
                service_panel("Replication Jobs", [{"expr": 'couchdb_couch_replicator_jobs_running{job="couchdb"}', "legend": "running"}, {"expr": 'couchdb_couch_replicator_jobs_pending{job="couchdb"}', "legend": "pending"}, {"expr": 'couchdb_couch_replicator_jobs_crashed{job="couchdb"}', "legend": "crashed"}]),
                service_panel("Erlang Memory", [{"expr": 'couchdb_erlang_memory_bytes{job="couchdb"}', "legend": "{{memory}}"}], "bytes"),
                service_panel("Message Queues", [{"expr": 'couchdb_erlang_message_queues{job="couchdb"}', "legend": "queues"}, {"expr": 'couchdb_global_changes_listener_pending_updates{job="couchdb"}', "legend": "global changes pending"}]),
            ],
        },
        {
            "file": "gpu.json",
            "title": "GPU",
            "uid": "svc-gpu",
            "job": "node",
            "panels": [
                service_panel("GPU Exporter Up", [{"expr": 'up{job=~"nvidia-dcgm-exporter|amd-device-metrics-exporter"}', "legend": "{{job}} {{instance}}"}]),
                service_panel("GPU Utilization", [{"expr": 'avg by (gpu, gpu_id) (DCGM_FI_DEV_GPU_UTIL) or avg by (gpu_uuid, gpu_id) (amd_gpu_gfx_busy_instantaneous)', "legend": "{{gpu}}{{gpu_id}}{{gpu_uuid}}"}], "percent"),
                service_panel("VRAM Used", [{"expr": 'DCGM_FI_DEV_FB_USED * 1024 * 1024 or amd_gpu_used_vram', "legend": "{{gpu}}{{gpu_id}}{{gpu_uuid}}"}], "bytes"),
                service_panel("GPU Temperature", [{"expr": 'DCGM_FI_DEV_GPU_TEMP or amd_gpu_edge_temperature or amd_gpu_junction_temperature', "legend": "{{gpu}}{{gpu_id}}{{gpu_uuid}}"}], "celsius"),
                service_panel("GPU Power", [{"expr": 'DCGM_FI_DEV_POWER_USAGE or amd_gpu_package_power or amd_gpu_average_package_power', "legend": "{{gpu}}{{gpu_id}}{{gpu_uuid}}"}], "watt"),
                service_panel("Host Thermal Sensors", [{"expr": 'node_hwmon_temp_celsius{job="node"}', "legend": "{{chip}} {{sensor}}"}], "celsius"),
            ],
        },
        {
            "file": "keycloak.json",
            "title": "Keycloak",
            "uid": "svc-keycloak",
            "job": "keycloak",
            "panels": [
                service_panel("HTTP Activity", [{"expr": 'http_server_active_requests{job="keycloak"}', "legend": "{{instance}} requests"}, {"expr": 'http_server_active_connections{job="keycloak"}', "legend": "{{instance}} connections"}]),
                service_panel("HTTP Error Rate", [{"expr": 'sum by (instance) (rate(http_server_errors_total{job="keycloak"}[5m]))', "legend": "{{instance}}"}], "eps"),
                service_panel("Database Pool", [{"expr": 'agroal_active_count{job="keycloak"}', "legend": "{{instance}} active"}, {"expr": 'agroal_available_count{job="keycloak"}', "legend": "{{instance}} available"}, {"expr": 'agroal_awaiting_count{job="keycloak"}', "legend": "{{instance}} awaiting"}]),
                service_panel("Cache Size", [{"expr": 'sum by (cache) (cache_size{job="keycloak"})', "legend": "{{cache}}"}]),
                service_panel("JVM Memory", [{"expr": 'sum by (area) (jvm_memory_used_bytes{job="keycloak"})', "legend": "{{area}} used"}, {"expr": 'sum by (area) (jvm_memory_max_bytes{job="keycloak"})', "legend": "{{area}} max"}], "bytes"),
                service_panel("Password Hash Validations", [{"expr": 'sum by (provider) (rate(keycloak_credentials_password_hashing_validations_total{job="keycloak"}[5m]))', "legend": "{{provider}}"}], "ops"),
            ],
        },
        {
            "file": "nextcloud.json",
            "title": "Nextcloud",
            "uid": "svc-nextcloud",
            "job": "nextcloud",
            "panels": [
                service_panel("Users and Sessions", [{"expr": 'nextcloud_users{job="nextcloud"}', "legend": "users"}, {"expr": 'nextcloud_active_users{job="nextcloud"}', "legend": "active users"}, {"expr": 'nextcloud_active_sessions{job="nextcloud"}', "legend": "active sessions"}]),
                service_panel("Files and Shares", [{"expr": 'nextcloud_files{job="nextcloud"}', "legend": "files"}, {"expr": 'nextcloud_shares{job="nextcloud"}', "legend": "shares"}]),
                service_panel("Collaboration", [{"expr": 'nextcloud_comments{job="nextcloud"}', "legend": "comments"}, {"expr": 'nextcloud_running_jobs{job="nextcloud"}', "legend": "running jobs"}]),
                service_panel("App Enabled Count", [{"expr": 'sum(nextcloud_app_enabled{job="nextcloud"})', "legend": "enabled apps"}]),
                service_panel("Maintenance and Log Level", [{"expr": 'nextcloud_maintenance{job="nextcloud"}', "legend": "maintenance"}, {"expr": 'nextcloud_log_level{job="nextcloud"}', "legend": "log level"}]),
                service_table("Instance Info", 'nextcloud_instance_info{job="nextcloud"}'),
            ],
        },
        {
            "file": "open-webui.json",
            "title": "Open-WebUI",
            "uid": "svc-open-webui",
            "job": "open-webui",
            "panels": [
                service_panel("HTTP Requests", [{"expr": 'sum by (http_method, http_route, http_status_code) (rate(http_server_requests_total{job="open-webui"}[5m]))', "legend": "{{http_method}} {{http_route}} {{http_status_code}}"}], "reqps"),
                service_panel("HTTP Duration p95", [{"expr": 'histogram_quantile(0.95, sum by (le, http_route) (rate(http_server_duration_milliseconds_bucket{job="open-webui"}[5m])))', "legend": "{{http_route}}"}], "ms"),
                service_panel("Users", [{"expr": 'webui_users_total{job="open-webui"}', "legend": "total"}, {"expr": 'webui_users_active{job="open-webui"}', "legend": "active"}, {"expr": 'webui_users_active_today{job="open-webui"}', "legend": "active today"}]),
                service_panel("Status Code Mix", [{"expr": 'sum by (http_status_code) (rate(http_server_requests_total{job="open-webui"}[5m]))', "legend": "{{http_status_code}}"}], "reqps"),
                service_panel("Route Hotspots", [{"expr": 'topk(10, sum by (http_route) (rate(http_server_requests_total{job="open-webui"}[5m])))', "legend": "{{http_route}}"}], "reqps"),
                service_panel("Blackbox Availability", [{"expr": 'probe_success{job="blackbox-http",instance="http://open-webui:8080"}', "legend": "probe success"}]),
                service_panel("Blackbox Duration", [{"expr": 'probe_duration_seconds{job="blackbox-http",instance="http://open-webui:8080"}', "legend": "probe duration"}], "s"),
                service_table("OpenTelemetry Target Info", 'target_info{job="open-webui"}'),
            ],
        },
    ]

    for config in services:
        write_dashboard(config)


if __name__ == "__main__":
    main()
