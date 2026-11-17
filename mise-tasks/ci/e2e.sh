#!/bin/sh
#MISE description="Serve a throwaway RSA key from a temporary keychain: ssh-add lists it, ssh-keygen signs with it, and the keychain refuses to export it; macOS only"
#MISE depends=["build"]
# The temporary keychain joins the user's search list for the test, and the original
# list comes back when the script exits, pass or fail.
set -eu

bin=$(swift build --show-bin-path)/keychain-agent
work=$(mktemp -d)
keychain=$work/e2e.keychain-db
password=e2e
label=keychain-agent-e2e
original=$(security list-keychains -d user | tr -d '"')
pid=

cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
  fi
  # shellcheck disable=SC2086 # one path per word
  security list-keychains -d user -s $original
  security delete-keychain "$keychain" 2> /dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "✘ $1" >&2
  cat "$work/agent.log" >&2
  exit 1
}

security create-keychain -p "$password" "$keychain"
security unlock-keychain -p "$password" "$keychain"
# No timeout: the keychain stays unlocked for the whole test.
security set-keychain-settings "$keychain"
# shellcheck disable=SC2086 # one path per word
security list-keychains -d user -s "$keychain" $original

openssl req -x509 -newkey rsa:3072 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 1 -subj "/CN=$label" 2> /dev/null
ssh-keygen -y -f "$work/key.pem" | cut -d' ' -f1,2 > "$work/expected.pub"
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$label" -passout pass:e2e -out "$work/key.p12"
rm "$work/key.pem"
security import "$work/key.p12" -k "$keychain" -P e2e -x -A > /dev/null
cdhash=$(codesign -dvvv "$bin" 2>&1 | awk -F= '/^CDHash=/ { print $2 }')
security set-key-partition-list -S "cdhash:$cdhash" -l "$label" -k "$password" "$keychain" > /dev/null

"$bin" --socket "$work/agent.sock" "$label" 2> "$work/agent.log" &
pid=$!
tries=0
while [ ! -S "$work/agent.sock" ]; do
  tries=$((tries + 1))
  if [ "$tries" -gt 50 ]; then fail "the agent made no socket in 5 seconds"; fi
  sleep 0.1
done
export SSH_AUTH_SOCK="$work/agent.sock"

listed=$(ssh-add -L | cut -d' ' -f1,2)
[ "$listed" = "$(cat "$work/expected.pub")" ] || fail "ssh-add -L listed '$listed'"

printf 'e2e\n' > "$work/message"
ssh-keygen -Y sign -f "$work/expected.pub" -n e2e "$work/message" 2> /dev/null || fail "ssh-keygen -Y sign failed"
printf 'e2e %s\n' "$(cat "$work/expected.pub")" > "$work/allowed"
ssh-keygen -Y verify -f "$work/allowed" -I e2e -n e2e -s "$work/message.sig" < "$work/message" > /dev/null ||
  fail "the signature does not verify"

if security export -k "$keychain" -t privKeys -f pkcs12 -P e2e -o "$work/out.p12" 2> /dev/null; then
  fail "the keychain exported the key"
fi

echo "✔ the agent listed and signed with the key, and the keychain refused to export it"
