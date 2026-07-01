# ptero.sh

Small shell helpers for working with a Pterodactyl panel and migrating Minecraft servers into it.


## Files

Some important files:

- `./ptero`: main command dispatcher
- `./panel-migrator`: migration helper
- `./ptero.env`: local environment defaults
- `./panel-migrator.json`: migration config


## Requirements

- `bash`
- `curl`
- `jq`
- `rsync`


## Setup

First, review `ptero.env` and set a real `PTERO_APP_API_KEY`.

Write-oriented `ptero` commands and `panel-migrator` default to preview mode.
Set `PTERO_LIVE_RUN=1` to allow live writes and real migrations.

I like to put something like this into my `~/.pterorc` file:

```sh
export PTERO_APP_API_KEY="ptla_changeme"
```

Next, review `panel-migrator.json` and update server entries as needed.


## Common commands

```sh
./ptero ping
./ptero users
./ptero allocations
./ptero servers
./ptero service-host
./ptero service-host lobby-dev
./ptero forwarding-check lobby-dev
./ptero egg 1
./ptero endpoint --velocity-name lobby lobby-dev
./ptero endpoint --update-velocity-config --velocity-name lobby lobby-dev
```

Resolve the host-side IP that Pterodactyl containers should use for shared host
services such as MariaDB or Redis:

```sh
./ptero service-host
./ptero service-host --plain
./ptero service-host lobby-dev
```

Velocity config updates:

```sh
./ptero endpoint --update-velocity-config --velocity-name lobby lobby-dev
./ptero endpoint --check-reachability --update-velocity-config --velocity-name lobby lobby-dev
PTERO_LIVE_RUN=1 ./ptero endpoint --update-velocity-config --velocity-name lobby lobby-dev
```

By default this updates `velocity.toml` at
`$PTERO_VOLUMES_DIR/<velocity-uuid>/velocity.toml`. Override that path with
`PTERO_VELOCITY_TOML` if the Velocity config lives elsewhere.

By default `--update-velocity-config` is preview-only. Set `PTERO_LIVE_RUN=1` to
apply the rendered `velocity.toml` change.

If `--check-reachability` is requested while the backend container is not running,
the reachability step is skipped automatically.

Backend target selection defaults to the backend container's Docker-network IP plus the allocation port:

- allocation alias plus port
- allocation IP plus port
- Docker-network IP plus port for the resolved backend target

Create a server preview:

```sh
./ptero create example-server "Example Server" 2
PTERO_LIVE_RUN=1 ./ptero create example-server "Example Server" 2
```

List migration targets:

```sh
./panel-migrator list
```

Migration preview:

```sh
./panel-migrator example-server
MIGRATOR_DRY_RUN_SUDO=1 ./panel-migrator example-server
PTERO_LIVE_RUN=1 ./panel-migrator example-server
```

More detailed workflow notes live in `MIGRATION_PLAN.md`.
