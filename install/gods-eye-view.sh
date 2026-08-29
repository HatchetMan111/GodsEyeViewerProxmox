#!/usr/bin/env bash
# ============================================================================
# God's Eye View – VM für Proxmox VE – Ein-Zeiler-Installer (Community-Scripts-Stil)
#
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GodsEyeViewerProxmox/main/install/gods-eye-view.sh)"
#
# Erstellt eine Debian-12-Cloud-VM und installiert darin God's Eye View
# (https://github.com/bilawalsidhu/gods-eye-view) – die 3D-Globe-Intelligence-
# Konsole mit Live-Flugzeugen, Schiffen, Satelliten, CCTV und Sprachsteuerung.
#
# Ablauf: Cloud-Image laden (SHA512-verifiziert) → VM via qm anlegen →
# cloud-init (cidata-ISO) provisioniert die VM beim ersten Boot → Node.js 24,
# App, systemd-Service → Script wartet auf die VM-IP und verifiziert
# Service + HTTP. Am Ende steht die URL, unter der die Web-UI lokal erreichbar ist.
#
# Alle Einstellungen per Umgebungsvariable überschreibbar, z. B.:
#   VMID=140 GOOGLE_MAPS_API_KEY='AIza...' bash -c "$(wget -qLO - https://...)"
#
# Debugging bei Fehlern:
#   - Komplettes Log (Host):       /var/log/gods-eye-view-pve-installer.log
#   - Log in der VM:               /var/log/gods-eye-view-installer.log
#   - Mit Shell-Trace ausführen:   bash -x <(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GodsEyeViewerProxmox/main/install/gods-eye-view.sh)
# ============================================================================

# ---------------------------------------------------------------------------
# Konfiguration (per Env überschreibbar)
# ---------------------------------------------------------------------------
if [[ -z ${VMID:-} ]]; then
  VMID=130
  VMID_EXPLICIT=false
else
  VMID_EXPLICIT=true
fi
VM_NAME="${VM_NAME:-gods-eye-view}"
CORES="${CORES:-4}"
MEMORY_MB="${MEMORY_MB:-8192}"
DISK_GB="${DISK_GB:-32}"
CPU_TYPE="${CPU_TYPE:-host}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
VLAN="${VLAN:-}"
PVE_FIREWALL="${PVE_FIREWALL:-0}"        # 0 = kein Proxmox-Firewall-Tag an der NIC (Port frei)
ONBOOT="${ONBOOT:-1}"
RECREATE="${RECREATE:-false}"

TIMEZONE="${TIMEZONE:-Europe/Berlin}"
GEV_PORT="${GEV_PORT:-4173}"
GEV_REPO_URL="${GEV_REPO_URL:-https://github.com/bilawalsidhu/gods-eye-view}"
GEV_BRANCH="${GEV_BRANCH:-main}"
NODE_MAJOR="${NODE_MAJOR:-24}"           # App verlangt >=24.14 <25 oder >=26 <27

# Zugangsdaten zur VM (root per SSH/Konsole)
PASSWORD_PLAIN="${PASSWORD_PLAIN:-gods-eye-view}"   # nach Erstlogin ändern!
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"

# Optionale statische IP (leer = DHCP): z. B. NET_CIDR='192.168.1.60/24' NET_GATEWAY='192.168.1.1'
NET_CIDR="${NET_CIDR:-}"
NET_GATEWAY="${NET_GATEWAY:-}"

# API-Keys für die App (werden nach /root/gev-install.env in der VM geschrieben)
GOOGLE_MAPS_API_KEY="${GOOGLE_MAPS_API_KEY:-}"
CESIUM_ION_TOKEN="${CESIUM_ION_TOKEN:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
AISSTREAM_API_KEY="${AISSTREAM_API_KEY:-}"
FIRMS_MAP_KEY="${FIRMS_MAP_KEY:-}"
TOMTOM_API_KEY="${TOMTOM_API_KEY:-}"
OPENSKY_AUTH_MODE="${OPENSKY_AUTH_MODE:-}"
OPENSKY_CLIENT_ID="${OPENSKY_CLIENT_ID:-}"
OPENSKY_CLIENT_SECRET="${OPENSKY_CLIENT_SECRET:-}"
GEV_RATELIMIT_GOOGLE_PER_MIN="${GEV_RATELIMIT_GOOGLE_PER_MIN:-}"
GEV_RATELIMIT_OPENAI_PER_MIN="${GEV_RATELIMIT_OPENAI_PER_MIN:-}"

