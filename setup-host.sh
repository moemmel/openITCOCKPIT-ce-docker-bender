#!/usr/bin/env bash
#
# itcockpit-setup.sh - legt die Bind-Mount-Ordner des openITCOCKPIT-Stacks an
#
# Aufruf (auf dem Docker-Host, als root):
#   sudo ./itcockpit-setup.sh            Ordner anlegen / Rechte korrigieren (idempotent, löscht nie etwas)
#   sudo ./itcockpit-setup.sh --check    nur prüfen und anzeigen, nichts ändern
#   sudo ./itcockpit-setup.sh --reset    ALLE Daten löschen und neu einrichten (nur bei gestopptem Stack)
#
# Optionale Umgebungsvariablen:
#   BASE=/opt/docker/itcockpit   Basisverzeichnis (muss zu den Pfaden in der compose.yml passen)
#   OITC_VERSION=5.7.0           Image-Tag (derselbe Wert wie in Dockhand)
#
# Die Datei enthält keine Geheimnisse und kann im Git-Repo liegen.

set -euo pipefail

BASE="${BASE:-/opt/docker/itcockpit}"
OITC_VERSION="${OITC_VERSION:-5.7.0}"

# Benutzer-/Gruppen-IDs aus den Containern (so beobachtet, siehe Prüfung in check_nagios_uid):
#   nagios   = UID 117 im Naemon-Image, www-data = 33, grafana = UID 472 / GID 0
NAGIOS_UID=117
WWW_GID=33

# Ordner -> UID:GID. "-" = nur anlegen, Besitzer setzt der Container selbst (MySQL).
declare -A OWNER=(
  [mysql-data]="-"
  [grafana-data]="472:0"
  [graphite-data]="0:0"
  [naemon-var]="${NAGIOS_UID}:${WWW_GID}"
  [naemon-var-local]="${NAGIOS_UID}:${WWW_GID}"
  [naemon-config]="${NAGIOS_UID}:${WWW_GID}"
  [oitc-frontend-src]="0:0"
  [oitc-webroot]="33:33"
  [oitc-maps]="33:33"
  [oitc-agent-cert]="0:0"
  [oitc-agent-etc]="0:0"
  [oitc-var]="0:0"
  [oitc-backups]="0:0"
  [oitc-styles]="33:33"
  [checkmk-etc]="0:0"
  [checkmk-var]="0:0"
  [checkmk-agents]="0:0"
  [prometheus-var]="0:0"
  [prometheus-config]="0:0"
)

# Unterordner, die im Image existieren, aber vom leeren Bind-Mount verdeckt werden.
# Ohne sie bricht Naemon beim Start ab (check_result_path, Query-Handler-Socket in rw/).
NAEMON_VAR_SUBDIRS=(rw log/naemon/archives cache/naemon/checkresults)
NAEMON_VAR_LOCAL_SUBDIRS=(spool/perfdata spool/checkresults archives stats cache/naemon)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNUNG:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }

sorted_names() { printf '%s\n' "${!OWNER[@]}" | sort; }
have_docker()  { command -v docker >/dev/null 2>&1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen (sudo $0 ...)."
}

