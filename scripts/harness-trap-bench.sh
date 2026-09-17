#!/bin/bash
# Bench for the harness trap question. Builds two script shapes, runs each under five conditions,
# and reports whether cleanup ran. No disk images: a marker file stands in for an acquired resource,
# which makes the run fast and the assertion exact.
#
# The two lessons from the failed attempt are encoded as assertions, not as care:
#   1. PRECONDITION — every case starts by proving the resource does not already exist. A case that
#      begins dirty measures the previous case.
#   2. CAPTURE — the script's stdout/stderr go to a file that is read on failure. Three earlier
#      attempts ran with stdout on /dev/null and read "no cleanup message" as "nothing to clean".
set -u
RIG=/private/tmp/xcv-rig
rm -rf "$RIG"; mkdir -p "$RIG"

# shape A: today's harness — body is a brace group in a pipeline
# shape B: proposed — body is a function, output redirected, no pipe
write_script() {
  local shape="$1" path="$2" res="$3" log="$4"
  {
    echo '#!/bin/bash'
    echo "RES=$res"
    echo 'cleanup() { rm -f "$RES"; echo CLEANED >> '"$log"'; }'
    if [ "$shape" = A ]; then
      echo 'trap cleanup EXIT INT TERM HUP'
      echo '{ : > "$RES"; echo ACQUIRED >> '"$log"'; sleep 30; } 2>&1 | cat'
    else
      echo 'main() { : > "$RES"; echo ACQUIRED >> '"$log"'; sleep 30; }'
      echo 'trap cleanup EXIT INT TERM HUP'
      echo 'main > '"$log"'.raw 2>&1'
    fi
  } > "$path"
  chmod +x "$path"
}

probe() {  # probe <shape> <condition>
  local shape="$1" cond="$2"
  local s="$RIG/s.sh" res="$RIG/resource" log="$RIG/log" out="$RIG/out"
  rm -f "$s" "$res" "$log" "$log.raw" "$out"

  # (1) PRECONDITION, asserted rather than assumed.
  if [ -e "$res" ]; then echo "  $shape/$cond: PRECONDITION FAILED (resource pre-exists)"; return; fi

  write_script "$shape" "$s" "$res" "$log"
  if [ "$cond" = group ]; then
    perl -e 'setpgrp(0,0); exec @ARGV' "$s" > "$out" 2>&1 &
  else
    "$s" > "$out" 2>&1 &
  fi
  local pid=$! i
  # Wait for the resource to actually be acquired; without this we may signal before there is
  # anything to clean, and a pass would mean nothing.
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$res" ] && break; sleep 0.5; done
  if [ ! -e "$res" ]; then echo "  $shape/$cond: INVALID (resource never acquired)"; kill "$pid" 2>/dev/null; return; fi

  case "$cond" in
    normal)      kill -TERM "$pid" 2>/dev/null; sleep 1; rm -f "$s" "$res"; echo "  $shape/normal      : (see normal-exit row)"; return;;
    term-parent) kill -TERM "$pid" 2>/dev/null;;
    term-all)    pkill -TERM -f "$RIG/s.sh" 2>/dev/null;;
    group)       kill -INT "-$(ps -o pgid= -p "$pid" | tr -d ' ')" 2>/dev/null;;
    int-parent)  kill -INT "$pid" 2>/dev/null;;
  esac
  sleep 4

  local cleaned="no" leftover="yes"
  grep -q CLEANED "$log" 2>/dev/null && cleaned="YES"
  [ -e "$res" ] || leftover="no"
  printf '  %s/%-12s cleanup=%-3s recurso-vazou=%s\n' "$shape" "$cond" "$cleaned" "$leftover"
  # (2) CAPTURE — on a bad outcome, show what the run actually said.
  if [ "$cleaned" != "YES" ] && [ -s "$out" ]; then
    echo "      saída: $(head -2 "$out" | tr '\n' ' ' | cut -c1-70)"
  fi
  pkill -f "$RIG/s.sh" 2>/dev/null
  rm -f "$s" "$res" "$log" "$log.raw" "$out"
}

normal_exit() {  # cleanup on a run that simply finishes
  local shape="$1" s="$RIG/n.sh" res="$RIG/nres" log="$RIG/nlog"
  rm -f "$s" "$res" "$log" "$log.raw"
  [ -e "$res" ] && { echo "  $shape/normal: PRECONDITION FAILED"; return; }
  {
    echo '#!/bin/bash'
    echo "RES=$res"
    echo 'cleanup() { rm -f "$RES"; echo CLEANED >> '"$log"'; }'
    if [ "$shape" = A ]; then
      echo 'trap cleanup EXIT INT TERM HUP'
      echo '{ : > "$RES"; sleep 1; } 2>&1 | cat'
    else
      echo 'main() { : > "$RES"; sleep 1; }'
      echo 'trap cleanup EXIT INT TERM HUP'
      echo 'main > '"$log"'.raw 2>&1'
    fi
  } > "$s"; chmod +x "$s"
  "$s" >/dev/null 2>&1; sleep 1
  local cleaned="no"; grep -q CLEANED "$log" 2>/dev/null && cleaned="YES"
  printf '  %s/%-12s cleanup=%-3s recurso-vazou=%s\n' "$shape" "normal" "$cleaned" "$([ -e "$res" ] && echo yes || echo no)"
  rm -f "$s" "$res" "$log" "$log.raw"
}

echo "A = forma atual   { ... } | cat          (trap no pai)"
echo "B = proposta      main > arquivo         (trap no pai, sem pipeline)"
echo
for shape in A B; do
  normal_exit "$shape"
  for cond in term-parent term-all int-parent group; do probe "$shape" "$cond"; done
  echo
done
rm -rf "$RIG"
