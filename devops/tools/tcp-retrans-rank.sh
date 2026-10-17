#!/bin/bash
# Rank current TCP connections by lifetime retransmits, group them by peer, or measure bandwidth.
#
# Modes:
#   -s  simple    retransmits, segments sent, percent, timer, local -> peer, process
#   -a  advanced  adds direction and TCP state; direction inferred from listening ports (default)
#                 -s/-a/-c also list SYN-RECV half-open entries, counting their SYN-ACK resends
#   -c  conntrack like advanced, but direction is confirmed from the conntrack table where possible
#   -p  peers     count connections by state, process, initiator -> acceptor:port and direction
#   -b  bandwidth sample TCP byte counters for a few seconds and rank connections by kbit/s
#   -A  all       run advanced, peers and bandwidth one after another in a single report
#
# Options:
#   -f STATE  only show connections in this state, e.g. ESTAB, SYN-SENT, CLOSE-WAIT, TIME-WAIT
#   -n N      show the top N lines (default 20); -n all or -n 0 shows every line
#   -i SECS   sampling interval for -b (default 5)
#   -r        print standalone one-liners and handshake checks you can paste on a server
#   -h        show this help
#
# Processes are shown as name/pid. Run as root so all processes (and conntrack) are visible.
# TIMER (-s/-a/-c) is the kernel timer running now, as kind/count:
#   on/N        data or SYN waiting for an ACK; N = resends since the last ACK (N > 0 = stalled now)
#   keepalive/N keepalive probes unanswered     persist/N  zero-window probes     -  no timer
# RETRANS is the socket's lifetime total. For SYN-RECV it is the SYN-ACK resend count
# from the timer, and SEGS_OUT/PCT show '-' because ss gives no segment count for them.

# ---------------------------------------------------------------------------
# TROUBLESHOOTING NOTES (not shown by -h; -r prints the handshake check below)
#
# High retransmit ratio but few connections?
#   The Grafana ratio RetransSegs / OutSegs gets large on a quiet host, so check the
#   absolute rates first. Then find out which kind of retransmit is rising:
#       nstat -n; sleep 60; nstat | grep -Ei 'RetransSegs|OutSegs|SynRetrans|Timeouts|FastRetrans|LossProbe'
#   TCPSynRetrans   SYN or SYN-ACK resends: handshakes that never complete (see below)
#   TCPLossProbes   tail loss probes, usually harmless on chatty low-volume connections
#   TCPTimeouts     full RTO timeouts: connections stalling
#   TCPFastRetrans  real packet loss on established connections
#
# Handshakes that never complete (SYN-SENT / SYN-RECV):
#       ss -tnop state syn-recv state syn-sent
#   Example output:
#       SYN-RECV  0  0  23.227.166.146:8081   85.203.40.180:41000  timer:(on,3.120sec,2)
#       SYN-SENT  0  1  23.227.166.146:51234  10.20.0.15:5432      users:(("app",pid=812,fd=9)) timer:(on,7.8sec,3)
#   timer:(on,<time until next resend>,<resends so far>)
#   SYN-RECV  Inbound. A remote host sent a SYN, we answered with a SYN-ACK, and the
#             final ACK never came. Many sources hitting one port usually means scanners
#             or a SYN flood. No process is shown because nothing has accepted it yet.
#             Each SYN-ACK resend counts in RetransSegs (default limit:
#             net.ipv4.tcp_synack_retries = 5, about a minute). If the client keeps
#             resending its SYN, the count can go higher.
#             ss reports no retrans: field for half-open entries, only the timer count
#             above, so -s/-a/-c take RETRANS for SYN-RECV rows from that timer count.
#             Fix: firewall the port to trusted sources if it needn't be public, keep
#             net.ipv4.tcp_syncookies = 1, optionally lower tcp_synack_retries to 2.
#   SYN-SENT  Outbound. This host is connecting to something that doesn't answer
#             (down, firewalled with DROP, or a stale address in a config). The process
#             column shows who is trying. One socket keeps retrying (default
#             net.ipv4.tcp_syn_retries = 6, up to ~2 minutes), so repeated snapshots show
#             the same socket. A new local port means a new attempt. These do appear
#             in -a: ./tcp-retrans-rank.sh -a -f syn-sent -n all
#   Watch live:   watch -n1 'ss -tnop state syn-recv state syn-sent'
#   Per source:   see the "SYN-RECV by source" one-liner in -r.
#
# Reproduce both states safely on one box (spare port 9999, loopback only):
#       nc -lk 9999 &
#       iptables -I INPUT -i lo -p tcp --sport 9999 --tcp-flags SYN,ACK SYN,ACK -j DROP
#       nc -v -w 60 127.0.0.1 9999
#       ss -tnop state syn-recv state syn-sent       # both sides, counts climbing
#       iptables -D INPUT -i lo -p tcp --sport 9999 --tcp-flags SYN,ACK SYN,ACK -j DROP
# ---------------------------------------------------------------------------

