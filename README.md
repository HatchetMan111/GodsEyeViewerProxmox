# God's Eye View für Proxmox VE – Ein-Zeiler-VM-Installer

Installiert [God's Eye View](https://github.com/bilawalsidhu/gods-eye-view) — die
Live-3D-Globe-Intelligence-Konsole (Flugzeuge, Schiffe, Satelliten, Erdbeben,
CCTV, Sprachsteuerung) — vollautomatisch als **VM** auf einem Proxmox-VE-Host,
im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

Eine einzige Zeile auf dem PVE-Host: Debian-12-Cloud-VM anlegen → cloud-init
provisioniert Node.js 24, App, systemd-Service → am Ende steht die **URL,
unter der die Web-UI lokal erreichbar ist**.

---

## Installation (Einzeiler auf dem Proxmox-Host)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GodsEyeViewerProxmox/main/install/gods-eye-view.sh)"
```

Empfohlen mit dem einen zwingend nötigen Key (Google Maps, für den
photorealistischen 3D-Globe — **vor** dem Ausführen als Umgebungsvariable:

```bash
GOOGLE_MAPS_API_KEY='AIza...' bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GodsEyeViewerProxmox/main/install/gods-eye-view.sh)"
```

Mit eigenen Einstellungen (alle Variablen siehe unten):

```bash
VMID=140 CORES=4 MEMORY_MB=8192 GOOGLE_MAPS_API_KEY='AIza...' OPENAI_API_KEY='sk-...' \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GodsEyeViewerProxmox/main/install/gods-eye-view.sh)"
```

### Voraussetzungen

| Was | Wert |
|---|---|
| Proxmox VE | 8.x |
| Zugriff | root auf dem PVE-Host |
| Standard-Ressourcen | 4 vCPU · 8 GB RAM · 32 GB Disk · Bridge `vmbr0` |
| Netzwerk | DHCP im VM-Netz (oder statisch via `NET_CIDR`/`NET_GATEWAY`) |
| Internet | auf dem Host (Image/Scripte) und in der VM (apt/npm/Repo) |
| API-Keys | `GOOGLE_MAPS_API_KEY` **erforderlich** für den 3D-Globe; alles andere läuft keyless |

Das Script ist **idempotent**: Läuft schon eine VM namens `gods-eye-view`,
zeigt es nur Status und URL. Neu aufsetzen mit `RECREATE=true`.

---

## Ablauf

1. Debian-12-Cloud-Image laden (SHA512-verifiziert)
2. In-VM-Installer + systemd-Unit aus diesem Repo laden (GitHub-first)
3. VM via `qm` anlegen (Image-Import, Disk auf `DISK_GB` erweitern,
   `onboot: 1`, qemu-guest-agent, cloud-init-cidata-ISO)
4. Erster Boot: cloud-init installiert Guest-Agent, schreibt Keys nach
   `/root/gev-install.env` und startet `gev-in-vm.sh`
5. In-VM-Installer: Basis-Pakete → Node.js 24 (NodeSource) → App-Repo nach
   `/opt/gods-eye-view` → `.env` (bind `0.0.0.0`, Port `4173`) → `npm ci` →
   systemd-Service `gods-eye-view` (enabled, `Restart=always`) → Selbstverifikation
6. Host wartet auf Guest-Agent + IP, prüft `systemctl is-active` (in der VM)
   und HTTP 200 (von außen), dann Ausgabe der finalen URL

> **Geduld:** Erster Boot inkl. `apt` + `npm ci` kann einige Minuten dauern —
> das Script wartet selbstständig und meldet sich mit der URL, sobald alles steht.

---

## Variablen (per Env überschreibbar)

| Variable | Default | Bedeutung |
|---|---|---|
| `VMID` | automatisch frei (ab 130) | Proxmox-VM-ID |
| `VM_NAME` | `gods-eye-view` | Hostname + VM-Name |
| `CORES` | `4` | vCPUs |
| `MEMORY_MB` | `8192` | RAM in MB |
| `DISK_GB` | `32` | Disk in GB (Storage `STORAGE`) |
| `CPU_TYPE` | `host` | CPU-Typ |
| `STORAGE` | `local-lvm` | Storage für Disk |
| `BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `VLAN` | leer | VLAN-Tag (leer = keiner) |
| `PVE_FIREWALL` | `0` | Firewall-Tag an der VM-NIC (0 = Port frei) |
| `ONBOOT` | `1` | VM startet automatisch mit dem Host |
| `RECREATE` | `false` | `true` = existierende VM löschen & neu |
| `TIMEZONE` | `Europe/Berlin` | Zeitzone in der VM |
| `GEV_PORT` | `4173` | Web-UI-Port |
| `GEV_REPO_URL` | upstream Repo | App-Quelle (Fork möglich) |
| `GEV_BRANCH` | `main` | App-Branch |
| `NODE_MAJOR` | `24` | Node.js-Hauptversion (App: ≥24.14 <25 oder ≥26) |
| `PASSWORD_PLAIN` | `gods-eye-view` | root-Passwort in der VM (**nach Erstlogin ändern!**) |
| `SSH_PUBLIC_KEY` | leer | SSH-Public-Key(s) für root |
| `NET_CIDR` / `NET_GATEWAY` | leer (DHCP) | statische IP, z. B. `192.168.1.60/24` + `192.168.1.1` |

