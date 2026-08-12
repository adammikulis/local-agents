#!/usr/bin/env bash
# Per-chunk temp file + exit-code check, so a truncated transfer is retried rather than appended twice.
set -uo pipefail
cd "$(dirname "$0")"
PARAMS="molec_id,local_iso_id,nu,sw,gamma_air,n_air,elower"
fetch() {  # $1 out  $2 isos  $3 lo  $4 hi  $5 step
  : > "$1"
  for lo in $(seq "$3" "$5" $(( $4 - $5 ))); do
    hi=$((lo + $5))
    ok=0
    for try in 1 2 3 4 5; do
      if curl -sS -m 600 --retry 0 --ignore-content-length -g -o chunk.tmp \
        "https://hitran.org/lbl/api?iso_ids_list=$2&numin=$lo&numax=$hi&head=false&fixwidth=0&sep=%5Bcomma%5D&request_params=$PARAMS"; then
        ok=1; break
      fi
      sleep 5
    done
    [ "$ok" -eq 1 ] || { echo "FETCH_FAILED $1 $lo-$hi"; return 1; }
    cat chunk.tmp >> "$1"
    echo "  $1 $lo-$hi $(wc -l < "$1")"
  done
  return 0
}
fetch co2_lines.csv "7,8,9,10,11,12" 0 10000 250 || exit 1
fetch h2o_lines.csv "1,2,3,4" 0 10000 250 || exit 1
echo FETCH_ALL_DONE
curl -sSL -m 300 --ignore-content-length -o CO2-CO2_2024.cia \
  "https://hitran.org/data/CIA/main/CO2-CO2_2024.cia" || exit 1
echo CIA_DONE