set -o pipefail

TOP=20
MODE=advanced
INTERVAL=5
STATE_FILTER=""

usage() {
    sed -n '2,/^$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# Prints "C <line>" for each line of ss -tinopH (TCP info, timers, processes), for awk.
ss_connections() {
    ss -tinopH | sed 's/^/C /'
}

# Prints "C <line>" for each socket line of ss -tanpH (no per-socket TCP info).
ss_sockets() {
    ss -tanpH | sed 's/^/C /'
}

# Prints "L <port>" for each TCP listening port.
listening_ports() {
    ss -tlnH | awk '{ p = $4; sub(/.*:/, "", p); print "L", p }'
}

# Prints "T <initiator ip> <initiator port> <acceptor ip> <acceptor port>" from conntrack's original-direction tuples.
conntrack_tuples() {
    {
        conntrack -L -p tcp 2>/dev/null
        conntrack -L -f ipv6 -p tcp 2>/dev/null
    } | awk '{
        s = d = sp = dp = ""
        for (i = 1; i <= NF; i++) {
            if (s  == "" && $i ~ /^src=/)   s  = substr($i, 5)
            else if (d  == "" && $i ~ /^dst=/)   d  = substr($i, 5)
            else if (sp == "" && $i ~ /^sport=/) sp = substr($i, 7)
            else if (dp == "" && $i ~ /^dport=/) dp = substr($i, 7)
        }
        if (s != "" && dp != "") print "T", s, sp, d, dp
    }'
}

# Passes through the first TOP lines, or everything when TOP is 0 (all).
limit_rows() {
    if [ "$TOP" -eq 0 ]; then cat; else head -n "$TOP"; fi
}

sort_and_trim() {
    sort -rn | limit_rows
}

