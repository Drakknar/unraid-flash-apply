# unraid-flash-apply

Lets a coding agent propose changes to unRAID Docker templates without being able to write to the flash drive. The agent drops a JSON proposal in a folder; a person at the host's terminal reviews and confirms it. The script does nothing without a terminal.

## Install (on the unRAID host)

Copy `flash-apply.php` to `/boot/config/flash-apply.php`, somewhere the agent can't reach. Read it first: it runs as root.

## Use

```
php /boot/config/flash-apply.php              # lists waiting proposals
php /boot/config/flash-apply.php proposal.json
```

It shows what would change, computed from the template before and after, with existing values hidden. Risky changes are marked and need `apply dangerous` instead of `apply`. A backup goes to `/boot/config/flash-apply-backups/` (it contains secrets). The change takes effect when you press Apply in the Docker tab.

Proposals are read from `/mnt/cache/appdata/code-server/flash-proposals`; set `FLASH_APPLY_PROPOSALS` to change that.

## Proposal format

```json
{
  "template": "my-app.xml",
  "summary": "Why this change is wanted",
  "set": { "Repository": "ghcr.io/me/app:latest" },
  "variables": { "set": { "HEALTH_URL": "http://host/healthz" }, "remove": ["OLD"] },
  "paths": { "set": [{ "container": "/data", "host": "/mnt/user/appdata/app/data", "mode": "rw" }], "remove": ["/app"] },
  "ports": { "set": [{ "container": 8080, "host": 64000, "protocol": "tcp" }], "remove": [80] }
}
```

`set` accepts `Repository`, `Network`, `Privileged`, `ExtraParams`, `PostArgs` and `WebUI`. Everything else is refused, including unknown fields, control characters, link files and names with a path.

## What it doesn't protect against

The warnings cover the common ways to gain root, but you are the check: read the diff. A new image in `Repository` can do anything its container's mounts allow. Variable values in a proposal are shown in clear, so don't put secrets in one.

## Tests

`sh tests/run.sh` (needs PHP with dom and mbstring, and `script`).
