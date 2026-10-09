#!/bin/sh
# All commands from a TSG_ROOT run terminate here. Never fall through to a
# live networking command, even when a test forgets to provide a fixture.
set -eu
printf '%s\n' "$*" >>"$TSG_ROOT/commands.log"
cmd=$1; shift
case "$cmd" in
 /bin/mkdir|/bin/rm)
  for arg in "$@"; do case "$arg" in -*) ;; "$TSG_ROOT"/*) ;; *) exit 95;; esac; done
  exec "$cmd" "$@";;
 /usr/sbin/tailscale|/usr/bin/tailscale)
  case "$1" in
   status) cat "$TSG_ROOT/status.json";;
   debug) cat "$TSG_ROOT/prefs.json";;
   set) /usr/bin/ucode /tmp/tsg-dev/tests/fake-set.uc "$TSG_ROOT/prefs.json" "$@";;
   *) exit 0;;
  esac;;
 /bin/ubus)
  case "$*" in
   'call network.interface dump') cat "$TSG_ROOT/interfaces.json";;
   *'"name":"tailscale-gateway"'*|*'"name": "tailscale-gateway"'*)
    remote=$(uci -c "$TSG_ROOT/etc/config" -P "$TSG_ROOT/tmp/tsg-read" -q get tailscale_gateway.access.remote_enabled || true)
    managed=$(uci -c "$TSG_ROOT/etc/config" -P "$TSG_ROOT/tmp/tsg-read" -q get tailscale_gateway.main.managed || true)
    subnets=false; [ "$remote:$managed" != 1:1 ] || subnets=true
    printf '{"tailscale-gateway":{"instances":{"collector":{"running":true},"subnets":{"running":%s}}}}\n' "$subnets";;
   *) echo '{}';;
  esac;;
 /sbin/fw4)
  if [ "$1" = check ] && [ -e "$TSG_ROOT/fail-fw4" ]; then echo 'injected invalid firewall'; exit 1; fi;;
 /usr/sbin/nft)
  [ ! -e "$TSG_ROOT/fail-nft" ] || exit 1
  [ "$1" = -f ] || exit 96
  cat "$2" >"$TSG_ROOT/last-nft.txt";;
 /sbin/ip)
  if [ "$*" = '-4 -j route show table 52' ]; then
    [ ! -e "$TSG_ROOT/fail-routes" ] || exit 1
    if [ -f "$TSG_ROOT/routes4.json" ]; then cat "$TSG_ROOT/routes4.json"; else echo '[]'; fi
    exit 0
  fi
  if [ "$*" = '-4 -j rule show' ] && [ -f "$TSG_ROOT/rules4.json" ]; then cat "$TSG_ROOT/rules4.json"; else echo '[]'; fi;;
 /usr/bin/env)
  case "$1:$2" in TSG_DNS_INSTANCE=*:/usr/libexec/tailscale-gateway-dns) exit 0;; *) exit 96;; esac;;
 /etc/init.d/*|/usr/libexec/tailscale-gateway-dns) exit 0;;
 *) echo "Unmocked command: $cmd" >&2; exit 96;;
esac