# Shared awk helpers for parsing ss output.
AWK_COMMON='
function proc_name(line,    p, u) {
    p = "-"
    if (match(line, /users:\(\("[^"]+",pid=[0-9]+/)) {
        split(substr(line, RSTART + 9, RLENGTH - 9), u, "\",pid=")
        p = u[1] "/" u[2]
    }
    return p
}
function retrans_total(line,    r) {
    if (!match(line, /retrans:[0-9]+\/[0-9]+/)) return -1
    split(substr(line, RSTART + 8, RLENGTH - 8), r, "/")
    return r[2] + 0
}
function segs_out(line) {
    if (match(line, /segs_out:[0-9]+/)) return substr(line, RSTART + 9, RLENGTH - 9) + 0
    return 0
}
function port_of(addr,    p) { p = addr; sub(/.*:/, "", p); return p }
function ip_of(addr,    a) {
    a = addr
    sub(/:[^:]*$/, "", a)        # drop port
    gsub(/[\[\]]/, "", a)        # drop IPv6 brackets
    sub(/%.*/, "", a)            # drop interface zone
    sub(/^::ffff:/, "", a)       # IPv4-mapped IPv6 -> IPv4
    return a
}
function pct(r, o) { return o ? r * 100 / o : 0 }
# Sets tkind and tcount from a timer:(kind,expiry,count) field; tkind is "" when absent.
function parse_timer(line,    t, f) {
    tkind = ""; tcount = 0
    if (match(line, /timer:\([a-z]+,[^,)]*,[0-9]+\)/)) {
        t = substr(line, RSTART + 7, RLENGTH - 8)
        split(t, f, ",")
        tkind = f[1]; tcount = f[3] + 0
    }
}
function timer_label() { return tkind == "" ? "-" : tkind "/" tcount }
# Builds the RETRANS/SEGS_OUT/PCT/TIMER columns for the current record.
# Returns 0 if the record has nothing to report.
function retrans_cols(state, info,    r, o) {
    if (state == "SYN-RECV") {
        if (tkind == "" || tcount <= 0) return 0
        c_r = tcount; c_o = "-"; c_p = "-"
    } else {
        r = retrans_total(info)
        if (r <= 0 && !(tkind == "on" && tcount > 0)) return 0
        if (r < 0) r = 0
        o = segs_out(info)
        c_r = r; c_o = o; c_p = sprintf("%.2f%%", pct(r, o))
    }
    c_t = timer_label()
    return 1
}
function show_host(a) { a = ip_of(a); return (a ~ /:/) ? "[" a "]" : a }
function wanted(state) { return want == "" || state == want }
'

simple_report() {
    printf "%8s %10s %9s  %-13s %-50s %s\n" RETRANS SEGS_OUT PCT TIMER "LOCAL -> PEER" PROCESS
    ss_connections | awk -v want="$STATE_FILTER" "$AWK_COMMON"'
    function flush() {
        if (!have || !wanted(state)) return
        parse_timer(head)
        if (retrans_cols(state, info))
            printf "%8d %10s %9s  %-13s %-50s %s\n", c_r, c_o, c_p, c_t, conn, proc
    }
    { sub(/^C /, "") }
    /^[A-Z]/ { flush(); have = 1; head = $0; info = ""
               state = $1; conn = $4 " -> " $5; proc = proc_name($0); next }
    { info = info " " $0 }
    END { flush() }' | sort_and_trim
}

# Shared by advanced and conntrack modes. Pass "1" to use conntrack.
direction_report() {
    local use_ct="$1"
    printf "%8s %10s %9s  %-13s %-4s %-10s  %-50s %s\n" RETRANS SEGS_OUT PCT TIMER DIR STATE "INITIATOR -> ACCEPTOR" PROCESS
    {
        listening_ports
        [ "$use_ct" = 1 ] && conntrack_tuples
        ss_connections
    } | awk -v want="$STATE_FILTER" "$AWK_COMMON"'
    function flush() {
        if (!have || !wanted(state)) return
        parse_timer(head)
        if (retrans_cols(state, info))
            printf "%8d %10s %9s  %-13s %-4s %-10s  %-50s %s\n", c_r, c_o, c_p, c_t, dir, state, conn, proc
    }
    $1 == "L" { listen[$2] = 1; next }
    $1 == "T" { ct[$2 "|" $3 "|" $4 "|" $5] = 1; next }
    { sub(/^C /, "") }
    /^[A-Z]/ {
        flush(); have = 1; head = $0; info = ""
        state = $1; local = $4; peer = $5; proc = proc_name($0)
        lip = ip_of(local); lp = port_of(local)
        pip = ip_of(peer);  pp = port_of(peer)
        if ((pip "|" pp "|" lip "|" lp) in ct)      dir = "in"
        else if ((lip "|" lp "|" pip "|" pp) in ct) dir = "out"
        else if (lp in listen)                      dir = "in?"
        else                                        dir = "out?"
        if (dir ~ /^in/) conn = peer " -> " local
        else             conn = local " -> " peer
        next
    }
    { info = info " " $0 }
    END { flush() }' | sort_and_trim
}

advanced_report() {
    direction_report 0
    echo
    echo "DIR: in/out inferred from listening ports (marked with ?). Use -c to confirm with conntrack."
}

conntrack_report() {
    if ! command -v conntrack >/dev/null 2>&1; then
        echo "conntrack not found. Install it with: dnf install -y conntrack-tools" >&2
        exit 1
    fi
    if [ -z "$(conntrack -L -p tcp 2>/dev/null | head -n 1)" ]; then
        echo "Warning: conntrack table is empty or unreadable (not root, or nf_conntrack not loaded)." >&2
        echo "Falling back to inferred direction." >&2
    fi
    direction_report 1
    echo
    echo "DIR: in/out confirmed by conntrack; in?/out? inferred from listening ports (no conntrack entry)."
}

# Counts connections grouped by state, process, initiator -> acceptor:service port and direction.
peers_report() {
    printf "%7s  %-11s %-22s %-4s %s\n" COUNT STATE PROCESS DIR "INITIATOR -> ACCEPTOR:PORT"
    {
        listening_ports
        ss_sockets
    } | awk -v want="$STATE_FILTER" "$AWK_COMMON"'
    $1 == "L" { listen[$2] = 1; next }
    { sub(/^C /, "") }
    $1 !~ /^[A-Z]/ || $1 == "LISTEN" || NF < 5 || !wanted($1) { next }
    {
        lp = port_of($4); rp = port_of($5)
        if (lp in listen) { dir = "in";  conn = show_host($5) " -> " show_host($4) ":" lp }
        else              { dir = "out"; conn = show_host($4) " -> " show_host($5) ":" rp }
        print $1 "\t" proc_name($0) "\t" dir "\t" conn
    }' | sort | uniq -c | sort -rn | limit_rows |
    awk -F'\t' '{ split($1, a, " "); printf "%7d  %-11s %-22s %-4s %s\n", a[1], a[2], $2, $3, $4 }'
    echo
    echo "DIR inferred from listening ports. PORT is the service port: local for in, remote for out."
}

# Prints "<local> <peer> <bytes_acked> <bytes_received> <name/pid>" for each TCP socket in the wanted state.
bandwidth_snapshot() {
    ss -tinpH | awk -v want="$STATE_FILTER" "$AWK_COMMON"'
    /^[A-Z]/ { skip = !wanted($1); key = $4 " " $5; proc = proc_name($0); next }
    {
        if (skip) next
        tx = rx = 0
        if (match($0, /bytes_acked:[0-9]+/))    tx = substr($0, RSTART + 12, RLENGTH - 12)
        if (match($0, /bytes_received:[0-9]+/)) rx = substr($0, RSTART + 15, RLENGTH - 15)
        print key, tx, rx, proc
    }'
}

# Takes two snapshots INTERVAL seconds apart and ranks connections by throughput.
# Snapshots are held in shell variables, so no temp files are written.
bandwidth_report() {
    local before after
    echo "Sampling TCP byte counters for ${INTERVAL}s..." >&2
    before=$(bandwidth_snapshot)
    sleep "$INTERVAL"
    after=$(bandwidth_snapshot)
    printf "%12s %12s %12s  %-50s %s\n" TOTAL_kbps TX_kbps RX_kbps "LOCAL -> PEER" PROCESS
    {
        printf '%s\n' "$before" | sed 's/^/A /'
        printf '%s\n' "$after"  | sed 's/^/B /'
    } | awk -v i="$INTERVAL" '
    NF < 6 { next }
    $1 == "A" { tx[$2 " " $3] = $4; rx[$2 " " $3] = $5; next }
    {
        t = ($4 - tx[$2 " " $3]) * 8 / 1000 / i
        r = ($5 - rx[$2 " " $3]) * 8 / 1000 / i
        if (t + r > 0) printf "%12.1f %12.1f %12.1f  %-50s %s\n", t + r, t, r, $2 " -> " $3, $6
    }' | sort_and_trim
    echo
    echo "TCP payload only (bytes acked / received); UDP such as RTP is not included. Use iftop for UDP."
}

section() {
    printf '\n===== %s =====\n' "$1"
}

# Runs advanced, peers and bandwidth in one go, with a header for each.
all_report() {
    echo "Host: $(hostname)   Time: $(date '+%Y-%m-%d %H:%M:%S %Z')${STATE_FILTER:+   State: $STATE_FILTER}"
    section "RETRANSMITS (advanced)"
    advanced_report
    section "CONNECTIONS BY PEER"
    peers_report
    section "BANDWIDTH (${INTERVAL}s sample)"
    bandwidth_report
}

# Standalone one-liners to copy and paste. The quoted heredoc is printed as-is, never run.
reference() {
    cat <<'REFERENCE'
Standalone versions to copy and paste when you can't put this script on a server.
Run as root to see process names.

--- Simple: rank connections by lifetime retransmits ---
Columns: retransmits, segments sent, percent, local -> peer, process

ss -tinpH | awk '
/^[A-Z]/ { conn = $4 " -> " $5 "  " $NF; next }
match($0, /retrans:[0-9]+\/[0-9]+/) {
    split(substr($0, RSTART+8, RLENGTH-8), r, "/")
    out = 0
    if (match($0, /segs_out:[0-9]+/)) out = substr($0, RSTART+9, RLENGTH-9)
    printf "%8d %10d %7.2f%%  %s\n", r[2], out, (out ? r[2]*100/out : 0), conn
}' | sort -rn | head -20

--- Peers: count connections by state, process/pid, initiator -> acceptor:port, direction ---
Direction is inferred from listening ports. Port is the service port.

{ ss -tlnH | awk '{p=$4; sub(/.*:/,"",p); print "L", p}'; ss -tanpH | sed 's/^/C /'; } | awk '
function host(a) { sub(/:[^:]*$/, "", a); gsub(/[][]/, "", a); return (a ~ /:/) ? "[" a "]" : a }
function port(a) { sub(/.*:/, "", a); return a }
$1=="L" { listen[$2]=1; next }
$2=="LISTEN" || NF<6 { next }
{
  state=$2
  proc="-"
  if (match($0, /users:\(\("[^"]+",pid=[0-9]+/)) {
    split(substr($0, RSTART+9, RLENGTH-9), u, "\",pid=")
    proc=u[1] "/" u[2]
  }
  lip=host($5); lp=port($5); rip=host($6); rp=port($6)
  if (lp in listen) print state, proc, rip " -> " lip ":" lp, "(in)"
  else              print state, proc, lip " -> " rip ":" rp, "(out)"
}' | sort | uniq -c | sort -rn | head -30

--- Bandwidth: sample TCP byte counters for I seconds, rank connections by kbit/s ---
Columns: total, transmit and receive kbit/s, local -> peer, process/pid. TCP only.

I=5
snap() { ss -tinpH | awk '
/^[A-Z]/ { k = $4 " " $5; p = "-"
           if (match($0, /users:\(\("[^"]+",pid=[0-9]+/)) { split(substr($0, RSTART+9, RLENGTH-9), u, "\",pid="); p = u[1] "/" u[2] }
           next }
{ tx = rx = 0
  if (match($0, /bytes_acked:[0-9]+/))    tx = substr($0, RSTART+12, RLENGTH-12)
  if (match($0, /bytes_received:[0-9]+/)) rx = substr($0, RSTART+15, RLENGTH-15)
  print k, tx, rx, p }'; }
BEFORE=$(snap); sleep "$I"; AFTER=$(snap)
printf "%12s %12s %12s  %-50s %s\n" TOTAL_kbps TX_kbps RX_kbps "LOCAL -> PEER" PROCESS
{ printf '%s\n' "$BEFORE" | sed 's/^/A /'; printf '%s\n' "$AFTER" | sed 's/^/B /'; } | awk -v i="$I" '
$1 == "A" { tx[$2" "$3] = $4; rx[$2" "$3] = $5; next }
{ t = ($4 - tx[$2" "$3]) * 8 / 1000 / i; r = ($5 - rx[$2" "$3]) * 8 / 1000 / i
  if (t + r > 0) printf "%12.1f %12.1f %12.1f  %-50s %s\n", t + r, t, r, $2 " -> " $3, $6 }' \
  | sort -rn | head -20

--- Handshakes: half-open inbound (SYN-RECV) and stuck outbound (SYN-SENT) ---
timer:(on,<time until next resend>,<resends so far>). SYN-RECV = SYN-ACKs we resent to a
peer that never finished the handshake. SYN-SENT = our SYNs to a peer that never answered;
the process column shows who is connecting.

ss -tnop state syn-recv state syn-sent

Watch it live:

watch -n1 'ss -tnop state syn-recv state syn-sent'

--- SYN-RECV by source: half-open connections and SYN-ACK resends per peer and local port ---

printf "%8s %12s  %s\n" HALF_OPEN SYNACK_RETX "PEER -> LOCAL PORT"
ss -tnoH state syn-recv | awk '
match($0, /timer:\(on,[^,]*,[0-9]+\)/) {
  t = substr($0, RSTART, RLENGTH); sub(/.*,/, "", t); sub(/\)/, "", t)
  ip = $4; sub(/:[^:]*$/, "", ip); lp = $3; sub(/.*:/, "", lp)
  k = ip " -> :" lp; n[k]++; r[k] += t }
END { for (k in n) printf "%8d %12d  %s\n", n[k], r[k], k }' | sort -k2 -rn | head -20
REFERENCE
}

while getopts ":sacpbArf:n:i:h" opt; do
    case "$opt" in
        s) MODE=simple ;;
        a) MODE=advanced ;;
        c) MODE=conntrack ;;
        p) MODE=peers ;;
        b) MODE=bandwidth ;;
        A) MODE=all ;;
        i) [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]] || { echo "-i needs a whole number of seconds" >&2; usage 1; }
           INTERVAL="$OPTARG" ;;
        f) STATE_FILTER="${OPTARG^^}" ;;
        n) if [[ "${OPTARG,,}" == all ]]; then TOP=0
           elif [[ "$OPTARG" =~ ^[0-9]+$ ]]; then TOP="$OPTARG"
           else echo "-n needs a number or 'all'" >&2; usage 1; fi ;;
        r) reference; exit 0 ;;
        h) usage 0 ;;
        :) echo "-$OPTARG needs a value" >&2; usage 1 ;;
        *) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
    esac
done

case "$MODE" in
    simple)    simple_report ;;
    advanced)  advanced_report ;;
    conntrack) conntrack_report ;;
    peers)     peers_report ;;
    bandwidth) bandwidth_report ;;
    all)       all_report ;;
esac