### API-Keys (werden nach `/opt/gods-eye-view/.env` in der VM geschrieben)

| Variable | Zweck |
|---|---|
| `GOOGLE_MAPS_API_KEY` | 🔴 **erforderlich** — photorealistischer 3D-Globe (Map Tiles API) |
| `OPENAI_API_KEY` | 🟡 Sprachsteuerung (GEV MIC) + AI-HUD-Zusammenfassung |
| `AISSTREAM_API_KEY` | 🟡 Live-Schiffe |
| `FIRMS_MAP_KEY` | 🟡 Aktive Brände |
| `TOMTOM_API_KEY` | 🟡 Echter Live-Traffic (sonst Simulation) |
| `CESIUM_ION_TOKEN` | 🟡 Bing-Imagery/World-Terrain-Stacks |
| `OPENSKY_AUTH_MODE` / `OPENSKY_CLIENT_ID` / `OPENSKY_CLIENT_SECRET` | 🟢 Flüge laufen anonym (`anon`), OAuth optional |
| `GEV_RATELIMIT_GOOGLE_PER_MIN` / `GEV_RATELIMIT_OPENAI_PER_MIN` | Per-IP-Rate-Limits der Key-Proxies |

> **Sicherheit:** Der Vite-Server bindet an `0.0.0.0` und brokered deine Keys
> serverseitig — jeder im LAN kann dann Quota verbrauchen. Setze im Heimnetz
> idealerweise `GEV_RATELIMIT_*` und provider-seitige Budget-Limits (siehe
> SECURITY.md des Upstream-Repos). `GOOGLE_MAPS_API_KEY`/`CESIUM_ION_TOKEN`
> sind bewusst client-sichtbar — beim Provider einschränken.

---

## Nach der Installation

Das Script endet mit:

```
======================================================================
  🌍 God's Eye View ist installiert und läuft!
======================================================================
  Web-UI (lokal)   : http://192.168.1.50:4173
  Optional Alias   : auf deinem Client  echo "192.168.1.50  gods-eye-view.local" >> /etc/hosts
                     → http://gods-eye-view.local:4173
  VM               : ID 130 · 4 vCPU · 8192 MB RAM · 32 GB Disk · local-lvm
  SSH              : ssh root@192.168.1.50
  App-Logs (in VM) : journalctl -u gods-eye-view -f
  ...
```

Im Browser am Client: **`http://<VM-IP>:4173`** öffnen — fertig.

