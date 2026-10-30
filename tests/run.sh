#!/bin/sh
# Test of flash-apply.php on a fake flash. Needs php (dom, mbstring) and script(1) for a terminal.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d)
export FLASH_APPLY_ROOT="$root"
export FLASH_APPLY_PROPOSALS=/proposals
tpl="$root/boot/config/plugins/dockerMan/templates-user"
props="$root/proposals"
mkdir -p "$tpl" "$props" "$root/etc"
echo 'version="7.3.4"' > "$root/etc/unraid-version"
SECRET=fake-existing-secret-value
fails=0

reset_template() {
  cat > "$tpl/my-app.xml" <<X
<?xml version="1.0"?>
<Container version="2">
  <Name>app</Name>
  <Repository>old/image:1</Repository>
  <Network>bridge</Network>
  <Privileged>false</Privileged>
  <ExtraParams>--secret-param=$SECRET</ExtraParams>
  <Config Name="Token" Target="TOKEN" Default="" Mode="" Description="" Type="Variable" Display="always" Required="false" Mask="true">$SECRET</Config>
  <Config Name="Keep" Target="KEEP" Default="" Mode="" Description="" Type="Variable" Display="always" Required="false" Mask="false">kept</Config>
  <Config Name="App" Target="/app" Default="" Mode="ro" Description="" Type="Path" Display="always" Required="false" Mask="false">/mnt/user/appdata/app/app</Config>
</Container>
X
  rm -rf "$root/boot/config/flash-apply-backups"
}

