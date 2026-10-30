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
expect "applied" "Written:"
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
  '{"template":"my-app.xml","append_extra_params":"--cap-add=ALL"}|Extra Parameters' \
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

# --- Extra Parameters
reset_template
run e1 '{"template":"my-app.xml","set":{"ExtraParams":"-p 1:2"}}' "apply dangerous"
expect "won't replace an existing value" "already has a value"
file_has "existing value kept after refusal" "--secret-param=$SECRET"
run e2 '{"template":"my-app.xml","append_extra_params":"-p 172.17.0.1:1:2"}' "apply dangerous"
expect "append applied" "Written:"
never "append doesn't print the old value" "$SECRET"
file_has "append keeps the old value" "--secret-param=$SECRET -p 172.17.0.1:1:2"
run e3 '{"template":"my-app.xml","append_extra_params":"-p 172.17.0.1:1:2"}' "apply dangerous"
expect "second append changes nothing" "already match"
sed -i "s#<ExtraParams>.*</ExtraParams>#<ExtraParams></ExtraParams>#" "$tpl/my-app.xml"
run e4 '{"template":"my-app.xml","set":{"ExtraParams":"-p 3:4"}}' "apply dangerous"
file_has "set works on an empty value" ">-p 3:4<"
run e5 '{"template":"my-app.xml","append_extra_params":"x\u001b[2J"}' stop
expect "append refuses control characters" "control characters"

# --- part of a secret value
reset_template
printf '%s' "$(sed 's#</Container>#<Config Name="Db" Target="DATABASE_URL" Default="" Mode="" Description="" Type="Variable" Display="always" Required="false" Mask="false">postgres://u:'$SECRET'@192.168.1.4:64232/db</Config></Container>#' "$tpl/my-app.xml")" > "$tpl/my-app.xml"
run p1 '{"template":"my-app.xml","replace_in_variables":{"DATABASE_URL":{"from":"192.168.1.4:64232","to":"172.17.0.1:64232"}}}' apply
expect "replace applied" "Written:"
never "replace doesn't print the rest" "$SECRET"
file_has "replace changed the host" "$SECRET@172.17.0.1:64232/db"
run p2 '{"template":"my-app.xml","replace_in_variables":{"DATABASE_URL":{"from":"192.168.1.4:64232","to":"172.17.0.1:64232"}}}' apply
expect "replace is safe to repeat" "already match"
run p3 '{"template":"my-app.xml","replace_in_variables":{"DATABASE_URL":{"from":"nothing-here","to":"unmatched-new-text"}}}' apply
expect "replace refuses when nothing matches" "neither the old nor the new"
run p4 '{"template":"my-app.xml","replace_in_variables":{"MISSING":{"from":"a","to":"b"}}}' apply
expect "replace refuses a missing variable" "has no variable"

# --- values survive a rewrite exactly
reset_template
cat > "$tpl/my-rt.xml" <<'X'
<?xml version="1.0"?>
<Container version="2">
  <Name>rt</Name>
  <Repository>old/image:1</Repository>
  <ExtraParams>--a=1 --b="x y"</ExtraParams>
  <Overview>Caf&#xE9; &lt;b&gt;bold&lt;/b&gt; &amp; more</Overview>
  <Config Name="Url" Target="URL" Default="d&amp;e" Mode="" Description="say &quot;hi&quot;" Type="Variable" Display="always" Required="false" Mask="true">postgres://u:p&amp;w&lt;d%24$x'"é@192.168.1.4:5/db?a=1&amp;b=2</Config>
  <Config Name="Json" Target="JSON" Default="" Mode="" Description="" Type="Variable" Display="always" Required="false" Mask="false">{"k":"a&amp;b","n":"&lt;x&gt;","u":"ü"}</Config>
  <Config Name="Keep" Target="KEEP" Default="" Mode="" Description="" Type="Variable" Display="always" Required="false" Mask="false">  spaced  </Config>
  <Config Name="Empty" Target="EMPTY" Default="fallback" Mode="" Description="" Type="Variable" Display="always" Required="false" Mask="false"></Config>
  <Config Name="P" Target="53" Default="" Mode="tcp" Description="" Type="Port" Display="always" Required="false" Mask="false">53</Config>
  <Config Name="P" Target="53" Default="" Mode="udp" Description="" Type="Port" Display="always" Required="false" Mask="false">53</Config>
</Container>
X
cat > "$root/rt.php" <<'X'
<?php
$d = new DOMDocument(); $d->load($argv[1]); $o = [];
foreach ($d->getElementsByTagName('Config') as $c) { $a = []; foreach ($c->attributes as $n) { $a[$n->name] = $n->value; } $o[] = [$a, $c->textContent]; }
foreach (['Name', 'Repository', 'ExtraParams', 'Overview'] as $f) { $o[$f] = $d->getElementsByTagName($f)->item(0)->textContent; }
echo json_encode($o, JSON_UNESCAPED_UNICODE);
X
before=$(php "$root/rt.php" "$tpl/my-rt.xml")
run rt1 '{"template":"my-rt.xml","variables":{"set":{"NEWVAR":"1"}}}' apply
expect "round trip applied" "Written:"
after=$(php "$root/rt.php" "$tpl/my-rt.xml" | sed 's/,\[{"Name":"NEWVAR".*\]\]*,"Name"/,"Name"/')
want=$(printf '%s' "$before" | sed 's/\],"Name"/],"Name"/')
out="before=$before
after =$(php "$root/rt.php" "$tpl/my-rt.xml")"
for s in 'p&w<d%24$x' 'a=1&b=2' '"k":"a&b"' '"n":"<x>"' 'ü' '  spaced  ' 'fallback' 'Café <b>bold</b> & more' '--b=\"x y\"' 'd&e' 'say \"hi\"'; do
  if php "$root/rt.php" "$tpl/my-rt.xml" | grep -qF -- "$s"; then ok "survives: $s"; else bad "survives: $s"; fi
