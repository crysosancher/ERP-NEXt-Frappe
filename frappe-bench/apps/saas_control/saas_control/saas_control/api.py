from __future__ import annotations

import re
import subprocess
import os
from pathlib import Path

import frappe
from frappe import _
from frappe.utils import get_bench_path

REGISTRY_TABLE = "__saas_tenant_registry"
SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{1,62}$")
NIP_IO_SUFFIX = ".127.0.0.1.nip.io"


def _normalize_email(email: str) -> str:
    return (email or "").strip().lower()


def _normalize_slug(slug: str) -> str:
    value = (slug or "").strip().lower()
    if not SLUG_PATTERN.match(value):
        frappe.throw(_("Company slug can only contain lowercase letters, numbers, and hyphens."))
    return value


def _registry_table_sql() -> str:
    return f"""
        CREATE TABLE IF NOT EXISTS {REGISTRY_TABLE} (
            id BIGINT PRIMARY KEY AUTO_INCREMENT,
            owner_email VARCHAR(255) NOT NULL,
            company_slug VARCHAR(64) NOT NULL,
            site_name VARCHAR(255) NOT NULL,
            tenant_domain VARCHAR(255) NOT NULL,
            status VARCHAR(32) NOT NULL,
            log_text LONGTEXT,
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            UNIQUE KEY uq_owner_email (owner_email),
            UNIQUE KEY uq_company_slug (company_slug)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """


def _ensure_registry_table() -> None:
    frappe.db.sql(_registry_table_sql())


def _get_registry_row_by_email(email: str) -> dict | None:
    rows = frappe.db.sql(
        f"""
        SELECT owner_email, company_slug, site_name, tenant_domain, status, log_text
        FROM {REGISTRY_TABLE}
        WHERE owner_email=%s
        LIMIT 1
        """,
        (email,),
        as_dict=True,
    )
    return rows[0] if rows else None


def _get_registry_row_by_slug(slug: str) -> dict | None:
    rows = frappe.db.sql(
        f"""
        SELECT owner_email, company_slug, site_name, tenant_domain, status, log_text
        FROM {REGISTRY_TABLE}
        WHERE company_slug=%s
        LIMIT 1
        """,
        (slug,),
        as_dict=True,
    )
    return rows[0] if rows else None


def _upsert_registry(
    owner_email: str,
    company_slug: str,
    site_name: str,
    tenant_domain: str,
    status: str,
    log_text: str = "",
) -> None:
    frappe.db.sql(
        f"""
        INSERT INTO {REGISTRY_TABLE}
            (owner_email, company_slug, site_name, tenant_domain, status, log_text)
        VALUES (%s, %s, %s, %s, %s, %s)
        ON DUPLICATE KEY UPDATE
            company_slug=VALUES(company_slug),
            site_name=VALUES(site_name),
            tenant_domain=VALUES(tenant_domain),
            status=VALUES(status),
            log_text=VALUES(log_text)
        """,
        (owner_email, company_slug, site_name, tenant_domain, status, log_text),
    )
    frappe.db.commit()


def _get_base_domain() -> str:
    return (frappe.conf.get("saas_base_domain") or "erp.local").strip()


def _build_tenant_domain(company_slug: str) -> str:
    return f"{company_slug}.{_get_base_domain()}"


def _slug_from_domain(domain: str) -> str:
    return (domain or "").split(".", 1)[0]


def _nip_io_host_for_domain(domain: str) -> str:
    return f"{_slug_from_domain(domain)}{NIP_IO_SUFFIX}"


def _use_nip_io_redirects() -> bool:
    # Override behavior with saas_redirect_mode in common_site_config if needed.
    # Values: auto (default), nip_io, native
    mode = str(frappe.conf.get("saas_redirect_mode") or "auto").strip().lower()
    if mode == "nip_io":
        return True
    if mode == "native":
        return False

    request_host = ""
    if getattr(frappe.local, "request", None):
        request_host = str(getattr(frappe.local.request, "host", "") or "").lower()

    return any(token in request_host for token in ("localhost", "127.0.0.1", "nip.io"))


def _public_redirect_host(tenant_domain: str) -> str:
    return _nip_io_host_for_domain(tenant_domain) if _use_nip_io_redirects() else tenant_domain


def _bench_root() -> Path:
    return Path(get_bench_path())


def _site_exists(site_name: str) -> bool:
    return (_bench_root() / "sites" / site_name / "site_config.json").exists()


def _ensure_nip_io_site_alias(site_name: str) -> None:
    site_slug = _slug_from_domain(site_name)
    alias_host = f"{site_slug}{NIP_IO_SUFFIX}"
    sites_root = _bench_root() / "sites"
    alias_path = sites_root / alias_host

    if alias_path.exists() or alias_path.is_symlink():
        return

    try:
        alias_path.symlink_to(site_name)
    except Exception:
        # Alias creation failure should not block signup/login APIs.
        pass


def _run_provisioning(site_name: str, admin_password: str) -> str:
    script_path = _bench_root() / "scripts" / "provision_tenant.sh"
    if not script_path.exists():
        frappe.throw(_("Tenant provisioning script not found at {0}").format(str(script_path)))

    env = {
        **os.environ,
        **{
            "DB_HOST": str(frappe.conf.get("saas_db_host") or "127.0.0.1"),
            "DB_PORT": str(frappe.conf.get("saas_db_port") or "3307"),
            "DB_ROOT_USER": str(frappe.conf.get("saas_db_root_user") or "root"),
            "DB_CONTAINER": str(frappe.conf.get("saas_db_container") or "erp-mariadb"),
            "ERP_APP": str(frappe.conf.get("saas_erp_app") or "erpnext"),
        },
    }

    db_root_password = str(frappe.conf.get("saas_db_root_password") or "root")

    result = subprocess.run(
        [str(script_path), site_name, admin_password, db_root_password],
        cwd=str(_bench_root()),
        text=True,
        capture_output=True,
        env=env,
        timeout=int(frappe.conf.get("saas_provision_timeout") or 1800),
    )

    combined_log = "\n".join([result.stdout or "", result.stderr or ""]).strip()
    if result.returncode != 0:
        raise RuntimeError(combined_log or "Tenant provisioning failed")
    return combined_log


