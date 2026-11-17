#!/bin/sh
#MISE description="Check Secure Enclave keys, the access group and the LaunchAgent with the installed Signd.app; a physical Mac only"
# GitHub-hosted runners have no Secure Enclave, so this runs on a Mac before each release.
# It uses /Applications/Signd.app, or the app SIGND_APP names, and the agent on ~/.ssh/signd.sock.
set -eu

app=${SIGND_APP:-/Applications/Signd.app}
signd=$app/Contents/MacOS/signd
work=$(mktemp -d)
name=e2e-hw-$$
export SSH_AUTH_SOCK=$HOME/.ssh/signd.sock

cleanup() {
  "$signd" key delete "$name" 2> /dev/null || true
  "$signd" config unset key-lifetime
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "✘ $1" >&2
  exit 1
}

agent_pid() {
  "$signd" status --json | plutil -extract agent.pid raw - 2> /dev/null
}

wait_for_agent() {
  tries=0
  until "$signd" status > /dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then fail "the agent did not answer in 5 seconds"; fi
    sleep 0.1
  done
}

sign_and_verify() {
  printf 'e2e\n' > "$work/message"
  rm -f "$work/message.sig"
  ssh-keygen -Y sign -f "$work/key.pub" -n e2e "$work/message" 2> /dev/null || fail "ssh-keygen -Y sign failed ($1)"
  printf 'e2e %s\n' "$(cut -d' ' -f1,2 "$work/key.pub")" > "$work/allowed"
  ssh-keygen -Y verify -f "$work/allowed" -I e2e -n e2e -s "$work/message.sig" < "$work/message" > /dev/null 2>&1 ||
    fail "the signature does not verify ($1)"
}

"$signd" service enable > /dev/null
"$signd" service enable > /dev/null
wait_for_agent
[ "$(pgrep -x -u "$(id -u)" signd | wc -l | tr -d ' ')" = 1 ] || fail "service enable twice left other than one agent"

"$signd" key create "$name" > "$work/key.pub"
grep -q '^ecdsa-sha2-nistp256 ' "$work/key.pub" || fail "key create printed no P-256 public key"
[ "$("$signd" key show "$name")" = "$(cat "$work/key.pub")" ] || fail "key show differs from key create"
ssh-add -L | grep -q "$(cut -d' ' -f2 "$work/key.pub")" || fail "ssh-add -L does not list the new key"
sign_and_verify "first signature"

locked=$(ioreg -n Root -d1 -a | plutil -extract IOConsoleLocked raw - 2> /dev/null || echo unknown)

old=$(agent_pid)
launchctl kickstart -k "gui/$(id -u)/com.victor-software-house.signd"
wait_for_agent
[ "$(agent_pid)" != "$old" ] || fail "the agent did not restart"
sign_and_verify "after a restart"

# A cask upgrade removes the job from launchd and leaves the login item enabled.
launchctl bootout "gui/$(id -u)/com.victor-software-house.signd"
"$signd" service enable > /dev/null
wait_for_agent
sign_and_verify "after service enable restored a removed job"

cat > "$work/probe.swift" << 'SWIFT'
import Foundation
import Security
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.victor-software-house.signd.key", kSecUseDataProtectionKeychain as String: true, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
var result: CFTypeRef?
print(SecItemCopyMatching(query as CFDictionary, &result))
SWIFT
xcrun swiftc -o "$work/probe" "$work/probe.swift"
status=$("$work/probe")
[ "$status" != 0 ] || fail "an ad-hoc signed probe read signd's keys"

"$signd" config set key-lifetime 1s
sign_and_verify "with a 1-second lifetime"
sleep 3
"$signd" status --json | grep -B1 "\"name\" : \"$name\"" | grep -q '"inMemory" : false' || fail "the key stayed in memory past its lifetime"

"$signd" key delete "$name"
if ssh-add -L 2> /dev/null | grep -q "$(cut -d' ' -f2 "$work/key.pub")"; then fail "the deleted key is still listed"; fi

echo "✔ Secure Enclave key created, listed, signed before and after an agent restart (screen locked: $locked), hidden from an ad-hoc probe (status $status), dropped from memory after its lifetime, and deleted"
