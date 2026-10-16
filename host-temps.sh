#!/bin/bash
# host-temps - a btop-style live panel for a Linux homelab server: CPU / VRM / GPU / NVMe / HDD
# temperatures, CPU load and memory, ZFS pool health and resilver progress, per-disk read/write,
# and the top 5 processes by memory and by disk I/O (labelled with their Incus/LXC container or VM).
#
# No root needed for temperatures (HDDs need the `drivetemp` kernel module). Run with sudo to add
# SMART bad-sector counts per HDD and per-process disk I/O.
#
# Usage: host-temps.sh            # live, refresh every 10 s (q or Ctrl-C to quit)
#        host-temps.sh 60         # refresh every 60 s
#        host-temps.sh once       # print once and exit
#
# https://github.com/bryanbhd/host-temps - MIT licence
set -u
interval=${1:-10}

# ---- look ------------------------------------------------------------------
E=$'\e'; RST="$E[0m"; BOLD="$E[1m"
fg() { printf '%s[38;5;%sm' "$E" "$1"; }
BC=$(fg 60); TC=$(fg 117); LC=$(fg 252); DC=$(fg 240)
GOOD=$(fg 114); WARM=$(fg 221); HOT=$(fg 203)
GRAD=(); for n in 34 40 76 112 148 184 220 214 208 202 196 160; do GRAD+=("$(fg "$n")"); done

