#!/bin/sh
#MISE description="Run the built agent on a temporary socket and drive it with ssh-add and ssh-keygen, and check the SSH routing files with ssh -G; macOS only"
#MISE depends=["build"]
# The build is unsigned here, so the keychain store is unavailable and the agent serves
# only keys that ssh-add adds; signd's Secure Enclave keys are checked by e2e:hardware.
set -eu

bin=$(swift build --show-bin-path)/signd
work=$(mktemp -d)
socket=$work/s.sock
pid=

stop() {
  if [ -n "$pid" ]; then
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
    pid=
  fi
}

cleanup() {
  stop
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "✘ $1" >&2
  exit 1
}

start() {
  "$bin" serve --socket "$socket" 2>> "$work/agent.log" &
  pid=$!
  tries=0
  until SSH_AUTH_SOCK=$socket ssh-add -l > /dev/null 2>&1 || [ $? -eq 1 ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then fail "the agent did not answer in 5 seconds"; fi
    sleep 0.1
  done
}

export SSH_AUTH_SOCK="$socket"
start

[ "$(stat -f %Lp "$socket")" = 600 ] || fail "the socket mode is $(stat -f %Lp "$socket"), not 600"

printf 'e2e\n' > "$work/message"
for type in ed25519 ecdsa rsa; do
  ssh-keygen -q -t "$type" -N '' -C "e2e-$type" -f "$work/$type"
  ssh-add -q "$work/$type" 2> /dev/null || fail "ssh-add refused the $type key"
  ssh-add -L | grep -q "e2e-$type" || fail "ssh-add -L does not list the $type key"
  ssh-keygen -Y sign -f "$work/$type.pub" -n e2e "$work/message" 2> /dev/null || fail "ssh-keygen -Y sign failed with the $type key"
  printf 'e2e %s\n' "$(cut -d' ' -f1,2 "$work/$type.pub")" > "$work/allowed"
  ssh-keygen -Y verify -f "$work/allowed" -I e2e -n e2e -s "$work/message.sig" < "$work/message" > /dev/null 2>&1 ||
    fail "the $type signature does not verify"
  rm "$work/message.sig"
done

if ssh-add -x < /dev/null > /dev/null 2>&1; then fail "the agent accepted lock"; fi
ssh-keygen -Y sign -f "$work/ed25519.pub" -n e2e "$work/message" 2> /dev/null || fail "signing stopped after a refused lock"
rm "$work/message.sig"

ssh-add -D > /dev/null 2>&1 || fail "ssh-add -D failed"
if ssh-add -L > /dev/null 2>&1; then fail "ssh-add -D left keys"; fi

if ssh-add -c "$work/ed25519" > /dev/null 2>&1; then fail "the agent accepted a confirm constraint"; fi
ssh-add -q -t 2 "$work/ed25519" 2> /dev/null || fail "ssh-add -t refused the key"
ssh-add -L | grep -q e2e-ed25519 || fail "the key with a lifetime is not listed"
sleep 3
if ssh-add -L > /dev/null 2>&1; then fail "the key outlived its 2-second lifetime"; fi

# A length prefix of 300 KiB closes that connection; the agent keeps serving others.
perl -e 'print pack("N", 300 * 1024)' | nc -U "$socket" > /dev/null 2>&1 || true
ssh-add -q "$work/ed25519" 2> /dev/null || fail "the agent stopped serving after an oversized message"

stop
start
ssh-add -l > /dev/null 2>&1 || [ $? -eq 1 ] || fail "the agent did not restart over its stale socket"

"$bin" status --socket "$socket" --json > "$work/status.json" || fail "signd status did not reach the agent"
grep -q '"agentAnswers" : true' "$work/status.json" || fail "signd status reports no agent"

# SSH routing. The unsigned agent has no keychain, so it holds no key with hosts; a test writes the
# files into a temporary home, once with every key and once with one key's last host removed.
home=$work/home
mkdir -p "$home"
printf 'Include %s/.ssh/signd/config\n' "$home" > "$work/ssh_config"
# ssh expands ~ from the password database, not from HOME.
passwd_home=$(id -P | cut -d: -f9)

routing() {
  if ! SIGND_E2E_ROUTING_HOME="$home" SIGND_E2E_ROUTING_STEP="$1" swift test --filter writesTheFilesForTheShellScenarios > "$work/routing.log" 2>&1; then
    cat "$work/routing.log" >&2
    fail "the routing test failed at step $1"
  fi
}

ssh_g() {
  ssh -F "$work/ssh_config" -G "$1" 2> /dev/null
}

routing 1
[ "$(stat -f %Lp "$home/.ssh/signd")" = 700 ] || fail "~/.ssh/signd is not mode 700"
[ "$(stat -f %Lp "$home/.ssh/signd/config")" = 600 ] || fail "~/.ssh/signd/config is not mode 600"
[ "$(stat -f %Lp "$home/.ssh/signd/deploy.pub")" = 644 ] || fail "a public file is not mode 644"
ssh_g git.example.com > "$work/g1"
grep -q "^identityagent $passwd_home/.ssh/signd.sock$" "$work/g1" || fail "ssh -G does not name signd's socket for a routed host"
grep -q '^identityfile .*/.ssh/signd/deploy.pub$' "$work/g1" || fail "ssh -G does not name the first key's public file"
grep -q '^identityfile .*/.ssh/signd/other.pub$' "$work/g1" || fail "ssh -G does not name the second key for a host two keys share"
grep -q '^identitiesonly yes$' "$work/g1" || fail "ssh -G does not set identitiesonly"
ssh_g files.example.org > "$work/g2"
grep -q '^identityfile .*/.ssh/signd/other.pub$' "$work/g2" || fail "a wildcard host does not use its key"
if grep -q 'deploy.pub' "$work/g2"; then fail "a wildcard host uses a key not meant for it"; fi
ssh_g unrouted.example.net > "$work/g3"
if grep -q '^identityagent ' "$work/g3"; then fail "a host with no key got signd's socket"; fi
if grep -q 'ProxyCommand' "$home/.ssh/signd/config"; then fail "a host pattern with a space was written"; fi
[ ! -e "$home/.ssh/signd/bad.pub" ] || fail "the key with a bad host pattern has a public file"

routing 2
ssh_g git.example.com > "$work/g4"
if grep -q 'deploy.pub' "$work/g4"; then fail "a key whose last host was removed still routes"; fi
[ ! -e "$home/.ssh/signd/deploy.pub" ] || fail "the public file of a key with no hosts remains"
grep -q '^identityfile .*/.ssh/signd/other.pub$' "$work/g4" || fail "the remaining key stopped routing"

echo "✔ the agent served ed25519, ecdsa and rsa keys added by ssh-add, refused lock and confirm, honoured lifetimes and ssh-add -D, and survived an oversized message and a restart; the routing files give ssh -G the socket and key of each host, keep to modes 700, 600 and 644, drop a bad host pattern, and follow a removed host"