# run <name> <proposal json> <typed answer>: sets out and code. Runs under a terminal, as a person would.
run() {
  printf '%s' "$2" > "$props/$1.json"
  out=$(printf '%s\n' "$3" | script -qec "php '$here/flash-apply.php' '$1.json'" /dev/null 2>&1)
  code=$?
}

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n%s\n' "$1" "$out"; fails=$((fails + 1)); }
expect() { if printf '%s' "$out" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
never() { if printf '%s' "$out" | grep -qF -- "$2"; then bad "$1 (found: $2)"; else ok "$1"; fi; }
file_has() { if grep -qF -- "$2" "$tpl/my-app.xml"; then ok "$1"; else out=$(cat "$tpl/my-app.xml"); bad "$1 (file lacks: $2)"; fi; }
file_lacks() { if grep -qF -- "$2" "$tpl/my-app.xml"; then out=$(cat "$tpl/my-app.xml"); bad "$1 (file has: $2)"; else ok "$1"; fi; }
unchanged() { if grep -qF -- 'old/image:1' "$tpl/my-app.xml" && ! grep -qF -- 'NEWVAR' "$tpl/my-app.xml"; then ok "$1"; else out=$(cat "$tpl/my-app.xml"); bad "$1"; fi; }

# --- an ordinary change
reset_template
run p1 '{"template":"my-app.xml","summary":"test","variables":{"set":{"TOKEN":"new-token","NEWVAR":"v"},"remove":["GONE"]},"paths":{"remove":["/app"]}}' apply
expect "applied" "Written."
never "existing secret is never printed" "$SECRET"
expect "summary marked unverified" "not verified"
file_has "variable changed" ">new-token<"
file_has "variable added" 'Target="NEWVAR"'
file_has "other variable kept" ">kept<"
file_lacks "path removed" 'Target="/app"'
file_has "untouched secret param kept" "--secret-param=$SECRET"
if ls "$root/boot/config/flash-apply-backups/" | grep -q my-app; then ok "backup written"; else bad "backup written"; fi
if [ -f "$props/p1.json.applied" ]; then ok "proposal marked applied"; else bad "proposal marked applied"; fi

# --- confirmation
reset_template
run p2 '{"template":"my-app.xml","variables":{"set":{"NEWVAR":"v"}}}' no
expect "wrong answer stops" "Nothing was changed"
unchanged "wrong answer changes nothing"

reset_template
run p3 '{"template":"my-app.xml","set":{"Repository":"new/image:2"}}' apply
expect "dangerous needs the longer phrase" "apply dangerous"
unchanged "plain apply doesn't confirm a dangerous change"
run p3 '{"template":"my-app.xml","set":{"Repository":"new/image:2"}}' "apply dangerous"
file_has "dangerous applied with the phrase" "new/image:2"

reset_template
printf '%s' '{"template":"my-app.xml","variables":{"set":{"NEWVAR":"v"}}}' > "$props/p4.json"
out=$(printf 'apply\n' | php "$here/flash-apply.php" p4.json 2>&1); code=$?
expect "no terminal is refused" "person at a terminal"
unchanged "no terminal changes nothing"

# --- warnings
reset_template
for case in \
  '{"template":"my-app.xml","set":{"Privileged":"true"}}|privileged mode' \
  '{"template":"my-app.xml","set":{"ExtraParams":"--cap-add=ALL"}}|Extra Parameters' \
  '{"template":"my-app.xml","paths":{"set":[{"container":"/s","host":"/var/run/docker.sock","mode":"rw"}]}}|control of Docker' \
  '{"template":"my-app.xml","paths":{"set":[{"container":"/b","host":"/boot","mode":"ro"}]}}|host system folder' \
  '{"template":"my-app.xml","paths":{"set":[{"container":"/m","host":"/mnt/user","mode":"rw"}]}}|whole disk or share' \
  '{"template":"my-app.xml","variables":{"set":{"LD_PRELOAD":"/x.so"}}}|can change what code runs' \
  '{"template":"my-app.xml","ports":{"set":[{"container":80,"host":8081,"protocol":"tcp"}]}}|publishes the container'; do
  run w "${case%|*}" stop
  expect "warns: ${case#*|}" "${case#*|}"
  never "old ExtraParams value hidden" "$SECRET"
done

# --- refused proposals
reset_template
for case in \
  '{"template":"../my-app.xml"}|my-*.xml' \
  '{"template":"other.xml"}|my-*.xml' \
  '{"template":"my-missing.xml"}|not found' \
  '{"template":"my-app.xml","surprise":1}|unknown fields' \
  '{"template":"my-app.xml","set":{"Name":"x"}}|unknown fields' \
  '{"template":"my-app.xml","variables":{"set":{"BAD NAME":"x"}}}|Bad variable' \
  '{"template":"my-app.xml","variables":{"set":{"A":"x\u001b[2J"}}}|control characters' \
  '{"template":"my-app.xml","summary":"hide‮this"}|control characters' \
  '{"template":"my-app.xml","paths":{"set":[{"container":"/x","host":"/mnt/user/../../etc","mode":"rw"}]}}|without ..' \
  '{"template":"my-app.xml","paths":{"set":[{"container":"/x","host":"/ok","mode":"weird"}]}}|Bad path mode' \
  '{"template":"my-app.xml","ports":{"set":[{"container":"80;x","host":1}]}}|port number' \
  'not json|valid JSON'; do
  run r "${case%|*}" apply
  expect "refused: ${case%|*}" "${case#*|}"
  unchanged "nothing written: ${case%|*}"
done

out=$(script -qec "php '$here/flash-apply.php' '../evil.json'" /dev/null 2>&1)
expect "refuses a path as proposal name" "without a path"
ln -sf "$props/p2.json" "$props/link.json"
out=$(script -qec "php '$here/flash-apply.php' link.json" /dev/null 2>&1)
expect "refuses a linked proposal" "is a link"

# --- unRAID version gate
reset_template
for v in 'version="8.0.0"' 'version="6.12.1"' 'nonsense'; do
  echo "$v" > "$root/etc/unraid-version"
  run v '{"template":"my-app.xml","variables":{"set":{"NEWVAR":"v"}}}' apply
  expect "version gate refuses: $v" "Refused"
  unchanged "version gate writes nothing: $v"
done
rm "$root/etc/unraid-version"
run v '{"template":"my-app.xml","variables":{"set":{"NEWVAR":"v"}}}' apply
expect "missing version file refused" "Could not read"
echo 'version="7.9.0"' > "$root/etc/unraid-version"
run v '{"template":"my-app.xml","variables":{"set":{"NEWVAR":"v"}}}' apply
expect "same major is allowed" "Written."

rm -rf "$root"
[ "$fails" = 0 ] && echo "All tests passed" || { echo "$fails failed"; exit 1; }
