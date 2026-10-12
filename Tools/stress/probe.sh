#!/bin/bash
# TEMPORARY stress probe, stress branch only.
# usage: probe.sh MODE FREE TRIALS PARALLEL
#   race   : count trials whose pane dialed fewer than 2 times in the first 4s
#   select : the fixed test's logic: wait for the hold announcement, touch the marker,
#            time the redial
set -u
MODE=$1; FREE=$2; TRIALS=$3; PAR=$4
RENDER=${RENDER:-./render}
WORK=$(mktemp -d)
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
count() { wc -l <"$1" 2>/dev/null | tr -d ' '; }

trial() {
  local d=$WORK/t$1; mkdir -p "$d"
  local log=$d/dials marker=$d/marker out=$d/out
  local script; script=$($RENDER "$FREE" 120 180 "$log" "$marker")
  /bin/sh -c "$script" </dev/null >"$out" 2>/dev/null &
  local pid=$!
  if [ "$MODE" = race ]; then
    sleep 4
    echo "$(count "$log")" >"$d/result"
  else
    local t0; t0=$(now); local held=""
    for _ in $(seq 1 600); do
      if grep -Eq 'Retrying in ([6-9][0-9]|[1-9][0-9][0-9])s' "$out" 2>/dev/null; then held=1; break; fi
      sleep 0.1
    done
    if [ -z "$held" ]; then
      echo "nohold" >"$d/result"
    else
      local th; th=$(now)
      local before; before=$(count "$log")
      touch "$marker"
      local t1; t1=$(now); local ok=""
      for _ in $(seq 1 400); do
        if [ "$(count "$log")" -gt "$before" ]; then ok=1; break; fi
        sleep 0.05
      done
      local t2; t2=$(now)
      if [ -n "$ok" ]; then
        echo "ok $(awk -v a="$th" -v b="$t0" 'BEGIN{printf "%.3f", a-b}') $(awk -v a="$t2" -v b="$t1" 'BEGIN{printf "%.3f", a-b}') $before" >"$d/result"
      else
        echo "noredial" >"$d/result"
      fi
    fi
  fi
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

i=0
while [ "$i" -lt "$TRIALS" ]; do
  j=0
  while [ "$j" -lt "$PAR" ] && [ "$i" -lt "$TRIALS" ]; do
    i=$((i + 1)); j=$((j + 1))
    trial "$i" &
  done
  wait
done

if [ "$MODE" = race ]; then
  bad=0
  for f in "$WORK"/t*/result; do
    n=$(cat "$f"); [ "${n:-0}" -lt 2 ] && bad=$((bad + 1))
  done
  echo "RESULT mode=race free=$FREE parallel=$PAR trials=$TRIALS fewer_than_2_dials_in_4s=$bad"
else
  ok=$(cat "$WORK"/t*/result | grep -c '^ok')
  nohold=$(cat "$WORK"/t*/result | grep -c '^nohold')
  noredial=$(cat "$WORK"/t*/result | grep -c '^noredial')
  hold=$(cat "$WORK"/t*/result | awk '$1=="ok"{print $2}' | sort -n | awk '{a[NR]=$1} END{if(NR) printf "min=%s median=%s max=%s", a[1], a[int((NR+1)/2)], a[NR]}')
  lat=$(cat "$WORK"/t*/result | awk '$1=="ok"{print $3}' | sort -n | awk '{a[NR]=$1} END{if(NR){p=int(NR*0.95); if(p<1)p=1; printf "min=%s median=%s p95=%s max=%s", a[1], a[int((NR+1)/2)], a[p], a[NR]}}')
  echo "RESULT mode=select free=$FREE parallel=$PAR trials=$TRIALS ok=$ok nohold=$nohold noredial=$noredial"
  echo "RESULT   seconds-to-hold-announcement: $hold"
  echo "RESULT   seconds-from-marker-touch-to-redial: $lat"
fi
rm -rf "$WORK"
