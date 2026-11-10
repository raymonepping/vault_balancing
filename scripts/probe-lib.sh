#!/usr/bin/env bash
# scripts/probe-lib.sh: helpers for scripts/probe.sh. Source, do not execute.
# api <token|-> <METHOD> <addr> <path> [json body]: sets ST (HTTP status),
# BODY (response) and ERR (Vault's errors[0], verbatim).
# Never prints a token.

# shellcheck disable=SC2034  # a sourced file: probe.sh reads ST, BODY, ERR and WAITED
api() {
  local tok=$1 method=$2 addr=$3 path=$4 body=${5:-} out args=()
  out=$(mktemp)
  args=(-sS --max-time 20 -o "$out" -w '%{http_code}' --cacert "$VAULT_CACERT" -X "$method")
  [ "$tok" = - ] || args+=(-H "X-Vault-Token: $tok")
  [ -z "$body" ] || args+=(-H 'Content-Type: application/json' -d "$body")
  ST=$(curl "${args[@]}" "$addr/v1/$path" 2>/dev/null || true)
  [ -n "$ST" ] || ST=000
  BODY=$(cat "$out")
  rm -f "$out"
  ERR=$(jq -r '.errors[0] // empty' <<<"$BODY" 2>/dev/null | tr '\n\t' '  ' | tr -s ' ' | sed 's/ *$//' || true)
}

row() { # <case> <act> <call> <expected> <answer> <yes|no>
  # Vault's errors carry "* " bullets: escape them, or Markdown reads emphasis.
  printf '| %s | %s | `%s` | %s | %s | %s |\n' "$1" "$2" "$3" "$4" "$(tr '|\n' '/ ' <<<"$5" | cut -c1-240 | sed 's/\*/\\*/g')" "$6" >>"$ROWS"
  if [ "$6" = yes ]; then
    pass=$((pass + 1))
    printf '  \033[32mPASS\033[0m %-4s %s (%s)\n' "$1" "$3" "$(cut -c1-120 <<<"$5")"
  else
    fail=$((fail + 1))
    printf '  \033[31mFAIL\033[0m %-4s %s (%s)\n' "$1" "$3" "$(cut -c1-180 <<<"$5")"
  fi
}

# expect <case> <act> <call> <expected> <want status regex> [jq test on BODY]
expect() {
  local c=$1 a=$2 call=$3 want=$4 st=$5 test=${6:-} ans
  ans="HTTP $ST${ERR:+: $ERR}"
  if [[ "$ST" =~ ^($st)$ ]] && { [ -z "$test" ] || jq -e "$test" <<<"$BODY" >/dev/null 2>&1; }; then
    row "$c" "$a" "$call" "$want" "$ans" yes
  else
    row "$c" "$a" "$call" "$want" "$ans" no
  fi
}

# record <case> <act> <call> <answer>: an observation the drill builds on,
# not a pass/fail expectation (always "yes": it was observed).
record() { row "$1" "$2" "$3" "observed" "$4" yes; }

# until_ok <seconds> <command...>: poll every 0.5 s; sets WAITED (seconds, one
# decimal) and returns 1 on timeout.
until_ok() {
  local max=$1 t0 now
  shift
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  while :; do
    if "$@" >/dev/null 2>&1; then
      now=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
      WAITED=$(perl -e "printf '%.1f', $now - $t0")
      return 0
    fi
    now=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    if perl -e "exit(($now - $t0) < $max ? 1 : 0)"; then
      WAITED=$max
      return 1
    fi
    sleep 0.5
  done
}

health_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$VAULT_CACERT" "$1/v1/sys/health" || true; }
