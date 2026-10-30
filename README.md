# unraid-flash-apply

Lets a coding agent propose changes to unRAID Docker templates without being able to write to the flash drive. The agent drops a JSON proposal in a folder; a person at the host's terminal reviews and confirms it. The script does nothing without a terminal.

## Install (on the unRAID host)

Copy `flash-apply.php` to `/boot/config/flash-apply.php`, somewhere the agent can't reach. Read it first: it runs as root.

## Use

```
php /boot/config/flash-apply.php              # lists waiting proposals
php /boot/config/flash-apply.php proposal.json
```

It shows what would change, computed from the template before and after, with existing values hidden. Risky changes are marked and need `apply dangerous` instead of `apply`. A backup goes to `/boot/config/flash-apply-backups/` (it contains secrets). Changes take effect when you rebuild each container from the Docker tab.

Proposals are read from `/mnt/cache/appdata/code-server/flash-proposals`; set `FLASH_APPLY_PROPOSALS` to change that.

## unRAID versions

It refuses to run on any unRAID release other than the one in `TESTED_RELEASE` (`7.3` allows any 7.3.x). There is no override: after checking templates on a new release, change the number, release, and reinstall.

## Proposal format

```json
{
  "template": "my-app.xml",
  "summary": "Why this change is wanted",
  "set": { "Repository": "ghcr.io/me/app:latest" },
  "append_extra_params": "-p 172.17.0.1:64000:8080",
  "variables": { "set": { "HEALTH_URL": "http://host/healthz" }, "remove": ["OLD"] },
  "paths": { "set": [{ "container": "/data", "host": "/mnt/user/appdata/app/data", "mode": "rw" }], "remove": ["/app"] },
  "ports": { "set": [{ "container": 8080, "host": 64000, "protocol": "tcp" }], "remove": [80] }
}
```

`set` accepts `Repository`, `Network`, `Privileged`, `ExtraParams`, `PostArgs` and `WebUI`. `ExtraParams` can only be set while it is empty, because the old value stays hidden; `append_extra_params` adds to the end and keeps what is there. Everything else is refused, including unknown fields, control characters, link files and names with a path.

`replace_in_variables` changes part of a value that holds a secret, such as the host in a database URL, without showing or touching the rest:

```json
{ "replace_in_variables": { "DATABASE_URL": { "from": "192.168.1.4:5432", "to": "172.17.0.1:5432" } } }
```

## Batches

A file can hold several proposals, shown together and confirmed once. It's all or nothing: any invalid entry refuses the whole batch, and every backup and new copy is prepared before the first template is replaced.

```json
{ "summary": "Why", "changes": [ { "template": "my-a.xml", "...": "..." }, { "template": "my-b.xml", "...": "..." } ] }
```

## What it doesn't protect against

The warnings cover the common ways to gain root, but you are the check: read the diff. A new image in `Repository` can do anything its container's mounts allow. Variable values in a proposal are shown in clear, so don't put secrets in one.

## Tests

`sh tests/run.sh` (needs PHP with dom and mbstring, and `script`).