DEBIAN_IMAGE_URL="${DEBIAN_IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
DEBIAN_IMAGE_SHA512SUMS="${DEBIAN_IMAGE_SHA512SUMS:-https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS}"
REPO_RAW="https://raw.githubusercontent.com/HatchetMan111/GodsEyeViewerProxmox/main"

LOGFILE="/var/log/gods-eye-view-pve-installer.log"
WORKDIR="$(mktemp -d /tmp/gods-eye-view-vm.XXXXXX)"

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Logging + Fehlerbehandlung: komplette Fehlermeldungskette statt letzter Zeile
# ---------------------------------------------------------------------------
touch "$LOGFILE" 2>/dev/null || LOGFILE="$WORKDIR/installer.log"
exec > >(tee -a "$LOGFILE") 2>&1

on_error() {
  local exit_code=$1 line=$2 command_=${3:-}
  echo
  echo "======================================================================" >&2
  echo "FEHLER: Installation abgebrochen" >&2
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
  echo "Vollständiges Log (Host) : $LOGFILE" >&2
  echo "Log in der VM            : /var/log/gods-eye-view-installer.log  (qm guest exec $VMID -- tail -50 /var/log/gods-eye-view-installer.log)" >&2
  echo "Dienst-Logs in der VM    : qm guest exec $VMID -- journalctl -u gods-eye-view -n 100 --no-pager" >&2
  echo "Mit Shell-Trace          : bash -x <(wget -qLO - $REPO_RAW/install/gods-eye-view.sh)" >&2
  echo "Erneut versuchen         : denselben Befehl einfach nochmal ausführen (idempotent)" >&2
  echo "======================================================================" >&2
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

info() { echo -e "\e[1;32m➤\e[0m $*"; }
warn() { echo -e "\e[1;33m⚠\e[0m $*"; }
ok()   { echo -e "\e[1;32m✔\e[0m $*"; }
die()  { echo -e "\e[1;31m✗\e[0m $*" >&2; exit "${2:-1}"; }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Hilfsfunktion: IP einer VM über qemu-guest-agent ermitteln
# ---------------------------------------------------------------------------
vm_ip_of() {
  local vmid=$1
  qm guest cmd "$vmid" network-get-interfaces 2>/dev/null | python3 -c '
import json, sys
try:
    ifs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for iface in ifs:
    for addr in iface.get("ip-addresses", []):
        ip = addr.get("ip-address", "")
        if addr.get("ip-address-type") == "ipv4" and ip and not ip.startswith("127.") and not ip.startswith("169.254."):
            print(ip)
            sys.exit(0)
' || true
}

print_banner() {
  local ip=$1
  echo
  echo "======================================================================"
  echo -e "\e[1;32m  🌍 God's Eye View ist installiert und läuft!\e[0m"
  echo "======================================================================"
  echo "  Web-UI (lokal)   : http://${ip}:${GEV_PORT}"
  echo "  Optional Alias   : auf deinem Client  echo \"${ip}  gods-eye-view.local\" >> /etc/hosts"
  echo "                     → http://gods-eye-view.local:${GEV_PORT}"
  echo "  VM               : ID ${VMID} · ${CORES} vCPU · ${MEMORY_MB} MB RAM · ${DISK_GB} GB Disk · ${STORAGE}"
  echo "  SSH              : ssh root@${ip}  (Passwort: \$PASSWORD_PLAIN oder SSH-Key)"
  echo "  App-Logs (in VM) : journalctl -u gods-eye-view -f"
  echo "  Install-Log (VM) : /var/log/gods-eye-view-installer.log"
  echo "  Host-Log         : ${LOGFILE}"
  [[ -n $GOOGLE_MAPS_API_KEY ]] || echo -e "\e[1;33m  ⚠ Ohne GOOGLE_MAPS_API_KEY lädt der 3D-Globe nicht – Key nachtragen:\e[0m"
  [[ -n $GOOGLE_MAPS_API_KEY ]] || echo "     Key in /opt/gods-eye-view/.env setzen, dann: systemctl restart gods-eye-view"
  echo "======================================================================"
}

# ---------------------------------------------------------------------------
# Voraussetzungen prüfen
# ---------------------------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "Bitte als root ausführen (Proxmox-Host)."
command -v qm >/dev/null 2>&1 || die "'qm' nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || die "Weder 'wget' noch 'curl' gefunden."
command -v python3 >/dev/null 2>&1 || die "'python3' nicht gefunden (auf PVE-Hosten Standard)."
command -v qemu-img >/dev/null 2>&1 || die "'qemu-img' nicht gefunden (Bestandteil von pve-qemu-kvm)."

pvesm status >/dev/null 2>&1 || die "Storage-Status nicht abrufbar (pvesm status fehlgeschlagen)."
pvesm status | awk '{print $1}' | grep -qx "$STORAGE" || die "Storage '$STORAGE' existiert nicht. Verfügbare Storages: $(pvesm status | awk 'NR>1{printf "%s ", $1}')"
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
  die "Bridge '$BRIDGE' nicht gefunden. Vorhandene Bridges: $(ls /sys/class/net | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# VMID-Auflösung: explizite ID respektieren, sonst automatisch frei wählen
# ---------------------------------------------------------------------------
vmid_in_use() { qm status "$1" >/dev/null 2>&1 || pct status "$1" >/dev/null 2>&1; }

existing_gev_vm() {
  qm list 2>/dev/null | awk -v n="$(printf '%s' "$VM_NAME" | tr '[:upper:]' '[:lower:]')" \
    'NR > 1 && tolower($2) == n {print $1}' | head -n1
}

resolve_vmid() {
  if [[ $VMID_EXPLICIT == true ]]; then
    if pct status "$VMID" >/dev/null 2>&1; then
      die "ID $VMID ist bereits ein LXC-CONTAINER. Container werden nie automatisch angetastet – bitte andere ID wählen."
    fi
    return
  fi
  while qm status "$VMID" >/dev/null 2>&1 || pct status "$VMID" >/dev/null 2>&1; do
    VMID=$((VMID + 1))
  done
}

destroy_vm() {
  warn "VM $1 ($VM_NAME) existiert bereits – RECREATE=true: stoppe und lösche sie…"
  qm shutdown "$1" --timeout 60 --forceStop 1 >/dev/null 2>&1 || true
  qm wait "$1" --timeout 60 2>/dev/null || true
  qm destroy "$1" --purge
  info "Alte VM $1 gelöscht."
}

# ---------------------------------------------------------------------------
# Idempotenz: existierende VM → nur Status + URL anzeigen
# ---------------------------------------------------------------------------
EXISTING_VMID="$(existing_gev_vm || true)"
if [[ -n $EXISTING_VMID && $RECREATE != true ]]; then
  info "VM '$VM_NAME' existiert bereits als VM-ID $EXISTING_VMID – nichts zu tun (idempotent)."
  qm config "$EXISTING_VMID" | grep -E '^(name|cores|memory|onboot):' || true
  VM_IP="$(vm_ip_of "$EXISTING_VMID" 2>/dev/null || true)"
  if [[ -n $VM_IP ]]; then
    print_banner "$VM_IP"
  else
    warn "Keine IP ermittelbar (qemu-guest-agent noch nicht bereit oder VM aus?)."
    warn "VM starten: qm start $EXISTING_VMID"
  fi
  exit 0
fi
if [[ -n $EXISTING_VMID && $RECREATE == true ]]; then
  destroy_vm "$EXISTING_VMID"
fi

resolve_vmid
if qm status "$VMID" >/dev/null 2>&1; then
  if [[ $RECREATE == true ]]; then destroy_vm "$VMID"; else
    die "VM-ID $VMID ist bereits belegt – bitte andere VMID wählen oder RECREATE=true setzen."
  fi
fi
info "Verwende VM-ID: $VMID"

# ---------------------------------------------------------------------------
# Cloud-Image laden + SHA512 verifizieren (idempotent: Cache wiederverwenden)
# ---------------------------------------------------------------------------
IMG_NAME="$(basename "$DEBIAN_IMAGE_URL")"

fetch() { # fetch <url> <zielpfad>
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    curl -fsSL -o "$2" "$1"
  fi
}

if [[ -s $WORKDIR/$IMG_NAME ]]; then
  info "Cloud-Image bereits vorhanden, überspringe Download."
else
  info "Lade Debian-12-Cloud-Image (~350 MB)…"
  fetch "$DEBIAN_IMAGE_URL" "$WORKDIR/$IMG_NAME"
  info "Verifiziere SHA512-Signatur…"
  fetch "$DEBIAN_IMAGE_SHA512SUMS" "$WORKDIR/SHA512SUMS"
  (cd "$WORKDIR" && grep " ${IMG_NAME}\$" SHA512SUMS | sha512sum -c -) \
    || die "SHA512-Prüfung des Cloud-Images fehlgeschlagen – Download verworfen."
fi

# ---------------------------------------------------------------------------
# In-VM-Installer + systemd-Unit aus dem Repo laden (GitHub-first)
# ---------------------------------------------------------------------------
info "Lade In-VM-Installer und systemd-Unit aus dem Repo…"
fetch "$REPO_RAW/install/gev-in-vm.sh" "$WORKDIR/gev-in-vm.sh"
fetch "$REPO_RAW/install/gods-eye-view.service" "$WORKDIR/gods-eye-view.service"
chmod +x "$WORKDIR/gev-in-vm.sh"
bash -n "$WORKDIR/gev-in-vm.sh" || die "Heruntergeladener Installer enthält Syntaxfehler."

# ---------------------------------------------------------------------------
# Konfigurationsdatei für die VM bauen (wird dort nach /root/gev-install.env geschrieben)
# ---------------------------------------------------------------------------
ENV_FILE="$WORKDIR/gev-install.env"
{
  echo "GEV_PORT='$GEV_PORT'"
  echo "GEV_REPO_URL='$GEV_REPO_URL'"
  echo "GEV_BRANCH='$GEV_BRANCH'"
  echo "NODE_MAJOR='$NODE_MAJOR'"
  if [[ -n $GOOGLE_MAPS_API_KEY ]]; then echo "GOOGLE_MAPS_API_KEY='$GOOGLE_MAPS_API_KEY'"; fi
  if [[ -n $CESIUM_ION_TOKEN ]]; then echo "CESIUM_ION_TOKEN='$CESIUM_ION_TOKEN'"; fi
  if [[ -n $OPENAI_API_KEY ]]; then echo "OPENAI_API_KEY='$OPENAI_API_KEY'"; fi
  if [[ -n $AISSTREAM_API_KEY ]]; then echo "AISSTREAM_API_KEY='$AISSTREAM_API_KEY'"; fi
  if [[ -n $FIRMS_MAP_KEY ]]; then echo "FIRMS_MAP_KEY='$FIRMS_MAP_KEY'"; fi
  if [[ -n $TOMTOM_API_KEY ]]; then echo "TOMTOM_API_KEY='$TOMTOM_API_KEY'"; fi
  if [[ -n $OPENSKY_AUTH_MODE ]]; then echo "OPENSKY_AUTH_MODE='$OPENSKY_AUTH_MODE'"; fi
  if [[ -n $OPENSKY_CLIENT_ID ]]; then echo "OPENSKY_CLIENT_ID='$OPENSKY_CLIENT_ID'"; fi
  if [[ -n $OPENSKY_CLIENT_SECRET ]]; then echo "OPENSKY_CLIENT_SECRET='$OPENSKY_CLIENT_SECRET'"; fi
  if [[ -n $GEV_RATELIMIT_GOOGLE_PER_MIN ]]; then echo "GEV_RATELIMIT_GOOGLE_PER_MIN='$GEV_RATELIMIT_GOOGLE_PER_MIN'"; fi
  if [[ -n $GEV_RATELIMIT_OPENAI_PER_MIN ]]; then echo "GEV_RATELIMIT_OPENAI_PER_MIN='$GEV_RATELIMIT_OPENAI_PER_MIN'"; fi
} > "$ENV_FILE"

# ---------------------------------------------------------------------------
# cloud-init-Dateien (user-data / meta-data / network-config) erzeugen
# ---------------------------------------------------------------------------
GEV_ENV_B64="$(base64 -w0 "$ENV_FILE")"
GEV_INSTALLER_B64="$(base64 -w0 "$WORKDIR/gev-in-vm.sh")"
GEV_UNIT_B64="$(base64 -w0 "$WORKDIR/gods-eye-view.service")"

SSH_KEYS_YAML=""
if [[ -n $SSH_PUBLIC_KEY ]]; then
  while IFS= read -r key; do
    if [[ -n $key ]]; then SSH_KEYS_YAML+="  - ${key}"$'\n'; fi
  done <<< "$SSH_PUBLIC_KEY"
fi

# SSH-Key-Block: valide YAML-Variante je nach Vorhandensein einsetzen
if [[ -n $SSH_KEYS_YAML ]]; then
  SSH_KEYS_BLOCK="ssh_authorized_keys:
${SSH_KEYS_YAML}"
else
  SSH_KEYS_BLOCK="ssh_authorized_keys: []"
fi

# Passwort YAML-sicher escapen (Single Quotes verdoppeln)
PASSWORD_YAML="${PASSWORD_PLAIN//\'/\'\'}"

cat > "$WORKDIR/user-data" <<USERDATA
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
timezone: ${TIMEZONE}
package_update: true
packages:
  - qemu-guest-agent
  - curl
  - git
  - ca-certificates
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: root
      password: '${PASSWORD_YAML}'
      type: text
users:
  - name: root
    lock_passwd: false
__SSH_KEYS_BLOCK__
write_files:
  - path: /root/gev-install.env
    owner: root:root
    permissions: '0600'
    encoding: b64
    content: ${GEV_ENV_B64}
  - path: /usr/local/sbin/gev-in-vm.sh
    owner: root:root
    permissions: '0755'
    encoding: b64
    content: ${GEV_INSTALLER_B64}
  - path: /etc/systemd/system/gods-eye-view.service
    owner: root:root
    permissions: '0644'
    encoding: b64
    content: ${GEV_UNIT_B64}
runcmd:
  - systemctl enable --now qemu-guest-agent
  - bash /usr/local/sbin/gev-in-vm.sh
final_message: "God's-Eye-View-Provisionierung beendet nach \$UPTIME Sekunden."
USERDATA

# SSH-Key-Block: valide YAML-Variante je nach Vorhandensein einsetzen
if [[ -n $SSH_KEYS_YAML ]]; then
  SSH_KEYS_BLOCK="ssh_authorized_keys:
${SSH_KEYS_YAML}"
else
  SSH_KEYS_BLOCK="ssh_authorized_keys: []"
fi
SSH_KEYS_BLOCK="$SSH_KEYS_BLOCK" python3 - "$WORKDIR/user-data" <<'PYEOF'
import os, sys

path = sys.argv[1]
with open(path) as fh:
    text = fh.read()
if "__SSH_KEYS_BLOCK__" not in text:
    sys.exit("__SSH_KEYS_BLOCK__-Platzhalter nicht gefunden in user-data")
with open(path, "w") as fh:
    fh.write(text.replace("__SSH_KEYS_BLOCK__", os.environ["SSH_KEYS_BLOCK"].rstrip("\n")))
PYEOF

cat > "$WORKDIR/meta-data" <<METADATA
instance-id: iid-gods-eye-view-$(date +%s)
local-hostname: ${VM_NAME}
METADATA

cat > "$WORKDIR/network-config" <<NETCONFIG
version: 2
ethernets:
  nic:
    match:
      name: "en*"
NETCONFIG
if [[ -n $NET_CIDR ]]; then
  [[ -n $NET_GATEWAY ]] || die "NET_CIDR gesetzt, aber NET_GATEWAY fehlt."
  cat >> "$WORKDIR/network-config" <<NETCONFIG_STATIC
    addresses: [${NET_CIDR}]
    routes:
      - to: default
        via: ${NET_GATEWAY}
    dhcp4: false
NETCONFIG_STATIC
else
  echo "    dhcp4: true" >> "$WORKDIR/network-config"
fi

# cidata-ISO bauen (cloud-localds bevorzugt, sonst genisoimage/xorriso; notfalls nachinstallieren)
CIDATA_ISO="$WORKDIR/cidata.iso"
if ! command -v cloud-localds >/dev/null 2>&1 \
   && ! command -v genisoimage >/dev/null 2>&1 \
   && ! command -v xorriso >/dev/null 2>&1; then
  warn "Kein ISO-Tool gefunden – installiere 'cloud-image-utils'…"
  apt-get update -qq && apt-get install -y -qq cloud-image-utils >/dev/null
fi
if command -v cloud-localds >/dev/null 2>&1; then
  cloud-localds --network-config="$WORKDIR/network-config" "$CIDATA_ISO" \
    "$WORKDIR/user-data" "$WORKDIR/meta-data"
else
  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -output "$CIDATA_ISO" -volid cidata -joliet -rock \
      "$WORKDIR/user-data" "$WORKDIR/meta-data" "$WORKDIR/network-config"
  else
    xorriso -as mkisofs -quiet -o "$CIDATA_ISO" -volid cidata -joliet -rock \
      "$WORKDIR/user-data" "$WORKDIR/meta-data" "$WORKDIR/network-config"
  fi
fi
ok "cloud-init-Dateien in cidata-ISO verpackt."

CIDATA_PATH="/var/lib/vz/template/iso/${VM_NAME}-${VMID}-cidata.iso"
mkdir -p /var/lib/vz/template/iso
cp "$CIDATA_ISO" "$CIDATA_PATH"

# ---------------------------------------------------------------------------
# VM anlegen: Image importieren, Ressourcen setzen, cloud-init anhängen
# ---------------------------------------------------------------------------
info "Erstelle VM ${VMID} (${CORES} vCPU, ${MEMORY_MB} MB RAM, ${DISK_GB} GB auf ${STORAGE})…"
qm create "$VMID" \
  --name "$VM_NAME" \
  --ostype l26 \
  --cores "$CORES" \
  --cpu "$CPU_TYPE" \
  --memory "$MEMORY_MB" \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --onboot "$ONBOOT" \
  --net0 "virtio,bridge=${BRIDGE}${VLAN:+,tag=$VLAN},firewall=${PVE_FIREWALL}" \
  --serial0 socket --vga serial0 \
  --scsihw virtio-scsi-pci

info "Importiere Disk-Image in Storage '$STORAGE'…"
qm importdisk "$VMID" "$WORKDIR/$IMG_NAME" "$STORAGE" >/dev/null

DISK_REF="$(qm config "$VMID" | awk '/^unused[0-9]+:/{print $2}' | tail -n1)"
[[ -n $DISK_REF ]] || die "Importierter Datenträger nicht gefunden (kein unused-Disk in VM ${VMID})."
qm set "$VMID" --scsi0 "$DISK_REF" --boot order=scsi0

info "Erweitere Disk auf ${DISK_GB} GB…"
IMG_BYTES="$(qemu-img info --output=json "$WORKDIR/$IMG_NAME" \
  | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["virtual-size"]))')"
DISK_BYTES=$((DISK_GB * 1024 * 1024 * 1024))
DELTA_BYTES=$((DISK_BYTES - IMG_BYTES))
if (( DELTA_BYTES > 0 )); then
  DELTA_GB=$(((DELTA_BYTES + 1024 ** 3 - 1) / 1024 ** 3))
  qm disk resize "$VMID" scsi0 "+${DELTA_GB}G" >/dev/null
else
  warn "Angeforderte Größe ${DISK_GB} GB ≤ Image-Größe ($((IMG_BYTES / 1024 ** 3)) GB) – Disk bleibt auf Image-Größe."
fi

qm set "$VMID" --ide2 "${CIDATA_PATH},media=cdrom" \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --onboot "$ONBOOT"

# ---------------------------------------------------------------------------
# VM starten und auf qemu-guest-agent + IP warten
# ---------------------------------------------------------------------------
info "Starte VM ${VMID}…"
qm start "$VMID"

info "Warte auf qemu-guest-agent (erster Boot + cloud-init, kann einige Minuten dauern)…"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-600}"
elapsed=0
until qm agent "$VMID" ping >/dev/null 2>&1; do
  sleep 5
  elapsed=$((elapsed + 5))
  if (( elapsed >= AGENT_TIMEOUT )); then
    die "qemu-guest-agent nach ${AGENT_TIMEOUT}s nicht erreichbar. VM-Konsole: qm terminal $VMID · Cloud-Init-Log: qm guest exec $VMID -- tail -50 /var/log/cloud-init-output.log"
  fi