done
run rt2 '{"template":"my-rt.xml","replace_in_variables":{"URL":{"from":"192.168.1.4:5","to":"172.17.0.1:5"}}}' apply
if php "$root/rt.php" "$tpl/my-rt.xml" | grep -qF "postgres://u:p&w<d%24\$x'\\\"é@172.17.0.1:5/db?a=1&b=2"; then ok "replace keeps special characters"; else out=$(php "$root/rt.php" "$tpl/my-rt.xml"); bad "replace keeps special characters"; fi

# --- moving a port
run mv1 '{"template":"my-rt.xml","append_extra_params":"-p 172.17.0.1:53:53","ports":{"remove":[9999]}}' "apply dangerous"
expect "move refused when the port entry is missing" "can't be moved"
if grep -q '172.17.0.1:53:53' "$tpl/my-rt.xml"; then bad "refused move wrote nothing"; else ok "refused move wrote nothing"; fi
run mv2 '{"template":"my-rt.xml","append_extra_params":"-p 172.17.0.1:53:53","ports":{"remove":[53]}}' "apply dangerous"
if grep -q 'Type="Port"' "$tpl/my-rt.xml"; then out=$(cat "$tpl/my-rt.xml"); bad "both protocol entries removed"; else ok "both protocol entries removed"; fi
run mv3 '{"template":"my-rt.xml","append_extra_params":"-p 172.17.0.1:53:53","ports":{"remove":[53]}}' "apply dangerous"
expect "repeating a finished move is safe" "already match"
cat > "$tpl/my-dup.xml" <<'X'
<?xml version="1.0"?>
<Container><Config Target="A" Type="Variable">one</Config><Config Target="A" Type="Variable">two</Config></Container>
X
run dup '{"template":"my-dup.xml","replace_in_variables":{"A":{"from":"one","to":"new"}}}' apply
expect "replace refuses a duplicated variable" "more than one"
rm -f "$tpl/my-rt.xml" "$tpl/my-dup.xml"

# --- batches
reset_template
sed 's/old\/image:1/second\/image:1/' "$tpl/my-app.xml" > "$tpl/my-two.xml"
run b1 '{"summary":"both","changes":[{"template":"my-app.xml","variables":{"set":{"NEWVAR":"1"}}},{"template":"my-two.xml","variables":{"set":{"NEWVAR2":"2"}}}]}' apply
expect "batch asks once for both" "these 2 templates"
expect "batch lists the first" "Written: my-app.xml"
expect "batch lists the second" "Written: my-two.xml"
never "batch hides secrets" "$SECRET"
if grep -q NEWVAR2 "$tpl/my-two.xml" && grep -q NEWVAR "$tpl/my-app.xml"; then ok "batch wrote both"; else bad "batch wrote both"; fi
if [ "$(ls "$root/boot/config/flash-apply-backups" | wc -l)" = 2 ]; then ok "batch backed up both"; else bad "batch backed up both"; fi
reset_template
sed 's/old\/image:1/second\/image:1/' "$tpl/my-app.xml" > "$tpl/my-two.xml"
run b2 '{"changes":[{"template":"my-app.xml","variables":{"set":{"NEWVAR":"1"}}},{"template":"my-missing.xml"}]}' apply
expect "batch refused on one bad entry" "not found"
unchanged "a refused batch writes nothing"
run b3 '{"changes":[{"template":"my-app.xml","variables":{"set":{"NEWVAR":"1"}}},{"template":"my-two.xml","set":{"Privileged":"true"}}]}' apply
expect "one risky change makes the batch risky" "apply dangerous"
unchanged "plain apply doesn't confirm a risky batch"
run b4 '{"changes":[{"template":"my-app.xml"},{"template":"my-app.xml"}]}' apply
expect "batch refuses a repeated template" "appears twice"
run b5 '{"changes":[{"template":"my-app.xml","variables":{"set":{"NEWVAR":"1"}}}],"surprise":1}' apply
expect "batch refuses unknown fields" "unknown fields"
rm -f "$tpl/my-two.xml"

# --- unRAID version gate
reset_template
for v in 'version="8.0.0"' 'version="7.4.0"' 'version="7.4.0-rc.1"' 'version="7.2.9"' 'version="7.30.0"' 'version="6.12.1"' 'nonsense'; do
  echo "$v" > "$root/etc/unraid-version"
  run v '{"template":"my-app.xml","variables":{"set":{"NEWVAR":"v"}}}' apply
  expect "version gate refuses: $v" "Refused"
  unchanged "version gate writes nothing: $v"
done
rm "$root/etc/unraid-version"
run v '{"template":"my-app.xml","variables":{"set":{"NEWVAR":"v"}}}' apply
expect "missing version file refused" "Could not read"
echo 'version="7.3.9"' > "$root/etc/unraid-version"
run v '{"template":"my-app.xml","variables":{"set":{"NEWVAR":"v"}}}' apply
expect "same release, newer patch, is allowed" "Written:"

rm -rf "$root"
[ "$fails" = 0 ] && echo "All tests passed" || { echo "$fails failed"; exit 1; }
