#!/usr/bin/php
<?php
// Applies one proposed change to an unRAID Docker template, after the person at the host's terminal confirms it.
// Proposals come from a coding agent that must not be able to change the flash by itself, so a proposal is untrusted:
// it is validated field by field, what is shown comes from comparing the template before and after, and existing
// values are never printed. See README.md.

const MAX_PROPOSAL_BYTES = 65536;
const SET_FIELDS = ['Repository', 'Network', 'Privileged', 'ExtraParams', 'PostArgs', 'WebUI'];
const PROPOSAL_KEYS = ['template', 'summary', 'set', 'variables', 'paths', 'ports'];
const PATH_MODES = ['rw', 'ro', 'rw,slave', 'ro,slave', 'rw,shared', 'ro,shared'];
const PROTOCOLS = ['tcp', 'udp'];

$root = getenv('FLASH_APPLY_ROOT') ?: '';
$templatesDir = $root . '/boot/config/plugins/dockerMan/templates-user';
$backupDir = $root . '/boot/config/flash-apply-backups';
$proposalsDir = $root . (getenv('FLASH_APPLY_PROPOSALS') ?: '/mnt/cache/appdata/code-server/flash-proposals');

function fail(string $message): never
{
    fwrite(STDERR, "Refused: " . clean($message) . "\n");
    exit(1);
}

// For display: nothing from a proposal or template may move the cursor, recolour or reorder the terminal.
function clean(string $text): string
{
    $utf8 = mb_check_encoding($text, 'UTF-8') ? $text : mb_convert_encoding($text, 'UTF-8', 'ISO-8859-1');
    return preg_replace('/[\x00-\x1f\x7f-\x9f\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u', '?', $utf8);
}

function requireText(mixed $value, string $what, int $max = 4096): string
{
    if (!is_string($value) && !is_int($value)) {
        fail("$what must be text");
    }

    $text = (string) $value;

    if (strlen($text) > $max || !mb_check_encoding($text, 'UTF-8')) {
        fail("$what is too long or isn't valid UTF-8");
    }

    if (preg_match('/[\x00-\x1f\x7f-\x9f\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u', $text)) {
        fail("$what contains control characters");
    }

    return $text;
}

function requireKeys(array $data, array $allowed, string $what): void
{
    $unknown = array_diff(array_map('strval', array_keys($data)), $allowed);

    if ($unknown) {
        fail("$what has unknown fields: " . implode(', ', $unknown));
    }
}

function requireList(mixed $value, string $what): array
{
    if (!is_array($value) || !array_is_list($value)) {
        fail("$what must be a list");
    }

    return $value;
}

function requireMap(mixed $value, string $what): array
{
    if (!is_array($value) || (array_is_list($value) && $value !== [])) {
        fail("$what must be an object");
    }

    return $value;
}

function containerPath(mixed $value, string $what): string
{
    $path = requireText($value, $what);

    if (!str_starts_with($path, '/') || preg_match('#(^|/)\.\.(/|$)#', $path)) {
        fail("$what must be an absolute path without ..");
    }

    return $path;
}

function portNumber(mixed $value, string $what): string
{
    $port = requireText($value, $what, 5);

    if (!preg_match('/^[0-9]+$/', $port) || (int) $port < 1 || (int) $port > 65535) {
        fail("$what must be a port number");
    }

    return $port;
}

function hostPathWarning(string $host): ?string
{
    $normal = rtrim($host, '/') ?: '/';

    if (preg_match('#(^|/)docker\.sock$#', $normal)) {
        return 'gives control of Docker, equal to root on the host';
    }

    if (preg_match('#^/(boot|etc|root|run|var/run|dev|proc|sys|usr|lib|lib64|bin|sbin|var)(/|$)#', $normal) || $normal === '/') {
        return 'a host system folder';
    }

    if (preg_match('#^/mnt(/(user|user0|cache|disk[0-9]+|[^/]+))?$#', $normal)) {
        return 'a whole disk or share';
    }

    return null;
}

