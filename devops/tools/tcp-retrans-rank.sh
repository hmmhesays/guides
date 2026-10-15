#!/bin/bash
# Rank current TCP connections by lifetime retransmits.
#
# Modes:
#   -s  simple    retransmits, segments sent, percent, local -> peer, process
#   -a  advanced  adds direction and TCP state; direction inferred from listening ports (default)
#   -c  conntrack like advanced, but direction is confirmed from the conntrack table where possible
#
# Options:
#   -n N  show the top N connections (default 20)
#   -h    show this help
#
# Run as root so process names (and conntrack) are visible.

set -o pipefail

TOP=20
MODE=advanced

usage() {
    sed -n '2,/^$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# Prints "C <line>" for each line of ss -tinpH, for awk to consume.
ss_connections() {
    ss -tinpH | sed 's/^/C /'
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

sort_and_trim() {
    sort -rn | head -n "$TOP"
}

# Shared awk helpers for parsing ss output.
AWK_COMMON='
function proc_name(line,    p) {
    p = "-"
    if (match(line, /users:\(\("[^"]+"/)) p = substr(line, RSTART + 9, RLENGTH - 10)
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
'

simple_report() {
    printf "%8s %10s %9s  %-50s %s\n" RETRANS SEGS_OUT PCT "LOCAL -> PEER" PROCESS
    ss_connections | awk "$AWK_COMMON"'
    { sub(/^C /, "") }
    /^[A-Z]/ { conn = $4 " -> " $5; proc = proc_name($0); next }
    {
        r = retrans_total($0); if (r < 0) next
        o = segs_out($0)
        printf "%8d %10d %8.2f%%  %-50s %s\n", r, o, pct(r, o), conn, proc
    }' | sort_and_trim
}

# Shared by advanced and conntrack modes. Pass "1" to use conntrack.
direction_report() {
    local use_ct="$1"
    printf "%8s %10s %9s  %-4s %-10s  %-50s %s\n" RETRANS SEGS_OUT PCT DIR STATE "INITIATOR -> ACCEPTOR" PROCESS
    {
        listening_ports
        [ "$use_ct" = 1 ] && conntrack_tuples
        ss_connections
    } | awk "$AWK_COMMON"'
    $1 == "L" { listen[$2] = 1; next }
    $1 == "T" { ct[$2 "|" $3 "|" $4 "|" $5] = 1; next }
    { sub(/^C /, "") }
    /^[A-Z]/ {
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
    {
        r = retrans_total($0); if (r < 0) next
        o = segs_out($0)
        printf "%8d %10d %8.2f%%  %-4s %-10s  %-50s %s\n", r, o, pct(r, o), dir, state, conn, proc
    }' | sort_and_trim
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

while getopts ":sacn:h" opt; do
    case "$opt" in
        s) MODE=simple ;;
        a) MODE=advanced ;;
        c) MODE=conntrack ;;
        n) [[ "$OPTARG" =~ ^[0-9]+$ ]] || { echo "-n needs a number" >&2; usage 1; }
           TOP="$OPTARG" ;;
        h) usage 0 ;;
        :) echo "-$OPTARG needs a value" >&2; usage 1 ;;
        *) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
    esac
done

case "$MODE" in
    simple)    simple_report ;;
    advanced)  advanced_report ;;
    conntrack) conntrack_report ;;
esac