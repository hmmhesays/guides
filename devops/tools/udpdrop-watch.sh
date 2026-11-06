#!/usr/bin/env bash
# udpdrop-watch.sh - log a line whenever a UDP socket drops packets because its receive buffer was full.
# Runs forever; under systemd, output goes to the journal (journalctl -u udpdrop-watch).
#
#   sudo bash udpdrop-watch.sh            # check every second
#   INTERVAL=5 sudo bash udpdrop-watch.sh # check every 5 seconds
#
# Output, one line per socket that dropped during the interval:
#   <RFC3339 time> port P  proc NAME(PID)  drops +N (total M)  recvq Q  rcvbuf B  | box: X dropped / Y read (Z%)
#     drops   - this socket: since the last check, and since it was opened
#     recvq   - buffer memory in use at the moment of the check (0 if it already drained)
#     rcvbuf  - the socket's receive buffer limit
#     box     - all UDP sockets on the host over the same interval (IPv4 + IPv6), exact
# Needs root to resolve other users' processes.
INTERVAL=${INTERVAL:-1}
command -v ss >/dev/null || { echo "ss not found (package iproute2)" >&2; exit 1; }

# One line per socket: "key drops rcvbuf recvq port inode"   (key = inode|local; kernel sockets all have inode 0)
snap() {
  ss -uameH 2>/dev/null | awk '
    /^[ \t]/ { line = line " " $0; next }          # skmem continuation line
    { if (line != "") print line; line = $0 }
    END { if (line != "") print line }' |
  awk '{
    ino = ""; d = ""; rb = ""
    if (match($0, /ino:[0-9]+/))  ino = substr($0, RSTART + 4, RLENGTH - 4)
    if (match($0, /,d[0-9]+\)/))  d   = substr($0, RSTART + 2, RLENGTH - 3)
    if (match($0, /,rb[0-9]+/))   rb  = substr($0, RSTART + 3, RLENGTH - 3)
    n = split($4, a, ":"); port = a[n]
    if (ino != "" && d != "") print ino "|" $4, d, rb, $2, port, ino
  }'
}

# Box-wide UDP totals: "read dropped" (InDatagrams, RcvbufErrors), IPv4 + IPv6
boxtot() {
  local r4 d4 r6 d6
  read -r r4 d4 < <(awk '$1=="Udp:"{ if(!h){for(i=2;i<=NF;i++) ix[$i]=i; h=1} else print $ix["InDatagrams"], $ix["RcvbufErrors"] }' /proc/net/snmp)
  r6=$(awk '$1=="Udp6InDatagrams"{print $2}' /proc/net/snmp6 2>/dev/null)
  d6=$(awk '$1=="Udp6RcvbufErrors"{print $2}' /proc/net/snmp6 2>/dev/null)
  echo "$(( ${r4:-0} + ${r6:-0} )) $(( ${d4:-0} + ${d6:-0} ))"
}

pct() {  # N D -> N/D as a percentage with 2 decimals (integer math)
  [ "$2" -gt 0 ] || { echo "-"; return; }
  local x=$(( $1 * 10000 / $2 )); printf '%d.%02d%%' $((x / 100)) $((x % 100))
}

owner() {  # INODE -> "comm(pid)"; looked up only when a socket drops
  [ "$1" = 0 ] && { echo kernel; return; }
  local p; p=$(find /proc/[0-9]*/fd -lname "socket:\[$1\]" 2>/dev/null | head -1 | cut -d/ -f3)
  [ -n "$p" ] && echo "$(cat "/proc/$p/comm" 2>/dev/null)($p)" || echo "?"
}

declare -A LAST
while read -r key d rb rq port ino; do LAST[$key]=$d; done < <(snap)
read -r BR BD <<<"$(boxtot)"
echo "$(date -Is) udpdrop-watch started: ${#LAST[@]} UDP sockets, checking every ${INTERVAL}s"

while sleep "$INTERVAL"; do
  now=$(snap)
  read -r br bd <<<"$(boxtot)"
  rd=$((br - BR)); dd=$((bd - BD)); BR=$br; BD=$bd
  box="box: $dd dropped / $rd read ($(pct "$dd" $((rd + dd))))"
  ts=$(date -Is)

  declare -A NOW=()
  while read -r key d rb rq port ino; do
    [ -n "$key" ] || continue
    NOW[$key]=$d
    prev=${LAST[$key]}
    if [ -n "$prev" ] && [ "$d" -gt "$prev" ]; then
      echo "$ts port $port  proc $(owner "$ino")  drops +$((d - prev)) (total $d)  recvq $rq  rcvbuf $rb  | $box"
    fi
  done <<<"$now"
  LAST=()                                   # forget closed sockets; new ones start from their current count
  for k in "${!NOW[@]}"; do LAST[$k]=${NOW[$k]}; done
  unset NOW
done