check_base() {
  # Schutz vor Tippfehlern: BASE muss ein Pfad mit mindestens zwei Ebenen sein.
  [[ "$BASE" == /*/* ]] || die "BASE='$BASE' sieht nicht sicher aus (mindestens /a/b erwartet)."
}

# Prüft, ob die UID von 'nagios' im Image noch zu NAGIOS_UID passt (Best Effort).
check_nagios_uid() {
  have_docker || return 0
  local real
  real=$(docker run --rm --entrypoint id "openitcockpit/naemon:${OITC_VERSION}" -u nagios 2>/dev/null || true)
  if [ -n "$real" ] && [ "$real" != "$NAGIOS_UID" ]; then
    warn "Im Image openitcockpit/naemon:${OITC_VERSION} hat 'nagios' die UID ${real}, das Skript nimmt ${NAGIOS_UID}. NAGIOS_UID im Skript anpassen!"
  fi
}

# Legt zusätzlich alle Verzeichnisse aus dem Image an (nur Verzeichnisse, keine Dateien).
# Best Effort: Ohne Docker oder ohne Image bleibt es bei den fest eingetragenen Listen.
seed_dirs_from_image() {
  local host_dir="$1" container_path="$2" dirs d
  have_docker || return 0
  if dirs=$(docker run --rm --entrypoint sh "openitcockpit/naemon:${OITC_VERSION}" \
              -c "cd '${container_path}' && find . -mindepth 1 -type d" 2>/dev/null); then
    while IFS= read -r d; do
      [ -n "$d" ] && mkdir -p "${host_dir}/${d}"
    done <<<"$dirs"
  else
    warn "Verzeichnisse aus dem Image (${container_path}) nicht lesbar - nutze die feste Liste."
  fi
}

chown_dirs_only() {
  # Besitzer nur für Verzeichnisse setzen, Dateien (status.dat, nagios.cmd ...) bleiben unverändert.
  local dir="$1" owner="$2"
  find "$dir" -type d -exec chown "$owner" {} +
}

setup() {
  require_root
  check_base
  check_nagios_uid

  log "Basisverzeichnis ${BASE}"
  install -d -m 0755 -o 0 -g 0 "$BASE"

  local name owner sub
  for name in $(sorted_names); do
    owner="${OWNER[$name]}"
    install -d -m 0755 "${BASE}/${name}"
    [ "$owner" = "-" ] || chown "$owner" "${BASE}/${name}"
  done

  log "Unterordner für Naemon"
  for sub in "${NAEMON_VAR_SUBDIRS[@]}"; do mkdir -p "${BASE}/naemon-var/${sub}"; done
  for sub in "${NAEMON_VAR_LOCAL_SUBDIRS[@]}"; do mkdir -p "${BASE}/naemon-var-local/${sub}"; done
  seed_dirs_from_image "${BASE}/naemon-var"       /opt/openitc/nagios/var
  seed_dirs_from_image "${BASE}/naemon-var-local" /opt/openitc/nagios/var_local
  chown_dirs_only "${BASE}/naemon-var"       "${OWNER[naemon-var]}"
  chown_dirs_only "${BASE}/naemon-var-local" "${OWNER[naemon-var-local]}"

  status
}

# Zeigt Soll/Ist je Ordner. Ändert nichts. Gibt 1 zurück, wenn etwas abweicht.
status() {
  local name expected actual mode rc=0 sub
  log "Prüfung (Besitzer UID:GID, Rechte)"
  printf '%-20s %-10s %-10s %-6s %s\n' ORDNER IST SOLL RECHTE ERGEBNIS
  for name in $(sorted_names); do
    expected="${OWNER[$name]}"
    if [ ! -d "${BASE}/${name}" ]; then
      printf '%-20s %-10s %-10s %-6s %s\n' "$name" "-" "$expected" "-" "FEHLT"
      rc=1; continue
    fi
    actual=$(stat -c '%u:%g' "${BASE}/${name}")
    mode=$(stat -c '%a' "${BASE}/${name}")
    if [ "$expected" = "-" ] || [ "$expected" = "$actual" ]; then
      printf '%-20s %-10s %-10s %-6s %s\n' "$name" "$actual" "$expected" "$mode" "ok"
    else
      printf '%-20s %-10s %-10s %-6s %s\n' "$name" "$actual" "$expected" "$mode" "ABWEICHUNG"
      rc=1
    fi
  done
  for sub in "${NAEMON_VAR_SUBDIRS[@]}"; do
    [ -d "${BASE}/naemon-var/${sub}" ] || { printf 'Unterordner fehlt: naemon-var/%s\n' "$sub"; rc=1; }
  done
  for sub in "${NAEMON_VAR_LOCAL_SUBDIRS[@]}"; do
    [ -d "${BASE}/naemon-var-local/${sub}" ] || { printf 'Unterordner fehlt: naemon-var-local/%s\n' "$sub"; rc=1; }
  done
  [ "$rc" -eq 0 ] && log "Alles wie erwartet." || warn "Abweichungen gefunden (siehe oben)."
  return "$rc"
}

reset_all() {
  require_root
  check_base
  if have_docker && [ -n "$(docker ps -q --filter 'name=openitcockpit-' 2>/dev/null)" ]; then
    die "Es laufen noch Container 'openitcockpit-*'. Stack in Dockhand stoppen, Container entfernen (docker rm), dann erneut starten."
  fi
  warn "Das löscht ALLE Daten unter ${BASE} (Datenbank, Konfiguration, Graphen, Zertifikate)."
  read -r -p "Zum Fortfahren JA eintippen: " answer
  [ "$answer" = "JA" ] || die "Abgebrochen."
  local name
  for name in $(sorted_names); do
    [ -d "${BASE}/${name}" ] && find "${BASE}/${name}" -mindepth 1 -delete
  done
  log "Daten gelöscht."
  setup
}

case "${1:-}" in
  "")        setup ;;
  --check)   check_base; status ;;
  --reset)   reset_all ;;
  -h|--help) sed -n '2,16p' "$0" ;;
  *)         die "Unbekannte Option '$1' (erlaubt: --check, --reset)." ;;
esac