function findConfigs(DOMDocument $doc, string $type): array
{
    $out = [];

    foreach ($doc->getElementsByTagName('Config') as $node) {
        if ($node->getAttribute('Type') === $type) {
            $out[] = $node;
        }
    }

    return $out;
}

function findConfig(DOMDocument $doc, string $type, string $target): ?DOMElement
{
    foreach (findConfigs($doc, $type) as $node) {
        if ($node->getAttribute('Target') === $target) {
            return $node;
        }
    }

    return null;
}

function addConfig(DOMDocument $doc, string $type, string $target, string $value, string $mode): DOMElement
{
    $node = $doc->createElement('Config');
    $node->setAttribute('Name', $target);
    $node->setAttribute('Target', $target);
    $node->setAttribute('Default', '');
    $node->setAttribute('Mode', $mode);
    $node->setAttribute('Description', '');
    $node->setAttribute('Type', $type);
    $node->setAttribute('Display', 'always');
    $node->setAttribute('Required', 'false');
    $node->setAttribute('Mask', 'false');
    $node->textContent = $value;
    $doc->documentElement->appendChild($node);

    return $node;
}

function hidden(string $value): string
{
    return $value === '' ? '(empty)' : '[existing value hidden]';
}

if (!class_exists('DOMDocument') || !function_exists('mb_check_encoding')) {
    fail('This PHP has no DOM or mbstring extension');
}

$name = $argv[1] ?? '';

if ($name === '') {
    echo "Usage: php flash-apply.php <proposal.json>\nWaiting in " . clean($proposalsDir) . ":\n";

    foreach (glob($proposalsDir . '/*.json') ?: [] as $file) {
        echo '  ' . clean(basename($file)) . "\n";
    }

    exit(0);
}

if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/', $name)) {
    fail('Name a proposal file in the proposals folder, without a path');
}

$proposalFile = "$proposalsDir/$name";

if (is_link($proposalFile) || !is_file($proposalFile)) {
    fail('Proposal not found, or it is a link');
}

$raw = file_get_contents($proposalFile, false, null, 0, MAX_PROPOSAL_BYTES + 1);

if ($raw === false || strlen($raw) > MAX_PROPOSAL_BYTES) {
    fail('Proposal is unreadable or too large');
}

$proposal = json_decode($raw, true, 8);

if (!is_array($proposal)) {
    fail('Proposal is not valid JSON');
}

requireKeys($proposal, PROPOSAL_KEYS, 'Proposal');
$template = requireText($proposal['template'] ?? null, 'template', 200);

if (!preg_match('/^my-[A-Za-z0-9][A-Za-z0-9._-]*\.xml$/', $template)) {
    fail('template must be a my-*.xml file name');
}

$templateFile = "$templatesDir/$template";

if (is_link($templateFile) || !is_file($templateFile)) {
    fail('Template not found, or it is a link');
}

$before = file_get_contents($templateFile);
$doc = new DOMDocument();
$doc->preserveWhiteSpace = false;
$doc->formatOutput = true;

if (!@$doc->loadXML($before, LIBXML_NONET) || $doc->documentElement->tagName !== 'Container' || $doc->doctype !== null) {
    fail('Template is not a plain Container XML file');
}

$changes = [];
$note = function (string $what, string $from, string $to, ?string $warning = null) use (&$changes) {
    $changes[] = ['what' => $what, 'from' => $from, 'to' => $to, 'warning' => $warning];
};

// Top-level fields
$set = requireMap($proposal['set'] ?? [], 'set');
requireKeys($set, SET_FIELDS, 'set');