---

## Update

```bash
qm guest exec <VMID> -- bash /usr/local/sbin/gev-in-vm.sh
```

Der In-VM-Installer ist idempotent: `git reset --hard origin/main` auf die
neueste App-Version, `npm ci` frisch, Service-Restart. Siehe
`journalctl -u gods-eye-view -f` währenddessen.

## Deinstallation

```bash
qm shutdown <VMID> --timeout 60 --forceStop 1 && qm destroy <VMID> --purge
rm -f /var/lib/vz/template/iso/gods-eye-view-<VMID>-cidata.iso   # cidata-ISO
```

---

## Debugging

Bei Fehlern gibt das Script immer die **komplette Fehlermeldungskette** aus
(Exit-Code, Zeile, Befehl, Aufrufkette, letzte 40 Logzeilen).

| Log | Ort |
|---|---|
| Host-Installer | `/var/log/gods-eye-view-pve-installer.log` |
| In-VM-Installer | `/var/log/gods-eye-view-installer.log` |
| App | `journalctl -u gods-eye-view -n 100 --no-pager` (in der VM) |
| Cloud-Init | `/var/log/cloud-init-output.log` (in der VM) |

Komfort-Zugriff vom Host:

```bash
qm guest exec <VMID> -- tail -50 /var/log/gods-eye-view-installer.log
qm guest exec <VMID> -- journalctl -u gods-eye-view -n 100 --no-pager
```

Mit Shell-Trace laufen lassen:

```bash
bash -x <(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GodsEyeViewerProxmox/main/install/gods-eye-view.sh)
```

In der VM (z. B. bei Service-Fehlern):

```bash
CONFIG_FILE=/root/gev-install.env bash -x /usr/local/sbin/gev-in-vm.sh
```

---

## Testdurchlauf (Reboot-Sicherheit)

Auf dem PVE-Host nach der Installation:

```bash
# 1) Service läuft
qm guest exec 130 -- systemctl is-active gods-eye-view
# → {"returncode":0,"out-data":"active\n"}

# 2) VM neustarten
qm reboot 130

# 3) Auf Guest-Agent + Service warten, dann HTTP prüfen
sleep 90
qm guest exec 130 -- systemctl is-active gods-eye-view   # wieder "active"
curl -fsS -o /dev/null -w '%{http_code}\n' http://<VM-IP>:4173   # → 200
```

Erwartung: Service und Web-UI kommen ohne manuelles Eingreifen zurück
(`systemctl enable gods-eye-view`, `Restart=always`, VM `onboot: 1`).

Zusätzlich wurde die Installer-Logik abseits eines echten PVE-Hosts
verifiziert (Stub-Harness für `qm`/`pct`/`pvesm`/Netzwerk): Neuanlage,
idempotenter Zweitlauf („existiert bereits") und `RECREATE=true` liefern
Exit 0 und die korrekte `qm`-Operations-Sequenz; cloud-init-`user-data`/
`network-config` als YAML validiert (inkl. SSH-Keys, Sonderzeichen-Passwort,
statische-IP-Variante); systemd-Unit via `systemd-analyze verify` geprüft.

---

## Repo-Struktur

```
gods-eye-view-proxmox/
├── README.md
└── install/
    ├── gods-eye-view.sh        # Einzeiler: VM anlegen (läuft auf dem PVE-Host)
    ├── gev-in-vm.sh            # Provisionierung (läuft in der VM, idempotent)
    └── gods-eye-view.service   # systemd-Unit (enabled + Restart=always)
```

App-Code selbst kommt live von
[bilawalsidhu/gods-eye-view](https://github.com/bilawalsidhu/gods-eye-view)
(`GEV_REPO_URL`/`GEV_BRANCH` überschreibbar, z. B. für Forks).

## Screenshots

<!-- TODO: Screenshot der laufenden Web-UI unter http://<VM-IP>:4173 -->
