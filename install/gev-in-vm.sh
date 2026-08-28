#!/usr/bin/env bash
# ============================================================================
# God's Eye View – In-VM-Installer
#
# Wird beim ersten Boot der VM über cloud-init ausgeführt (siehe
# install/gods-eye-view.sh). Danach beliebig oft re-launchbar = Update:
#   qm guest exec <VMID> -- bash /usr/local/sbin/gev-in-vm.sh
#
# Macht aus einem frischen Debian 12: Node.js 24 (NodeSource) → App-Repo
# (bilawalsidhu/gods-eye-view) → .env mit Keys → npm ci → systemd-Service
# an 0.0.0.0:${GEV_PORT} → Selbstverifikation (Service + HTTP).
# ============================================================================

CONFIG_FILE="${CONFIG_FILE:-/root/gev-install.env}"
LOGFILE="${LOGFILE:-/var/log/gods-eye-view-installer.log}"

set -Eeuo pipefail
exec > >(tee -a "$LOGFILE") 2>&1

on_error() {
  local exit_code=$1 line=$2 command_=${3:-}
  echo
  echo "======================================================================" >&2
  echo "FEHLER: In-VM-Installation abgebrochen" >&2
  echo "  Exit-Code : $exit_code" >&2
  echo "  Zeile     : $line" >&2
  echo "  Befehl    : $command_" >&2
  if [[ ${#FUNCNAME[@]} -gt 1 ]]; then
    echo "  Aufrufkette:" >&2
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      echo "    - ${FUNCNAME[i]} (${BASH_SOURCE[i]:-?}:${BASH_LINENO[i - 1]:-?})" >&2
    done
  fi
  echo "--- Letzte 40 Logzeilen ($LOGFILE) ---" >&2
  tail -n 40 "$LOGFILE" >&2 || true
  echo "----------------------------------------------------------------------" >&2
  echo "Vollständiges Log : $LOGFILE" >&2
  echo "Dienst-Logs       : journalctl -u gods-eye-view -n 100 --no-pager" >&2
  echo "Mit Shell-Trace   : CONFIG_FILE=$CONFIG_FILE bash -x /usr/local/sbin/gev-in-vm.sh" >&2
  echo "======================================================================" >&2
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

info() { echo -e "\e[1;32m➤\e[0m $*"; }
warn() { echo -e "\e[1;33m⚠\e[0m $*"; }
ok()   { echo -e "\e[1;32m✔\e[0m $*"; }
die()  { echo -e "\e[1;31m✗\e[0m $*" >&2; exit "${2:-1}"; }

# ---------------------------------------------------------------------------
# Konfiguration laden (von cloud-init geschrieben) + Defaults
# ---------------------------------------------------------------------------
if [[ -f $CONFIG_FILE ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set +a
else
  warn "Konfigurationsdatei $CONFIG_FILE nicht gefunden – verwende Defaults."
fi

: "${GEV_PORT:=4173}"
: "${GEV_REPO_URL:=https://github.com/bilawalsidhu/gods-eye-view}"
: "${GEV_BRANCH:=main}"
: "${NODE_MAJOR:=24}"
: "${GEV_DIR:=/opt/gods-eye-view}"
: "${GEV_USER:=gev}"
: "${APP_REPO_RAW:=https://raw.githubusercontent.com/HatchetMan111/GodsEyeViewerProxmox/main}"

[[ $(id -u) -eq 0 ]] || die "Bitte als root ausführen."

# ---------------------------------------------------------------------------
# 1. Systempakete
# ---------------------------------------------------------------------------
info "Aktualisiere Paketquellen und installiere Basis-Abhängigkeiten…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl git python3 make g++ libatomic1 xz-utils >/dev/null

# ---------------------------------------------------------------------------
# 2. Node.js (App verlangt >=24.14 <25 || >=26 <27) via NodeSource
# ---------------------------------------------------------------------------
node_version_ok() {
  local v
  v="$(node -v 2>/dev/null | sed 's/^v//' || true)"
  [[ $v =~ ^(24\.(1[4-9]|[2-9][0-9]+)|2[6-9]\.) ]]
}

if command -v node >/dev/null 2>&1 && node_version_ok; then
  info "Node.js $(node -v) bereits installiert – überspringe NodeSource-Setup."
else
  info "Installiere Node.js ${NODE_MAJOR}.x über NodeSource…"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi

NODE_V="$(node -v 2>/dev/null || true)"
node_version_ok \
  || die "Node-Version '$NODE_V' erfüllt die Anforderung der App (>=24.14 <25 || >=26 <27) nicht. Mit NODE_MAJOR=26 erneut versuchen."
npm -v >/dev/null 2>&1 || die "npm nicht gefunden nach Node-Installation."
ok "Node.js $NODE_V / npm $(npm -v) bereit."

# ---------------------------------------------------------------------------
# 3. Systembenutzer für den Service
# ---------------------------------------------------------------------------
if ! id -u "$GEV_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "/home/${GEV_USER}" \
    --shell /usr/sbin/nologin "$GEV_USER"
  info "Systembenutzer '$GEV_USER' angelegt."
fi

# ---------------------------------------------------------------------------
# 4. App-Repo klonen oder aktualisieren (idempotent)
# ---------------------------------------------------------------------------
if [[ -d $GEV_DIR/.git ]]; then
  info "Repo existiert – aktualisiere auf origin/${GEV_BRANCH}…"
  git -C "$GEV_DIR" fetch --all --prune
  git -C "$GEV_DIR" reset --hard "origin/${GEV_BRANCH}"
else
  info "Klone ${GEV_REPO_URL} (Branch ${GEV_BRANCH}) nach ${GEV_DIR}…"
  rm -rf "$GEV_DIR"
  git clone --depth 1 --branch "$GEV_BRANCH" "$GEV_REPO_URL" "$GEV_DIR"
fi

# ---------------------------------------------------------------------------
# 5. .env schreiben (beibehaltene Keys = idempotent, Host/Port erzwingen)
# ---------------------------------------------------------------------------
set_env_kv() { # set_env_kv <key> <value> – bestehenden Eintrag ersetzen oder anhängen
  local key=$1 value=$2 esc
  esc=${value//\\/\\\\}
  esc=${esc//&/\\&}
  if grep -qE "^${key}=" "$GEV_DIR/.env" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${esc}|" "$GEV_DIR/.env"
  else
    printf '%s=%s\n' "$key" "$value" >> "$GEV_DIR/.env"
  fi
}

if [[ ! -f $GEV_DIR/.env ]]; then
  if [[ -f $GEV_DIR/.env.example ]]; then
    cp "$GEV_DIR/.env.example" "$GEV_DIR/.env"
  else
    touch "$GEV_DIR/.env"
  fi
fi
touch "$GEV_DIR/.env"
info "Schreibe Konfiguration in ${GEV_DIR}/.env…"
set_env_kv HOST 0.0.0.0
set_env_kv PORT "$GEV_PORT"
if [[ -n ${GOOGLE_MAPS_API_KEY:-} ]]; then set_env_kv GOOGLE_MAPS_API_KEY "$GOOGLE_MAPS_API_KEY"; fi
if [[ -n ${CESIUM_ION_TOKEN:-} ]]; then set_env_kv CESIUM_ION_TOKEN "$CESIUM_ION_TOKEN"; fi
if [[ -n ${OPENAI_API_KEY:-} ]]; then set_env_kv OPENAI_API_KEY "$OPENAI_API_KEY"; fi
if [[ -n ${AISSTREAM_API_KEY:-} ]]; then set_env_kv AISSTREAM_API_KEY "$AISSTREAM_API_KEY"; fi
if [[ -n ${FIRMS_MAP_KEY:-} ]]; then set_env_kv FIRMS_MAP_KEY "$FIRMS_MAP_KEY"; fi
if [[ -n ${TOMTOM_API_KEY:-} ]]; then set_env_kv TOMTOM_API_KEY "$TOMTOM_API_KEY"; fi
if [[ -n ${OPENSKY_AUTH_MODE:-} ]]; then
  set_env_kv OPENSKY_AUTH_MODE "$OPENSKY_AUTH_MODE"
elif [[ -n ${OPENSKY_CLIENT_ID:-} ]]; then
  set_env_kv OPENSKY_AUTH_MODE oauth
else
  set_env_kv OPENSKY_AUTH_MODE anon
fi
if [[ -n ${OPENSKY_CLIENT_ID:-} ]]; then set_env_kv OPENSKY_CLIENT_ID "$OPENSKY_CLIENT_ID"; fi
if [[ -n ${OPENSKY_CLIENT_SECRET:-} ]]; then set_env_kv OPENSKY_CLIENT_SECRET "$OPENSKY_CLIENT_SECRET"; fi
if [[ -n ${GEV_RATELIMIT_GOOGLE_PER_MIN:-} ]]; then set_env_kv GEV_RATELIMIT_GOOGLE_PER_MIN "$GEV_RATELIMIT_GOOGLE_PER_MIN"; fi
if [[ -n ${GEV_RATELIMIT_OPENAI_PER_MIN:-} ]]; then set_env_kv GEV_RATELIMIT_OPENAI_PER_MIN "$GEV_RATELIMIT_OPENAI_PER_MIN"; fi
chmod 600 "$GEV_DIR/.env"

if [[ -z ${GOOGLE_MAPS_API_KEY:-} ]] && ! grep -q '^GOOGLE_MAPS_API_KEY=.\+' "$GEV_DIR/.env"; then
  warn "GOOGLE_MAPS_API_KEY fehlt – der photorealistische 3D-Globe wird nicht laden!"
  warn "Key besorgen (Google Cloud, Map Tiles API) und in ${GEV_DIR}/.env eintragen, dann: systemctl restart gods-eye-view"
fi

# ---------------------------------------------------------------------------
# 6. npm ci (Puppeteer-Download überspringen – im VM-Server nicht nötig)
# ---------------------------------------------------------------------------
info "Installiere npm-Abhängigkeiten (npm ci, dauert einige Minuten)…"
cd "$GEV_DIR"
export PUPPETEER_SKIP_DOWNLOAD=true
export PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
npm ci --no-audit --no-fund \
  || npm ci --no-audit --no-fund --loglevel verbose

# ---------------------------------------------------------------------------
# 7. systemd-Unit aktivieren (Datei kommt per cloud-init aus dem Repo)
# ---------------------------------------------------------------------------
info "Aktiviere systemd-Service…"
chown -R "${GEV_USER}:${GEV_USER}" "$GEV_DIR"
systemctl daemon-reload
systemctl enable gods-eye-view >/dev/null
systemctl restart gods-eye-view

# ---------------------------------------------------------------------------
# 8. Firewall (falls aktiv): Port freigeben
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${GEV_PORT}/tcp" >/dev/null
  ok "ufw: Port ${GEV_PORT}/tcp freigegeben."
fi

# ---------------------------------------------------------------------------
# 9. Verifikation: Service + HTTP
# ---------------------------------------------------------------------------
info "Prüfe Service…"
elapsed=0
until [[ $(systemctl is-active gods-eye-view) == active ]]; do
  if (( elapsed >= 60 )); then
    journalctl -u gods-eye-view -n 40 --no-pager || true
    die "Service gods-eye-view wurde nicht 'active'."
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
ok "Service gods-eye-view: active ($(systemctl is-enabled gods-eye-view), Boot-autostart aktiv)."

info "Prüfe HTTP auf localhost:${GEV_PORT}…"
elapsed=0
until curl -fsS -o /dev/null -m 5 "http://localhost:${GEV_PORT}/" 2>/dev/null; do
  if (( elapsed >= 120 )); then
    journalctl -u gods-eye-view -n 40 --no-pager || true
    die "HTTP-Check auf localhost:${GEV_PORT} fehlgeschlagen."
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
ok "HTTP 200 auf localhost:${GEV_PORT}."

LOCAL_IP="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[2]; exit}')"
ok "Installiert: ${GEV_DIR} (Branch ${GEV_BRANCH}) · User ${GEV_USER} · Port ${GEV_PORT}"
ok "Lokal erreichbar unter: http://${LOCAL_IP:-<VM-IP>}:${GEV_PORT}"