foreach ($set as $field => $value) {
    $value = requireText($value, "set.$field");
    $node = $doc->documentElement->getElementsByTagName($field)->item(0);
    $old = $node ? $node->textContent : '';

    if ($old === $value) {
        continue;
    }

    if (!$node) {
        $node = $doc->createElement($field);
        $doc->documentElement->appendChild($node);
    }

    $node->textContent = $value;
    $warning = match ($field) {
        'Privileged' => strtolower($value) === 'true' ? 'privileged mode is equal to root on the host' : null,
        'ExtraParams' => 'Extra Parameters can grant any Docker right',
        'PostArgs' => 'changes the command the container runs',
        'Repository' => 'changes which code runs',
        'Network' => 'changes what the container can reach',
        default => null,
    };
    $shownOld = in_array($field, ['ExtraParams', 'PostArgs'], true) ? hidden($old) : $old;
    $note($field, $shownOld, $value, $warning);
}

// Variables
$variables = requireMap($proposal['variables'] ?? [], 'variables');
requireKeys($variables, ['set', 'remove'], 'variables');

foreach (requireMap($variables['set'] ?? [], 'variables.set') as $key => $value) {
    $key = requireText($key, 'variable name', 200);

    if (!preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', $key)) {
        fail('Bad variable name');
    }

    $value = requireText($value, "variable $key");
    $warning = preg_match('/^(LD_|NODE_OPTIONS$|NODE_PATH$|PYTHON|PATH$|DOCKER_|SUDO_|BASH_ENV$|ENV$)/', $key) ? 'this variable can change what code runs' : null;
    $node = findConfig($doc, 'Variable', $key);

    if ($node) {
        if ($node->textContent === $value) {
            continue;
        }

        $old = $node->textContent;
        $node->textContent = $value;
        $note("Variable $key", hidden($old), $value, $warning);
    } else {
        addConfig($doc, 'Variable', $key, $value, '');
        $note("Variable $key (new)", '(none)', $value, $warning);
    }
}

foreach (requireList($variables['remove'] ?? [], 'variables.remove') as $key) {
    $key = requireText($key, 'variable name', 200);
    $node = findConfig($doc, 'Variable', $key);

    if ($node) {
        $old = $node->textContent;
        $node->parentNode->removeChild($node);
        $note("Variable $key removed", hidden($old), '(none)');
    }
}

// Paths
$paths = requireMap($proposal['paths'] ?? [], 'paths');
requireKeys($paths, ['set', 'remove'], 'paths');

foreach (requireList($paths['set'] ?? [], 'paths.set') as $entry) {
    $entry = requireMap($entry, 'path');
    requireKeys($entry, ['container', 'host', 'mode'], 'path');
    $target = containerPath($entry['container'] ?? null, 'path container');
    $host = containerPath($entry['host'] ?? null, 'path host');
    $mode = requireText($entry['mode'] ?? 'rw', 'path mode', 20);

    if (!in_array($mode, PATH_MODES, true)) {
        fail('Bad path mode');
    }

    $warning = hostPathWarning($host);
    $node = findConfig($doc, 'Path', $target);

    if ($node) {
        if ($node->textContent === $host && $node->getAttribute('Mode') === $mode) {
            continue;
        }

        $from = $node->textContent . ' (' . $node->getAttribute('Mode') . ')';
        $node->textContent = $host;
        $node->setAttribute('Mode', $mode);
        $note("Path $target", $from, "$host ($mode)", $warning);
    } else {
        addConfig($doc, 'Path', $target, $host, $mode);
        $note("Path $target (new)", '(none)', "$host ($mode)", $warning);
    }
}

foreach (requireList($paths['remove'] ?? [], 'paths.remove') as $target) {
    $target = containerPath($target, 'path container');
    $node = findConfig($doc, 'Path', $target);

    if ($node) {
        $from = $node->textContent;
        $node->parentNode->removeChild($node);
        $note("Path $target removed", $from, '(none)');
    }
}

// Ports
$ports = requireMap($proposal['ports'] ?? [], 'ports');
requireKeys($ports, ['set', 'remove'], 'ports');

