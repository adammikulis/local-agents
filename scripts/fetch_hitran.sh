#!/usr/bin/env bash
# Per-chunk temp file + exit-code check, so a truncated transfer is retried rather than appended twice.
set -uo pipefail
cd "$(dirname "$0")"
PARAMS="molec_id,local_iso_id,nu,sw,gamma_air,n_air,elower"
fetch() {  # $1 out  $2 isos  $3 lo  $4 hi  $5 step   (appends; truncate before the first call)
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
    # A window holding zero lines comes back as an HTML 404 page, not an empty body; keep CSV only.
    if head -c 1 chunk.tmp | grep -q '<'; then
      echo "  $1 $lo-$hi empty window"
    else
      cat chunk.tmp >> "$1"
      echo "  $1 $lo-$hi $(wc -l < "$1")"
    fi
  done
  return 0
}
# Dense rotation-vibration ranges in 250 cm^-1 chunks; the sparse near-IR tails in 500.
: > co2_lines.csv
fetch co2_lines.csv "7,8,9,10,11,12" 0 10000 250 || exit 1
fetch co2_lines.csv "7,8,9,10,11,12" 10000 13000 500 || exit 1
: > h2o_lines.csv
fetch h2o_lines.csv "1,2,3,4" 0 10000 250 || exit 1
fetch h2o_lines.csv "1,2,3,4" 10000 26000 500 || exit 1
: > o3_lines.csv
fetch o3_lines.csv "16,17,18,19,20" 0 7000 250 || exit 1
# The minor greenhouse gases (HITRAN global isotopologue ids). H2 has no dipole and no line list here.
: > ch4_lines.csv
fetch ch4_lines.csv "32,33,34,35" 0 10000 250 || exit 1
fetch ch4_lines.csv "32,33,34,35" 10000 11500 500 || exit 1
: > co_lines.csv
fetch co_lines.csv "26,27,28,29,30,31" 0 9000 500 || exit 1
: > so2_lines.csv
fetch so2_lines.csv "42,43" 0 4500 250 || exit 1
: > h2s_lines.csv
fetch h2s_lines.csv "81,82,83" 0 11500 500 || exit 1
echo FETCH_ALL_DONE
curl -sSL -m 300 --ignore-content-length -o CO2-CO2_2024.cia \
  "https://hitran.org/data/CIA/main/CO2-CO2_2024.cia" || exit 1
echo CIA_DONE
# O3 electronic bands (Hartley, Huggins, Chappuis, Wulf), 213-1100 nm at 11 temperatures 193-293 K:
# Serdyuchenko et al. 2014, AMT 7:625; Gorshelev et al. 2014, AMT 7:609. HITRAN's UV cross-section
# downloads sit behind a login; this is the same dataset from its authors' own server.
curl -sSL -m 600 --ignore-content-length -o o3_uv_serdyuchenko.dat \
  "https://www.iup.uni-bremen.de/gruppen/molspec/downloads/serdyuchenkogorshelev5digits.dat" || exit 1
echo O3_UV_DONE