# layout: size the boxes to the terminal (re-run on every redraw and on resize)
layout() {
  local size cols
  size=$( { stty size </dev/tty; } 2>/dev/null ) || size="50 80"
  ROWS=${size% *}; cols=${size#* }
  W=$(( cols - 2 )); (( W > 158 )) && W=158; (( W < 50 )) && W=50   # inner box width
  LW=46; (( LW > W / 2 )) && LW=$(( W / 2 ))                         # label column
  VW=11                                                               # value column
  BW=$(( W - LW - VW - 3 ))                                           # bar column
}

# bar <value> <max>: gradient gauge BW cells wide
bar() {
  local n=$(( $1 * BW / $2 )) i out=""
  (( n > BW )) && n=$BW; (( n < 0 )) && n=0
  for (( i = 0; i < BW; i++ )); do
    if (( i < n )); then out+="${GRAD[i * ${#GRAD[@]} / BW]}■"; else out+="$DC·"; fi
  done
  printf '%s%s' "$out" "$RST"
}

# level <value> <warm> <hot>: colour for a value
level() { if (( $1 >= $3 )); then printf %s "$HOT"; elif (( $1 >= $2 )); then printf %s "$WARM"; else printf %s "$GOOD"; fi; }

top()    { local t=" $1 "; printf '%s╭─%s%s%s%s' "$BC" "$BOLD$TC" "$t" "$RST$BC" ""; printf '─%.0s' $(seq 1 $(( W - ${#t} - 1 ))); printf '╮%s\n' "$RST"; }
bottom() { printf '%s╰' "$BC"; printf '─%.0s' $(seq 1 "$W"); printf '╯%s\n' "$RST"; }
# row <label> <value> <max> <text> <colour>
row() {
  # pad the value by characters (printf pads by bytes, which breaks on "°")
  local lab=${1:0:LW-1}
  printf '%s│%s %s%s%*s%s %s %*s%s%s%s %s│%s\n' "$BC" "$RST" "$LC" "$lab" $(( LW - 1 - ${#lab} )) "" "$RST" \
    "$(bar "$2" "$3")" $(( VW - ${#4} )) "" "$5" "$4" "$RST" "$BC" "$RST"
}
# temp <label> <°C> <warm> <hot>  (bar scale 20 °C .. hot+10)
temp() { row "$1" $(( $2 - 20 )) $(( $4 - 10 )) "$2 °C" "$(level "$2" "$3" "$4")"; }
# panel <title> <rows>: a box around pre-rendered rows; nothing at all if there are no rows
panel() { [ -n "$2" ] || return 0; top "$1"; printf '%s\n' "$2"; bottom; }
# note <colour> <text>: full-width text line
note() { local t=${2:0:W-4}; printf '%s│%s   %s%s%*s%s %s│%s\n' "$BC" "$RST" "$1" "$t" $(( W - 4 - ${#t} )) "" "$RST" "$BC" "$RST"; }

hw() { cat "$1" 2>/dev/null || echo 0; }

# ---- panels ----------------------------------------------------------------
show() {
  local h t l v blk l1 cpu100 tot avail tctl ccds cmax vrm vmax

  local hint="  ·  refresh ${interval}s  ·  q quit"
  [ "$interval" = once ] && hint=""
  printf '%s %s%s%s  %s%s%s\n' "$BOLD" "$TC" "$(hostname)" "$RST$DC" "$(date '+%F %T')" "$hint" "$RST"

  mirrors=$(zpool status 2>/dev/null | awk '$1 == "pool:" {p = $2} /mirror-/ {m = substr($1, 8) + 1} /(ata|usb|wwn)-/ {print $1, p " pair " m}')

  # ---- cpu / board
  top "cpu · board  ($(cpuname))"
  for h in /sys/class/hwmon/hwmon*; do
    case $(hw "$h/name") in
      k10temp)                       # AMD: Tctl + one sensor per core die (CCD)
        ccds=""; cmax=0
        for t in "$h"/temp*_input; do
          l=$(hw "${t%_input}_label"); v=$(( $(hw "$t") / 1000 ))
          case $l in Tctl) tctl=$v ;; Tccd*) ccds+="${ccds:+ · }$v"; (( v > cmax )) && cmax=$v ;; esac
        done
        temp "CPU" "$tctl" 80 90
        [ -n "$ccds" ] && temp "  core groups $ccds" "$cmax" 80 90 ;;
      coretemp)                      # Intel: package + hottest core
        cmax=0; tctl=""
        for t in "$h"/temp*_input; do
          l=$(hw "${t%_input}_label"); v=$(( $(hw "$t") / 1000 ))
          case $l in Package*) tctl=$v ;; Core*) (( v > cmax )) && cmax=$v ;; esac
        done
        [ -n "$tctl" ] && temp "CPU package" "$tctl" 80 95
        (( cmax > 0 )) && temp "  hottest core" "$cmax" 80 95 ;;
      asusec)                        # ASUS boards (asus-ec-sensors): VRM temps
        vrm=""; vmax=0
        for t in "$h"/temp*_input; do
          l=$(hw "${t%_input}_label"); v=$(( $(hw "$t") / 1000 ))
          case $l in VRM_E) vrm+="${vrm:+ · }E $v" ;; VRM_W) vrm+="${vrm:+ · }W $v" ;; *) continue ;; esac
          (( v > vmax )) && vmax=$v
        done
        [ -n "$vrm" ] && temp "CPU power (VRM) $vrm" "$vmax" 80 100 ;;
    esac
  done
  read -r l1 _ </proc/loadavg
  cpu100=$(( $(nproc) * 100 ))
  row "CPU busy (of $(nproc) threads)" $(( 10#${l1/./} )) "$cpu100" "$l1" "$(level $(( 10#${l1/./} * 100 / cpu100 )) 70 90)"
  tot=$(awk '/^MemTotal/ {print int($2/1048576)}' /proc/meminfo)
  avail=$(awk '/^MemAvailable/ {print int($2/1048576)}' /proc/meminfo)
  row "Memory in use" $(( tot - avail )) "$tot" "$(( tot - avail ))/${tot}G" "$(level $(( (tot - avail) * 100 / tot )) 80 92)"
  bottom

  # ---- gpus: one line each (temp bar; busy % and memory in the label)
  local rows=""
  if command -v nvidia-smi >/dev/null; then
    rows=$(nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,memory.used,memory.total \
      --format=csv,noheader,nounits 2>/dev/null | grep -E '^[0-9]+,' |
      while IFS=',' read -r i name tc util mu mt; do
        name=${name# }; name=${name#NVIDIA }; name=${name#GeForce }
        name=$(awk '{print $1, $2}' <<<"$name"); name=${name% }   # "H100 80GB HBM3" -> "H100 80GB"
        temp "GPU $(( i + 1 )) · $name · ${util# }% · $(( ${mu# } / 1024 )).$(( ${mu# } % 1024 * 10 / 1024 ))/$(( ${mt# } / 1024 ))G" "${tc# }" 75 85
      done)
  fi
  local amd; amd=$(amdgpus)
  [ -n "$amd" ] && rows="${rows:+$rows$'\n'}$amd"
  panel "graphics cards" "$rows"

  # ---- storage pools: health, fill, resilver/scrub progress
  panel "storage pools" "$(pools)"

  # one 1-second sample feeds both disk panels
  local d1 d2 s1="" s2="" rate pid
  d1=$(diskstats); [ "$(id -u)" -eq 0 ] && s1=$(iosnap)
  sleep 1
  d2=$(diskstats); [ "$(id -u)" -eq 0 ] && s2=$(iosnap)

  # ---- disks: temperature bar + read/write on one row
  rows=$(awk 'NR == FNR {r[$1] = $2; w[$1] = $3; next} ($1 in r) {print $1, ($2 - r[$1]) * 512, ($3 - w[$1]) * 512}' \
    <(echo "$d1") <(echo "$d2") | sort | while read -r blk rb wb; do
      if [[ $blk == nvme* ]]; then
        drow "$(disklabel "$blk")" "$(disktemp "$blk")" 60 70 "$rb" "$wb" 2000
      else
        drow "$(disklabel "$blk")" "$(disktemp "$blk")" 45 50 "$rb" "$wb" 200
        [ "$(id -u)" -eq 0 ] && smart "$blk"
      fi
    done
    [ "$(id -u)" -eq 0 ] || note "$DC" "run with sudo to also see bad-sector counts")
  panel "disks  (temp · read/write MB/s)" "$(grep -q '°C' <<<"$rows" && echo "$rows")"

  # ---- top 5 disk
  top "top 5 · disk read+write  (process · container → pool)"
  if [ "$(id -u)" -eq 0 ]; then
    storagemap=$(incus storage list -f csv -c n,D,S 2>/dev/null)
    poolmap=$(incus list --all-projects -f json 2>/dev/null |
      jq -r '.[] | [(if .project == "default" then .name else .project + "_" + .name end), .name,
                    (.expanded_devices.root.pool // "?")] | @tsv')
    awk 'NR == FNR {a[$1] = $2; next} ($1 in a) && $2 > a[$1] {print $2 - a[$1], $1}' \
      <(echo "$s1") <(echo "$s2") | sort -rn | head -5 | while read -r rate pid; do
        row "$(procname "$pid" pool)" $(( rate / 1024 )) $(( 200 * 1024 )) "$(human "$rate")/s" "$(level $(( rate / 1048576 )) 100 180)"
      done
    [ -n "$(awk 'NR == FNR {a[$1] = $2; next} ($1 in a) && $2 > a[$1]' <(echo "$s1") <(echo "$s2"))" ] ||
      note "$DC" "no disk activity in the last second"
  else
    note "$DC" "run with sudo to see per-process disk activity"
  fi
  bottom

  # ---- top 5 memory
  top "top 5 · memory  (bar = vs biggest)"
  local tot_kb max_kb rss
  tot_kb=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
  max_kb=$(ps -eo rss= --sort=-rss | head -1)   # bars relative to the biggest process
  ps -eo pid=,rss= --sort=-rss | head -5 | while read -r pid rss; do
    row "$(procname "$pid")" "$rss" "$max_kb" "$(human $(( rss * 1024 )))" "$(level $(( rss * 100 / tot_kb )) 15 30)"
  done
  bottom
}

# amdgpus: one row per AMD GPU (amdgpu driver): edge temp, busy %, VRAM
amdgpus() {
  local h d n=0 t busy used total
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(hw "$h/name")" = amdgpu ] || continue
    d=$h/device; n=$(( n + 1 ))
    t=$(( $(hw "$h/temp1_input") / 1000 ))
    busy=$(hw "$d/gpu_busy_percent")
    used=$(( $(hw "$d/mem_info_vram_used") / 1048576 )); total=$(( $(hw "$d/mem_info_vram_total") / 1048576 ))
    temp "AMD GPU $n · ${busy}% · $(( used / 1024 )).$(( used % 1024 * 10 / 1024 ))/$(( total / 1024 ))G" "$t" 90 100
  done
}

# pools: one row per ZFS pool (fill bar, health), a progress row while a resilver/scrub
# runs, a red line if ZFS reports errors; then the btrfs Incus "default" pool
pools() {
  local name cap health kind pct eta errs used
  zpool status 2>/dev/null | awk '
    $1 == "pool:"   {p = $2; order[++n] = p}
    $1 == "state:"  {st[p] = $2}
    $1 == "scan:" && /in progress/ {k[p] = $2}
    /% done/ && (p in k) {
      if (match($0, /[0-9.]+% done/)) pc[p] = substr($0, RSTART, RLENGTH - 6)
      if (match($0, /, [^,]* to go/)) e[p] = substr($0, RSTART + 2, RLENGTH - 8)
    }
    $1 == "errors:" && $2 != "No" {er[p] = substr($0, index($0, $2))}
    END {for (i = 1; i <= n; i++) {x = order[i]; printf "%s\t%s\t%s\t%s\t%s\t%s\n", x, st[x], k[x], pc[x], e[x], er[x]}}' |
  while IFS=$'\t' read -r name health kind pct eta errs; do
    cap=$(zpool list -Ho cap "$name" 2>/dev/null); cap=${cap%\%}
    if [ "$health" = ONLINE ]; then
      row "$name · ${cap}% full" "$cap" 100 "$health" "$GOOD"
    else
      row "$name · ${cap}% full" "$cap" 100 "$health" "$HOT"
    fi
    if [ -n "$kind" ]; then
      row "  $kind${eta:+ · $eta left}" "${pct%.*}" 100 "${pct:-?}%" "$WARM"
    fi
    [ -n "$errs" ] && note "$HOT" "$name: $errs"
  done
  # non-ZFS Incus storage pools (btrfs / dir / lvm): fill level from df on the pool's source
  local pname pdriver psrc
  command -v incus >/dev/null || return 0
  incus storage list -f csv -c n,D,S 2>/dev/null | while IFS=, read -r pname pdriver psrc; do
    [ "$pdriver" = zfs ] && continue
    [ -d "$psrc" ] || continue
    used=$(df -P "$psrc" 2>/dev/null | awk 'NR == 2 {sub(/%/, "", $5); print $5}')
    [ -n "$used" ] && row "incus $pname · ${used}% full" "$used" 100 "$pdriver" "$DC"
  done
}

# disktemp <blk>: drive temperature in °C (0 if unknown)
disktemp() {
  local f
  for f in /sys/block/"$1"/device/hwmon*/temp1_input /sys/block/"$1"/device/hwmon/hwmon*/temp1_input; do
    [ -e "$f" ] && { echo $(( $(hw "$f") / 1000 )); return; }
  done
  echo 0
}

# drow <label> <°C> <warm> <hot> <read B/s> <write B/s> <full-scale MB/s>: disk row
drow() {
  local BW=$(( BW - 13 ))           # make room for the read/write column (bar() sees this BW)
  local lab=${1:0:LW-1} tv="$2 °C" io
  (( $2 > 0 )) || tv="n/a"
  io="$(mbs "$5")/$(mbs "$6")"
  printf '%s│%s %s%s%*s%s %s %*s%s%s%s %*s%s%s%s %s│%s\n' "$BC" "$RST" "$LC" "$lab" $(( LW - 1 - ${#lab} )) "" "$RST" \
    "$(bar $(( $2 > 0 ? $2 - 20 : 0 )) $(( $4 - 10 )))" $(( VW - ${#tv} )) "" "$(level "$2" "$3" "$4")" "$tv" "$RST" \
    $(( 12 - ${#io} )) "" "$(level $(( ($5 + $6) * 100 / ($7 * 1048576) )) 50 85)" "$io" "$RST" "$BC" "$RST"
}

# disklabel <blk>: "sdc · tank pair 1 · IronWolf ·1A2B" / "nvme0 · fastpool · Intel P4510"
disklabel() {
  local model="" serial="" m="" role
  if [[ $1 == nvme* ]]; then
    model=$(xargs <"/sys/block/$1/device/model" 2>/dev/null)
    role=$(ssdrole "$1")
    echo "${1%n1}${role:+ · $role}${model:+ · $(friendly "$model")}"
    return
  fi
  read -r model serial < <(lsblk -dno MODEL,SERIAL "/dev/$1" 2>/dev/null | awk 'NF >= 2 {print $(NF-1), $NF}')
  [ -z "$model" ] && model=$(xargs <"/sys/block/$1/device/model" 2>/dev/null)
  if [ -n "$serial" ]; then m=$(awk -v s="$serial" 'index($1, s) {$1 = ""; print substr($0, 2); exit}' <<<"$mirrors"); fi
  [ -z "$m" ] && [ -n "$mirrors" ] && m="not in a pool"   # only say so on a ZFS host
  echo "$1${m:+ · $m}${model:+ · $(friendly "$model")}${serial:+ ·${serial: -4}}"
}

# diskstats: "<blk> <sectors read> <sectors written>" for whole disks with a size
diskstats() {
  awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n1)$/ {print $3, $6, $10}' /proc/diskstats | while read -r b r w; do
    [ "$(cat "/sys/block/$b/size" 2>/dev/null)" != 0 ] && echo "$b $r $w"
  done
}

# mbs <bytes>: MB with one decimal under 10
mbs() { awk -v b="$1" 'BEGIN {m = b / 1048576; printf (m < 10 ? "%.1f" : "%d"), m}'; }

# poolname <incus pool>: the ZFS pool / disk it lives on
poolname() {
  local src
  src=$(awk -F, -v p="$1" '$1 == p {print $2 "," $3; exit}' <<<"$storagemap")
  case $src in zfs,*) src=${src#zfs,}; echo "${src%%/*}" ;; *) echo "$1" ;; esac
}

# procname <pid> [pool]: "command · container" ("VM · name" for Incus VMs, "· host" otherwise);
# with "pool", appends "→ <pool>" (the instance's root disk pool, from $poolmap)
procname() {
  local c n out key
  n=$(cat "/proc/$1/comm" 2>/dev/null || echo "pid $1")
  if [[ $n == qemu* ]]; then
    key=$(tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null | awk 'p {print; exit} $0 == "-name" {p = 1}')
    out="VM · ${key#*_}"
  else
    key=$(grep -o 'lxc\.payload\.[^/]*' "/proc/$1/cgroup" 2>/dev/null | head -1)
    key=${key#lxc.payload.}
    if [ -n "$key" ]; then out="$n · ${key#*_}"; else out="$n · host"; fi
  fi
  if [ "${2:-}" = pool ] && [ -n "$key" ]; then
    c=$(awk -F'\t' -v k="$key" '$1 == k || $2 == k {print $3; exit}' <<<"$poolmap")
    [ -n "$c" ] && out="$out → $(poolname "$c")"
  fi
  echo "$out"
}

# iosnap: "<pid> <bytes read+written>" for every process (root sees all; grep skips exited pids)
iosnap() {
  grep -HE '^(read|write)_bytes' /proc/[0-9]*/io 2>/dev/null |
    awk -F'[/:]' '{t[$3] += $NF} END {for (p in t) print p, t[p]}'
}

# human <bytes>
human() { awk -v b="$1" 'BEGIN {split("B K M G T", u); i = 1; while (b >= 1024 && i < 5) {b /= 1024; i++}; printf (i > 2 ? "%.1f%s" : "%d%s"), b, u[i]}'; }

cpuname() { awk -F': ' '/model name/ {sub(/AMD Ryzen /, "", $2); sub(/ [0-9]+-Cores/, "", $2); print $2; exit}' /proc/cpuinfo; }

# friendly <model>: short name for common drive families (falls back to the raw model)
friendly() {
  case $1 in
    ST*VN*)          echo "IronWolf" ;;
    ST*NE*|ST*NT*)   echo "IronWolf Pro" ;;
    ST*NM*)          echo "Exos" ;;
    ST*DM*)          echo "BarraCuda" ;;
    *WD*EFPX*|*WD*EFZZ*|*WD*EFZX*|*WD*EFRX*) echo "WD Red Plus" ;;
    *WD*EFAX*)       echo "WD Red (SMR)" ;;
    *WUH72*|*HUH72*) echo "Ultrastar" ;;
    *HDWE*)          echo "X300" ;;
    *HDWG*)          echo "N300" ;;
    *MG0[0-9]ACA*)   echo "Toshiba MG" ;;
    *SSDPE2K*)       echo "Intel P45x0" ;;
    *MP700*)         echo "Corsair MP700" ;;
    *CT*T700*)       echo "Crucial T700" ;;
    *CT*T500*)       echo "Crucial T500" ;;
    *990\ PRO*)      echo "Samsung 990 PRO" ;;
    *980\ PRO*)      echo "Samsung 980 PRO" ;;
    *)               echo "$1" ;;
  esac
}

# ssdrole <nvmeXn1>: what the SSD is used for - "system", its ZFS pool, its mount point, or fs type
ssdrole() {
  lsblk -nP -o LABEL,FSTYPE,MOUNTPOINT "/dev/$1" 2>/dev/null | awk '
    function v(k) { return match($0, k "=\"[^\"]*\"") ? substr($0, RSTART + length(k) + 2, RLENGTH - length(k) - 3) : "" }
    { l = v("LABEL"); f = v("FSTYPE"); m = v("MOUNTPOINT")
      if (m == "/") sys = 1
      if (f == "zfs_member" && zp == "") zp = l
      if (m != "" && m != "/" && mp == "" && m !~ /^\/(boot|var\/lib\/incus\/devices)/) mp = m
      if (f != "" && f != "vfat" && fs == "") fs = f }
    END { if (!NR) exit
          if (sys) print "system"; else if (zp != "") print zp
          else if (mp != "") { n = split(mp, a, "/"); print a[n] } else if (fs != "") print fs; else print "unused" }'
}

# smart <dev>: one note line of SMART counters (root only)
smart() {
  local a pend off real hrs health c=$GOOD
  a=$(smartctl -A "/dev/$1" 2>/dev/null)
  get() { awk -v id="$1" '$1==id {print $10; exit}' <<<"$a"; }
  pend=$(get 197); off=$(get 198); real=$(get 5); hrs=$(get 9)
  health=$(smartctl -H "/dev/$1" 2>/dev/null | awk -F': *' '/overall-health/ {print $2}')
  if (( ${pend:-0} > 0 || ${off:-0} > 0 || ${real:-0} > 0 )); then c=$WARM; fi
  [ "${health:-PASSED}" = PASSED ] || c=$HOT
  [[ ${hrs:-} =~ ^[0-9]+$ ]] && hrs="$(( hrs / 8760 )).$(( hrs % 8760 * 10 / 8760 )) yrs" || hrs="? yrs"
  note "$c" "unreadable ${pend:-?} · uncorrectable ${off:-?} · remapped ${real:-?} · $hrs on · ${health:-?}"
}

# ---- run -------------------------------------------------------------------
layout
if [ "$interval" = once ]; then show; exit; fi
trap 'printf "%s[?25h%s[?1049l" "$E" "$E"; exit' INT TERM EXIT
printf '%s[?1049h%s[?25l' "$E" "$E"        # alternate screen, hide cursor
while true; do
  layout
  size=$( { stty size </dev/tty; } 2>/dev/null )
  frame=$(show)
  printf '%s[H%s%s[J' "$E" "$(head -n "$ROWS" <<<"$frame")" "$E"   # clip to window height
  # wait for the interval, polling once a second for q or a window resize
  for (( waited = 0; waited < interval; waited++ )); do
    read -rsn1 -t 1 key && [[ $key == q ]] && exit
    [ "$( { stty size </dev/tty; } 2>/dev/null )" != "$size" ] && break
  done
done
