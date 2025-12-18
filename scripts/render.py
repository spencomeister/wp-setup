#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import yaml  # type: ignore
except Exception as e:  # pragma: no cover
    raise SystemExit(
        "PyYAML is required. Install with: python3 -m pip install pyyaml\n"
        "On Ubuntu: sudo apt-get install -y python3-yaml\n"
        "On Amazon Linux 2023: sudo dnf install -y python3-pyyaml"
    ) from e


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _copy_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def _render_template(template: str, mapping: dict[str, str]) -> str:
    out = template
    for key, value in mapping.items():
        out = out.replace("{{" + key + "}}", value)
    return out


def _require_str(obj: Any, key_path: str) -> str:
    if not isinstance(obj, str) or not obj.strip():
        raise ValueError(f"Expected non-empty string at {key_path}")
    return obj


def _require_int(obj: Any, key_path: str) -> int:
    if not isinstance(obj, int):
        raise ValueError(f"Expected int at {key_path}")
    return obj


def _load_yaml(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(_read_text(path))
    if not isinstance(data, dict):
        raise ValueError("config root must be a mapping")
    return data


@dataclass(frozen=True)
class Site:
    name: str
    type: str
    server_names: list[str]
    cert_name: str
    upstream: str


def _is_valid_server_name(name: str) -> bool:
    # allow wildcard *.example.com
    if name.startswith("*."):
        name = name[2:]
    return bool(re.fullmatch(r"[a-zA-Z0-9.-]+", name)) and "." in name


def _cert_name_for_tls_domains(tls_domains: list[str]) -> str:
    # Certbot's live dir is usually named after the first domain requested.
    # We pick the first *non-wildcard* domain if present, else the first entry.
    for d in tls_domains:
        if not d.startswith("*."):
            return d
    return tls_domains[0]


def parse_sites(config: dict[str, Any]) -> tuple[int, str, list[Site], int]:
    edge = config.get("edge")
    if not isinstance(edge, dict):
        raise ValueError("edge must be a mapping")

    bind_port = _require_int(edge.get("bind_port"), "edge.bind_port")

    letsencrypt = config.get("letsencrypt")
    if not isinstance(letsencrypt, dict):
        raise ValueError("letsencrypt must be a mapping")
    le_dir = _require_str(letsencrypt.get("dir"), "letsencrypt.dir")

    wp = config.get("wordpress")
    if not isinstance(wp, dict):
        raise ValueError("wordpress must be a mapping")
    php = wp.get("php")
    if not isinstance(php, dict):
        raise ValueError("wordpress.php must be a mapping")
    upload_max_mb = _require_int(php.get("upload_max_mb"), "wordpress.php.upload_max_mb")

    sites_cfg = edge.get("sites")
    if not isinstance(sites_cfg, list) or not sites_cfg:
        raise ValueError("edge.sites must be a non-empty list")

    sites: list[Site] = []
    for idx, s in enumerate(sites_cfg):
        if not isinstance(s, dict):
            raise ValueError(f"edge.sites[{idx}] must be a mapping")

        name = _require_str(s.get("name"), f"edge.sites[{idx}].name")
        stype = _require_str(s.get("type"), f"edge.sites[{idx}].type")
        upstream = _require_str(s.get("upstream"), f"edge.sites[{idx}].upstream")

        tls_domains = s.get("tls_domains")
        if not isinstance(tls_domains, list) or not tls_domains:
            raise ValueError(f"edge.sites[{idx}].tls_domains must be a non-empty list")
        tls_domains_str = [_require_str(x, f"edge.sites[{idx}].tls_domains[]") for x in tls_domains]

        for d in tls_domains_str:
            if not _is_valid_server_name(d):
                raise ValueError(f"Invalid domain in edge.sites[{idx}].tls_domains: {d}")

        cert_name = _cert_name_for_tls_domains(tls_domains_str)
        sites.append(
            Site(
                name=name,
                type=stype,
                server_names=tls_domains_str,
                cert_name=cert_name,
                upstream=upstream,
            )
        )

    return bind_port, le_dir, sites, upload_max_mb


def render(config_path: Path, templates_dir: Path, out_dir: Path) -> None:
    config = _load_yaml(config_path)
    bind_port, le_dir, sites, upload_max_mb = parse_sites(config)

    # Preserve operator secrets across re-render
    preserved_secrets: str | None = None
    if (out_dir / "secrets.env").exists():
        preserved_secrets = _read_text(out_dir / "secrets.env")

    # Recreate out dir
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Copy snippets template tree
    _copy_tree(templates_dir / "nginx" / "snippets", out_dir / "nginx" / "snippets")

    # Render internal WordPress nginx site configs (wp-a/wp-b)
    wp_site_tpl = _read_text(templates_dir / "nginx" / "wp" / "site.conf.template")
    _write_text(
        out_dir / "nginx" / "wp-a" / "site.conf",
        _render_template(
            wp_site_tpl,
            {
                "UPLOAD_MAX_MB": str(upload_max_mb),
                "PHP_FPM_UPSTREAM": "wp-a-php:9000",
            },
        ),
    )
    _write_text(
        out_dir / "nginx" / "wp-b" / "site.conf",
        _render_template(
            wp_site_tpl,
            {
                "UPLOAD_MAX_MB": str(upload_max_mb),
                "PHP_FPM_UPSTREAM": "wp-b-php:9000",
            },
        ),
    )

    # Render edge nginx conf
    edge_base = _read_text(templates_dir / "nginx" / "edge" / "edge.conf.template")
    server_tpl = _read_text(templates_dir / "nginx" / "edge" / "server-block.template")

    server_blocks: list[str] = []
    for s in sites:
        server_blocks.append(
            _render_template(
                server_tpl,
                {
                    "SERVER_NAME": " ".join(s.server_names),
                    "CERT_NAME": s.cert_name,
                    "UPSTREAM": s.upstream,
                },
            )
        )

    edge_conf = _render_template(
        edge_base,
        {
            "SERVER_BLOCKS": "\n\n".join(server_blocks),
            "UPLOAD_MAX_MB": str(upload_max_mb),
        },
    )
    _write_text(out_dir / "nginx" / "edge" / "00-edge.conf", edge_conf)

    # Render php.ini
    php_ini_tpl = _read_text(templates_dir / "php-fpm" / "php.ini.template")
    php_ini = _render_template(php_ini_tpl, {"UPLOAD_MAX_MB": str(upload_max_mb)})
    _write_text(out_dir / "php-fpm" / "php.ini", php_ini)

    # Copy php-fpm Dockerfile
    shutil.copy2(templates_dir / "php-fpm" / "Dockerfile", out_dir / "php-fpm" / "Dockerfile")

    # Copy php-fpm Dockerfile + entrypoint templates if present later
    # (kept simple for now)

    # Render compose
    compose_tpl = _read_text(templates_dir / "docker-compose.template.yml")
    compose = _render_template(
        compose_tpl,
        {
            "EDGE_BIND_PORT": str(bind_port),
            "LE_DIR": le_dir,
        },
    )
    _write_text(out_dir / "docker-compose.yml", compose)

    # Convenience: copy secrets.env.example for operator
    secrets_example = config_path.parent / "secrets.env.example"
    if secrets_example.exists():
        _write_text(out_dir / "secrets.env.example", _read_text(secrets_example))

    # Copy canonical secrets if present
    canonical_secrets = config_path.parent / "secrets.env"
    secrets_content: str | None = None
    if canonical_secrets.exists():
        secrets_content = _read_text(canonical_secrets)
        _write_text(out_dir / "secrets.env", secrets_content)
    elif preserved_secrets is not None:
        secrets_content = preserved_secrets
        _write_text(out_dir / "secrets.env", secrets_content)

    # Also write .env for docker compose variable substitution.
    # Note: env_file sets container env, but ${VAR} substitution is resolved from
    # the compose CLI environment / .env / --env-file.
    if secrets_content is not None:
        _write_text(out_dir / ".env", secrets_content)

    # Copy certbot helper script templates are host-side; nothing to do here.


def main() -> int:
    parser = argparse.ArgumentParser(description="Render docker-compose/nginx from config.yml")
    parser.add_argument("--config", default="config/config.yml", help="Path to config.yml")
    parser.add_argument("--templates", default="templates", help="Templates directory")
    parser.add_argument("--out", default="out", help="Output directory")
    args = parser.parse_args()

    render(Path(args.config), Path(args.templates), Path(args.out))
    print(f"Rendered to {args.out}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
