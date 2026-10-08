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
   *'"name":"tailscale-gateway"'*|*'"name": "tailscale-gateway"'*) echo '{"tailscale-gateway":{"instances":{"collector":{"running":true}}}}';;
   *) echo '{}';;
  esac;;
 /sbin/fw4)
  if [ "$1" = check ] && [ -e "$TSG_ROOT/fail-fw4" ]; then echo 'injected invalid firewall'; exit 1; fi;;
 /sbin/ip)
  if [ "$*" = '-4 -j rule show' ] && [ -f "$TSG_ROOT/rules4.json" ]; then cat "$TSG_ROOT/rules4.json"; else echo '[]'; fi;;
 /usr/bin/env)
  case "$1:$2" in TSG_DNS_INSTANCE=*:/usr/libexec/tailscale-gateway-dns) exit 0;; *) exit 96;; esac;;
 /etc/init.d/*|/usr/libexec/tailscale-gateway-dns) exit 0;;
 *) echo "Unmocked command: $cmd" >&2; exit 96;;
esac