def _login_payload(row: dict) -> dict:
    tenant_domain = row["tenant_domain"]
    redirect_host = _public_redirect_host(tenant_domain)
    return {
        "ok": True,
        "action": "login",
        "tenant_domain": tenant_domain,
        "site_name": row["site_name"],
        "redirect_url": f"http://{redirect_host}:8000/#login",
        "status": row["status"],
    }


def _require_row(row: dict | None, message: str) -> dict:
    if row is None:
        frappe.throw(_(message))
        raise RuntimeError(message)
    return row


@frappe.whitelist(allow_guest=True, methods=["POST"])
def resolve_tenant(email: str):
    _ensure_registry_table()
    normalized_email = _normalize_email(email)
    if not normalized_email:
        frappe.throw(_("Email is required"))

    row = _get_registry_row_by_email(normalized_email)
    if not row:
        return {"ok": True, "found": False}

    if row.get("status") != "active":
        if _site_exists(row["site_name"]):
            _upsert_registry(
                owner_email=row["owner_email"],
                company_slug=row["company_slug"],
                site_name=row["site_name"],
                tenant_domain=row["tenant_domain"],
                status="active",
                log_text="Recovered by resolve_tenant: site already existed",
            )
            row = _require_row(
                _get_registry_row_by_email(normalized_email),
                "Tenant recovery failed",
            )
        else:
            return {"ok": True, "found": False, "status": row.get("status")}

    _ensure_nip_io_site_alias(row["site_name"])

    payload = _login_payload(row)
    payload["found"] = True
    return payload


@frappe.whitelist(allow_guest=True, methods=["POST"])
def create_or_login(email: str, full_name: str | None = None, company_slug: str | None = None, password: str | None = None):
    _ensure_registry_table()

    normalized_email = _normalize_email(email)
    if not normalized_email:
        frappe.throw(_("Email is required"))

    existing_by_email = _get_registry_row_by_email(normalized_email)
    if existing_by_email:
        if existing_by_email.get("status") == "active":
            _ensure_nip_io_site_alias(existing_by_email["site_name"])
            payload = _login_payload(existing_by_email)
            payload["message"] = _("Existing tenant found")
            return payload

        # Reconcile interrupted/failed provisioning when site already exists.
        if _site_exists(existing_by_email["site_name"]):
            _upsert_registry(
                owner_email=existing_by_email["owner_email"],
                company_slug=existing_by_email["company_slug"],
                site_name=existing_by_email["site_name"],
                tenant_domain=existing_by_email["tenant_domain"],
                status="active",
                log_text="Recovered by reconciliation: site already existed",
            )
            recovered_row = _require_row(
                _get_registry_row_by_email(normalized_email),
                "Tenant recovery failed",
            )
            _ensure_nip_io_site_alias(recovered_row["site_name"])
            payload = _login_payload(recovered_row)
            payload["message"] = _("Existing tenant recovered")
            return payload

    if not full_name or not company_slug or not password:
        frappe.throw(_("full_name, company_slug and password are required for first-time signup"))

    assert company_slug is not None
    assert password is not None

    slug = _normalize_slug(company_slug)
    slug_owner = _get_registry_row_by_slug(slug)
    if slug_owner and slug_owner.get("owner_email") != normalized_email:
        frappe.throw(_("Company slug already in use"))

    tenant_domain = _build_tenant_domain(slug)
    site_name = tenant_domain

    _upsert_registry(
        owner_email=normalized_email,
        company_slug=slug,
        site_name=site_name,
        tenant_domain=tenant_domain,
        status="provisioning",
        log_text="Provisioning started",
    )

    try:
        provisioning_log = _run_provisioning(site_name=site_name, admin_password=password)
    except Exception as exc:
        if _site_exists(site_name):
            _upsert_registry(
                owner_email=normalized_email,
                company_slug=slug,
                site_name=site_name,
                tenant_domain=tenant_domain,
                status="active",
                log_text=f"Recovered after provision error: {exc}",
            )
            row = _require_row(
                _get_registry_row_by_email(normalized_email),
                "Tenant recovery failed",
            )
            payload = _login_payload(row)
            payload["action"] = "signup"
            payload["message"] = _("Tenant created with reconciliation")
            return payload

        _upsert_registry(
            owner_email=normalized_email,
            company_slug=slug,
            site_name=site_name,
            tenant_domain=tenant_domain,
            status="failed",
            log_text=str(exc),
        )
        frappe.throw(_("Tenant provisioning failed"))

    _upsert_registry(
        owner_email=normalized_email,
        company_slug=slug,
        site_name=site_name,
        tenant_domain=tenant_domain,
        status="active",
        log_text=provisioning_log,
    )

    _ensure_nip_io_site_alias(site_name)

    row = _require_row(
        _get_registry_row_by_email(normalized_email),
        "Tenant provisioning finished but registry lookup failed",
    )
    payload = _login_payload(row)
    payload["action"] = "signup"
    payload["message"] = _("Tenant created")
    return payload