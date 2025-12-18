#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import ipaddress
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

try:
    import yaml  # type: ignore
except Exception as e:  # pragma: no cover
    raise SystemExit(
        "PyYAML is required. Install with: python3 -m pip install pyyaml\n"
        "On Ubuntu: sudo apt-get install -y python3-yaml\n"
        "On Amazon Linux 2023: sudo dnf install -y python3-pyyaml"
    ) from e


CF_API_BASE = "https://api.cloudflare.com/client/v4"


def _http_get_text(url: str, timeout: int = 10) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "wp-setup/1.0"}, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace").strip()


def _detect_public_ip(version: int) -> str:
    # Keep it simple and robust: try multiple providers.
    candidates = (
        [
            "https://api.ipify.org",
            "https://checkip.amazonaws.com",
            "https://ifconfig.me/ip",
        ]
        if version == 4
        else [
            "https://api64.ipify.org",
            "https://ifconfig.me/ip",
        ]
    )

    last_err: Exception | None = None
    for url in candidates:
        try:
            txt = _http_get_text(url)
            ip = ipaddress.ip_address(txt)
            if ip.version != version:
                continue
            if ip.is_global:
                return str(ip)
        except Exception as e:  # pragma: no cover
            last_err = e
            continue

    raise RuntimeError(
        f"Failed to auto-detect public IPv{version}. "
        f"Set cloudflare.dns.origin_ipv{version} explicitly. "
        f"Last error: {last_err}"
    )


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _load_yaml(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(_read_text(path))
    if not isinstance(data, dict):
        raise ValueError("config root must be a mapping")
    return data


def _load_env_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for raw in _read_text(path).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :]
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
    return env


def _as_bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return default


def _require_str(obj: Any, key_path: str) -> str:
    if not isinstance(obj, str) or not obj.strip():
        raise ValueError(f"Expected non-empty string at {key_path}")
    return obj.strip()


def _is_fqdn(name: str) -> bool:
    if name.startswith("*."):
        name = name[2:]
    return bool(re.fullmatch(r"[a-zA-Z0-9.-]+", name)) and "." in name


@dataclass(frozen=True)
class DesiredRecord:
    zone_name: str
    type: str
    name: str
    content: str
    ttl: int
    proxied: bool


class CloudflareApi:
    def __init__(self, token: str) -> None:
        self._token = token

    def _request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        url = CF_API_BASE + path
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Cloudflare API error {e.code} for {method} {path}: {body}") from e
        obj = json.loads(body)
        if not isinstance(obj, dict) or not obj.get("success", False):
            raise RuntimeError(f"Cloudflare API failure for {method} {path}: {body}")
        return obj

    def list_zones(self) -> list[dict[str, Any]]:
        zones: list[dict[str, Any]] = []
        page = 1
        while True:
            q = urllib.parse.urlencode({"page": page, "per_page": 50})
            res = self._request("GET", f"/zones?{q}")
            batch = res.get("result")
            if isinstance(batch, list):
                zones.extend([z for z in batch if isinstance(z, dict)])
            info = res.get("result_info")
            if not isinstance(info, dict):
                break
            total_pages = int(info.get("total_pages", page))
            if page >= total_pages:
                break
            page += 1
        return zones

    def find_dns_record(self, zone_id: str, rtype: str, name: str) -> dict[str, Any] | None:
        q = urllib.parse.urlencode({"type": rtype, "name": name, "per_page": 50})
        res = self._request("GET", f"/zones/{zone_id}/dns_records?{q}")
        result = res.get("result")
        if isinstance(result, list) and result:
            rec = result[0]
            return rec if isinstance(rec, dict) else None
        return None

    def create_dns_record(self, zone_id: str, r: DesiredRecord) -> dict[str, Any]:
        payload = {
            "type": r.type,
            "name": r.name,
            "content": r.content,
            "ttl": r.ttl,
            "proxied": r.proxied,
        }
        return self._request("POST", f"/zones/{zone_id}/dns_records", payload)

    def update_dns_record(self, zone_id: str, record_id: str, r: DesiredRecord) -> dict[str, Any]:
        payload = {
            "type": r.type,
            "name": r.name,
            "content": r.content,
            "ttl": r.ttl,
            "proxied": r.proxied,
        }
        return self._request("PUT", f"/zones/{zone_id}/dns_records/{record_id}", payload)


def _pick_zone_for_fqdn(fqdn: str, zone_names: Iterable[str]) -> str | None:
    matches = [z for z in zone_names if fqdn == z or fqdn.endswith("." + z)]
    if not matches:
        return None
    return max(matches, key=len)