foreach (requireList($ports['set'] ?? [], 'ports.set') as $entry) {
    $entry = requireMap($entry, 'port');
    requireKeys($entry, ['container', 'host', 'protocol'], 'port');
    $target = portNumber($entry['container'] ?? null, 'port container');
    $host = portNumber($entry['host'] ?? null, 'port host');
    $protocol = requireText($entry['protocol'] ?? 'tcp', 'port protocol', 5);

    if (!in_array($protocol, PROTOCOLS, true)) {
        fail('Bad port protocol');
    }

    $node = findConfig($doc, 'Port', $target);

    if ($node) {
        if ($node->textContent === $host && $node->getAttribute('Mode') === $protocol) {
            continue;
        }

        $from = $node->textContent . '/' . $node->getAttribute('Mode');
        $node->textContent = $host;
        $node->setAttribute('Mode', $protocol);
        $note("Port $target", $from, "$host/$protocol", 'publishes the container on the network');
    } else {
        addConfig($doc, 'Port', $target, $host, $protocol);
        $note("Port $target (new)", '(none)', "$host/$protocol", 'publishes the container on the network');
    }
}

foreach (requireList($ports['remove'] ?? [], 'ports.remove') as $target) {
    $target = portNumber($target, 'port container');
    $node = findConfig($doc, 'Port', $target);

    if ($node) {
        $from = $node->textContent;
        $node->parentNode->removeChild($node);
        $note("Port $target removed", $from, '(none)');
    }
}

if (!$changes) {
    echo "Nothing to change: " . clean($template) . " already matches this proposal.\n";
    exit(0);
}

$summary = requireText($proposal['summary'] ?? '', 'summary', 500);
$dangerous = array_filter($changes, fn ($c) => $c['warning'] !== null);

echo "\nTemplate: " . clean($template) . "\n";

if ($summary !== '') {
    echo "The agent's own description, not verified: " . clean($summary) . "\n";
}

echo "\nWhat would actually change:\n";

foreach ($changes as $c) {
    echo ($c['warning'] ? '  [!] ' : '      ') . clean($c['what']) . "\n";
    echo '        from: ' . clean($c['from']) . "\n";
    echo '        to:   ' . clean($c['to']) . "\n";

    if ($c['warning']) {
        echo '        WARNING: ' . clean($c['warning']) . "\n";
    }
}

$phrase = $dangerous ? 'apply dangerous' : 'apply';
echo "\n";

if (!stream_isatty(STDIN)) {
    fail('This must be confirmed by a person at a terminal; nothing was changed');
}

echo "Type \"$phrase\" to write this, anything else to stop: ";
$answer = rtrim((string) fgets(STDIN), "\r\n");

if ($answer !== $phrase) {
    echo "Stopped. Nothing was changed.\n";
    exit(1);
}

if (file_get_contents($templateFile) !== $before) {
    fail('The template changed while waiting; nothing was changed');
}

$after = $doc->saveXML();
$check = new DOMDocument();

if (!@$check->loadXML($after, LIBXML_NONET)) {
    fail('The result is not valid XML; nothing was changed');
}

if (!is_dir($backupDir) && !mkdir($backupDir, 0700, true)) {
    fail('Could not create the backup folder; nothing was changed');
}

$backup = $backupDir . '/' . $template . '.' . date('Ymd-His');

if (!copy($templateFile, $backup)) {
    fail('Could not write the backup; nothing was changed');
}

$temp = "$templateFile.flash-apply-tmp";

if (file_put_contents($temp, $after) === false || !rename($temp, $templateFile)) {
    @unlink($temp);
    fail('Could not write the template; it is unchanged or see the backup');
}

@rename($proposalFile, "$proposalFile.applied");
echo "\nWritten. Backup: " . clean($backup) . "\n";
echo "Nothing is running differently yet: open the container in the Docker tab, check it, and press Apply.\n";
