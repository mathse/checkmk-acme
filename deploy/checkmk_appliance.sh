#!/usr/bin/env sh

# acme.sh deploy hook for Checkmk Appliance / Webconf certificates.
#
# File:
#   /root/.acme.sh/deploy/checkmk_appliance.sh
#
# Hook name:
#   checkmk_appliance
#
# acme.sh calls:
#   checkmk_appliance_deploy <domain> <keyfile> <certfile> <cafile> <fullchain>
#
# Optional environment variables:
#   CHECKMK_APPLIANCE_STRICT_SYNC=1
#       Default: 1
#       If 1, the final cluster sync must succeed or the deploy hook returns non-zero.
#       If 0, cluster sync errors are handled like Webconf's best-effort sync.
#
#   CHECKMK_APPLIANCE_BACKUP_DIR=/root/.acme.sh/checkmk_appliance_backups
#       Backup directory for previous appliance TLS files.
#
#   CHECKMK_APPLIANCE_ALLOW_NO_CHAIN=0
#       Default: 0
#       If 1, deployment is allowed even when no CA chain can be found.
#
#   CHECKMK_APPLIANCE_DRY_RUN=0
#       Default: 0
#       If 1, only validates/parses and prints what would be done.

if ! command -v _info >/dev/null 2>&1; then
  _info() { printf '%s\n' "$*"; }
fi

if ! command -v _err >/dev/null 2>&1; then
  _err() { printf '%s\n' "$*" >&2; }
fi