def build_desired_records(cfg: dict[str, Any]) -> list[DesiredRecord]:
    cf = cfg.get("cloudflare")
    if not isinstance(cf, dict):
        raise ValueError("cloudflare must be a mapping")

    dns_cfg = cf.get("dns")
    if dns_cfg is None:
        # Backward-compatible: treat missing dns config as disabled.
        return []
    if not isinstance(dns_cfg, dict):
        raise ValueError("cloudflare.dns must be a mapping")

    enabled = _as_bool(dns_cfg.get("enabled"), default=False)
    if not enabled:
        return []

    origin_ipv4_cfg = dns_cfg.get("origin_ipv4")
    origin_ipv6_cfg = dns_cfg.get("origin_ipv6")

    origin_ipv4 = ""
    if origin_ipv4_cfg is None or str(origin_ipv4_cfg).strip().lower() == "auto":
        origin_ipv4 = _detect_public_ip(4)
    else:
        origin_ipv4 = _require_str(origin_ipv4_cfg, "cloudflare.dns.origin_ipv4")

    origin_ipv6 = ""
    if origin_ipv6_cfg is None:
        origin_ipv6 = ""  # optional
    elif str(origin_ipv6_cfg).strip().lower() == "auto":
        origin_ipv6 = _detect_public_ip(6)
    else:
        origin_ipv6 = str(origin_ipv6_cfg or "").strip()
    ttl = int(dns_cfg.get("ttl") or 1)
    proxy_enabled = _as_bool(cf.get("proxy_enabled"), default=True)

    edge = cfg.get("edge")
    if not isinstance(edge, dict):
        raise ValueError("edge must be a mapping")
    sites = edge.get("sites")
    if not isinstance(sites, list) or not sites:
        raise ValueError("edge.sites must be a non-empty list")

    fqdn_set: set[str] = set()
    for s in sites:
        if not isinstance(s, dict):
            continue
        tls = s.get("tls_domains")
        if not isinstance(tls, list):
            continue
        for d in tls:
            ds = str(d).strip()
            if ds and _is_fqdn(ds):
                fqdn_set.add(ds)

    # Determine zones by suffix match
    # We only decide zone_name later (needs API zones list), so keep a placeholder for now.
    # We'll fill zone_name during apply/plan.
    desired: list[DesiredRecord] = []
    for fqdn in sorted(fqdn_set):
        desired.append(
            DesiredRecord(
                zone_name="",
                type="A",
                name=fqdn,
                content=origin_ipv4,
                ttl=ttl,
                proxied=proxy_enabled,
            )
        )
        if origin_ipv6:
            desired.append(
                DesiredRecord(
                    zone_name="",
                    type="AAAA",
                    name=fqdn,
                    content=origin_ipv6,
                    ttl=ttl,
                    proxied=proxy_enabled,
                )
            )

    return desired


def main() -> int:
    ap = argparse.ArgumentParser(description="Upsert required Cloudflare DNS records for this stack")
    ap.add_argument("--config", default="config/config.yml", help="Path to config.yml")
    ap.add_argument("--secrets", default="config/secrets.env", help="Path to secrets.env")
    ap.add_argument("--apply", action="store_true", help="Actually apply changes (default: plan only)")
    args = ap.parse_args()

    cfg = _load_yaml(Path(args.config))
    desired = build_desired_records(cfg)
    if not desired:
        print("cloudflare.dns.enabled is false; nothing to do.")
        return 0

    secrets_path = Path(args.secrets)
    secrets = _load_env_file(secrets_path) if secrets_path.exists() else {}

    cf = cfg.get("cloudflare")
    if not isinstance(cf, dict):
        raise SystemExit("cloudflare must be a mapping")

    token_env_name = str(cf.get("dns_api_token_env") or "CF_DNS_API_TOKEN").strip() or "CF_DNS_API_TOKEN"
    token = os.environ.get(token_env_name) or secrets.get(token_env_name) or secrets.get("CF_DNS_API_TOKEN")
    if not token:
        raise SystemExit(
            f"Missing Cloudflare API token. Put {token_env_name}=... into {args.secrets} (or export it)."
        )

    api = CloudflareApi(token)
    zones = api.list_zones()
    zone_name_to_id: dict[str, str] = {}
    zone_names: list[str] = []
    for z in zones:
        name = z.get("name")
        zid = z.get("id")
        if isinstance(name, str) and isinstance(zid, str):
            zone_names.append(name)
            zone_name_to_id[name] = zid

    # Fill zone_name for each desired record
    filled: list[DesiredRecord] = []
    for r in desired:
        zone = _pick_zone_for_fqdn(r.name.lstrip("*."), zone_names)
        if not zone:
            raise SystemExit(f"No Cloudflare zone found for record name: {r.name}")
        filled.append(
            DesiredRecord(
                zone_name=zone,
                type=r.type,
                name=r.name,
                content=r.content,
                ttl=r.ttl,
                proxied=r.proxied,
            )
        )

    # De-dupe
    uniq: dict[tuple[str, str, str], DesiredRecord] = {}
    for r in filled:
        uniq[(r.zone_name, r.type, r.name)] = r
    records = list(uniq.values())

    changed = 0
    created = 0
    unchanged = 0

    for r in sorted(records, key=lambda x: (x.zone_name, x.type, x.name)):
        zid = zone_name_to_id[r.zone_name]
        existing = api.find_dns_record(zid, r.type, r.name)

        if not args.apply:
            action = "create" if existing is None else "update"
            print(f"PLAN {action}: zone={r.zone_name} {r.type} {r.name} -> {r.content} proxied={int(r.proxied)} ttl={r.ttl}")
            continue

        if existing is None:
            api.create_dns_record(zid, r)
            created += 1
            changed += 1
            print(f"CREATED: zone={r.zone_name} {r.type} {r.name}")
            continue

        existing_content = existing.get("content")
        existing_ttl = existing.get("ttl")
        existing_proxied = existing.get("proxied")

        needs_update = (
            str(existing_content) != r.content
            or int(existing_ttl) != int(r.ttl)
            or bool(existing_proxied) != bool(r.proxied)
        )
        if not needs_update:
            unchanged += 1
            print(f"OK: zone={r.zone_name} {r.type} {r.name} (no change)")
            continue

        rid = existing.get("id")
        if not isinstance(rid, str) or not rid:
            raise RuntimeError(f"Existing record has no id: {existing}")

        api.update_dns_record(zid, rid, r)
        changed += 1
        print(f"UPDATED: zone={r.zone_name} {r.type} {r.name}")

    if args.apply:
        print(f"Done. created={created} updated={changed - created} unchanged={unchanged}")
    else:
        print(f"Done. planned_records={len(records)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