done
ok "qemu-guest-agent antwortet."

info "Ermittle VM-IP…"
VM_IP=""
elapsed=0
while [[ -z $VM_IP ]]; do
  VM_IP="$(vm_ip_of "$VMID")"
  [[ -n $VM_IP ]] && break
  sleep 3
  elapsed=$((elapsed + 3))
  if (( elapsed >= 180 )); then
    die "Konnte keine IPv4-Adresse der VM ermitteln (DHCP im Netzwerk aktiv? Bridge '${BRIDGE}' korrekt?)."
  fi
done
ok "VM-IP: $VM_IP"

# ---------------------------------------------------------------------------
# Verifikation: systemd-Service in der VM + HTTP-Check von außen
# ---------------------------------------------------------------------------
info "Prüfe systemd-Service in der VM…"
SVC_OK=false
elapsed=0
while ! $SVC_OK; do
  SVC_JSON="$(qm guest exec "$VMID" -- /bin/sh -c "systemctl is-active gods-eye-view" 2>/dev/null || true)"
  SVC_STATE="$(printf '%s' "$SVC_JSON" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print((d.get("out-data") or d.get("err-data") or "").strip())
except Exception:
    print("")' 2>/dev/null || true)"
  if [[ $SVC_STATE == active ]]; then
    SVC_OK=true
  else
    if (( elapsed >= 240 )); then
      echo "--- Service-Status: '${SVC_STATE:-unbekannt}' ---" >&2
      qm guest exec "$VMID" -- /bin/sh -c "journalctl -u gods-eye-view -n 40 --no-pager" 2>/dev/null | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("out-data", ""))
except Exception:
    pass' >&2 || true
      die "gods-eye-view-Service ist nicht 'active' geworden. Logs siehe oben / Log in der VM."
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  fi
done
ok "systemd-Service 'gods-eye-view' ist active."

info "Prüfe Web-UI unter http://${VM_IP}:${GEV_PORT} (Vite-Kaltstart kann dauern)…"
HTTP_OK=false
elapsed=0
while ! $HTTP_OK; do
  if curl -fsS -o /dev/null -m 5 "http://${VM_IP}:${GEV_PORT}/" 2>/dev/null; then
    HTTP_OK=true
  else
    if (( elapsed >= 300 )); then
      die "Web-UI antwortet nicht auf http://${VM_IP}:${GEV_PORT}. In-VM prüfen: qm guest exec $VMID -- journalctl -u gods-eye-view -n 50 --no-pager"
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  fi
done
ok "Web-UI antwortet (HTTP 200)."

print_banner "$VM_IP"