checkmk_appliance_deploy() {
  _cdomain="$1"
  _ckey="$2"
  _ccert="$3"
  _cca="$4"
  _cfullchain="$5"

  _info "Deploying certificate to Checkmk Appliance Webconf for domain: $_cdomain"

  if [ "$(id -u)" != "0" ]; then
    _err "This deploy hook must run as root."
    return 1
  fi

  if [ -z "$_ckey" ] || [ ! -r "$_ckey" ]; then
    _err "Private key file is missing or not readable: $_ckey"
    return 1
  fi

  if [ -z "$_ccert" ] || [ ! -r "$_ccert" ]; then
    _err "Certificate file is missing or not readable: $_ccert"
    return 1
  fi

  if [ -n "$_cca" ] && [ ! -r "$_cca" ]; then
    _err "CA chain file was given but is not readable: $_cca"
    return 1
  fi

  if [ -n "$_cfullchain" ] && [ ! -r "$_cfullchain" ]; then
    _err "Fullchain file was given but is not readable: $_cfullchain"
    return 1
  fi

  python3 - "$_cdomain" "$_ckey" "$_ccert" "$_cca" "$_cfullchain" <<'PY'
import os
import shutil
import sys
import time
from pathlib import Path

domain, key_path, cert_path, ca_path, fullchain_path = sys.argv[1:6]

strict_sync = os.environ.get("CHECKMK_APPLIANCE_STRICT_SYNC", "1").lower() not in (
    "0",
    "false",
    "no",
)
dry_run = os.environ.get("CHECKMK_APPLIANCE_DRY_RUN", "0").lower() in (
    "1",
    "true",
    "yes",
)
allow_no_chain = os.environ.get("CHECKMK_APPLIANCE_ALLOW_NO_CHAIN", "0").lower() in (
    "1",
    "true",
    "yes",
)
backup_root = Path(
    os.environ.get(
        "CHECKMK_APPLIANCE_BACKUP_DIR",
        "/root/.acme.sh/checkmk_appliance_backups",
    )
)

def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

def info(msg: str) -> None:
    print(msg)

def read_text_file(path: str, label: str, required: bool = True) -> str:
    if not path:
        if required:
            fail(f"{label} path is empty")
        return ""

    p = Path(path)
    if not p.exists():
        if required:
            fail(f"{label} does not exist: {path}")
        return ""

    if not p.is_file():
        if required:
            fail(f"{label} is not a regular file: {path}")
        return ""

    try:
        data = p.read_text(encoding="ascii")
    except UnicodeDecodeError:
        fail(f"{label} is not ASCII/PEM text: {path}")
    except OSError as exc:
        fail(f"Cannot read {label} {path}: {exc}")

    if required and "-----BEGIN" not in data:
        fail(f"{label} does not look like PEM data: {path}")

    return data

def safe_domain_name(value: str) -> str:
    return "".join(c if c.isalnum() or c in "._-" else "_" for c in value)

try:
    import cma
    from cma.config import load_config
    from cma.crypto import (
        Certificate,
        CertificatePEM,
        PlaintextPrivateKeyPEM,
        PrivateKey,
        load_multiple_certificates,
    )
    from cma.hooks import execute_hooks
    from webconf.cluster import sync_files
    from webconf.pages.web_access import (
        delete_certificate_chain,
        save_certificate,
        save_certificate_chain,
        save_private_key,
        verify_key_and_certificate_match,
    )
except Exception as exc:
    fail(f"Could not import Checkmk Appliance/Webconf Python modules: {exc}")

try:
    cfg = load_config()
except Exception as exc:
    fail(f"Could not load Checkmk Appliance config: {exc}")

try:
    cluster_connected = bool(cma.is_cluster_connected())
except Exception:
    cluster_connected = False

try:
    cluster_master = bool(cma.master_node(cfg)) if cluster_connected else False
except Exception as exc:
    fail(f"Could not determine Checkmk Appliance cluster master state: {exc}")

if cluster_connected and not cluster_master:
    info("Cluster is connected and this node is not the active/master node. Nothing to do.")
    sys.exit(0)

key_pem = read_text_file(key_path, "private key", required=True)
cert_pem = read_text_file(cert_path, "certificate", required=True)
ca_pem = read_text_file(ca_path, "CA chain", required=False)
fullchain_pem = read_text_file(fullchain_path, "fullchain", required=False)

try:
    key = PrivateKey.load_pem(PlaintextPrivateKeyPEM(key_pem))
except Exception as exc:
    fail(f"Could not parse private key: {exc}")

try:
    cert = Certificate.load_pem(CertificatePEM(cert_pem))
except Exception as exc:
    fail(f"Could not parse certificate: {exc}")

try:
    verify_key_and_certificate_match(key, cert)
except Exception as exc:
    fail(f"Private key does not match certificate: {exc}")

chain = None
chain_source = None

if ca_pem.strip():
    try:
        chain = load_multiple_certificates(CertificatePEM(ca_pem))
        chain_source = "cafile"
    except Exception as exc:
        fail(f"Could not parse CA chain file: {exc}")

elif fullchain_pem.strip():
    try:
        fullchain_certs = load_multiple_certificates(CertificatePEM(fullchain_pem))
    except Exception as exc:
        fail(f"Could not parse fullchain file: {exc}")

    if len(fullchain_certs) > 1:
        # acme.sh fullchain is normally leaf cert + intermediate chain.
        # The leaf cert is stored separately by Webconf, so only store the rest as chain.
        chain = fullchain_certs[1:]
        chain_source = "fullchain-minus-leaf"

if chain is not None and len(chain) == 0:
    chain = None

if chain is None and not allow_no_chain:
    fail(
        "No CA chain found. acme.sh should normally provide cafile. "
        "Set CHECKMK_APPLIANCE_ALLOW_NO_CHAIN=1 only if you really want this."
    )

paths_to_backup = [
    getattr(cma, "ssl_private_key_path", None),
    getattr(cma, "ssl_certificate_path", None),
    getattr(cma, "ssl_chain_path", None),
]

existing_paths = [Path(p) for p in paths_to_backup if p and Path(p).exists()]

if existing_paths and not dry_run:
    backup_dir = backup_root / f"{safe_domain_name(domain)}-{time.strftime('%Y%m%d-%H%M%S')}"
    backup_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(backup_dir, 0o700)

    for src in existing_paths:
        shutil.copy2(src, backup_dir / src.name)

    info(f"Backed up previous appliance TLS files to: {backup_dir}")

info(f"Checkmk appliance private key path: {getattr(cma, 'ssl_private_key_path', '<unknown>')}")
info(f"Checkmk appliance certificate path: {getattr(cma, 'ssl_certificate_path', '<unknown>')}")
info(f"Checkmk appliance chain path: {getattr(cma, 'ssl_chain_path', '<unknown>')}")

if dry_run:
    info("Dry run enabled. Parsed key/certificate successfully; no files changed.")
    if cluster_connected:
        info(f"Cluster connected. This node is active/master: {cluster_master}")
    else:
        info("Cluster not connected or standalone mode detected.")
    sys.exit(0)

try:
    save_private_key(key)
    save_certificate(cert)

    if chain is not None:
        save_certificate_chain(chain)
        info(f"Saved certificate chain from: {chain_source}")
    else:
        delete_certificate_chain()
        info("No certificate chain stored.")
except Exception as exc:
    fail(f"Could not save certificate/key/chain via Webconf functions: {exc}")

def do_cluster_sync(label: str, catch: bool) -> None:
    if not cluster_connected or not cluster_master:
        return

    info(f"Synchronizing Checkmk Appliance files to cluster partner: {label}")

    try:
        sync_files(cfg, catch=catch)
    except Exception as exc:
        fail(f"Cluster file sync failed during {label}: {exc}")

# GUI upload path syncs once before activation and then again after hook execution.
# First sync is best-effort, so the local activation is not blocked by a temporarily
# unavailable partner.
do_cluster_sync("before ssl_certs hook", catch=True)

try:
    execute_hooks(cfg, ["ssl_certs"])
except Exception as exc:
    fail(f"Checkmk Appliance ssl_certs hook failed: {exc}")

# Final sync is strict by default, so acme.sh reports a failed deployment if the
# partner did not receive the updated TLS files.
do_cluster_sync("after ssl_certs hook", catch=not strict_sync)

info("Checkmk Appliance Webconf certificate deployment finished successfully.")
sys.exit(0)
PY
}

