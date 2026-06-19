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
./ptero egg 1
./ptero backend --target-mode allocation --velocity-name lobby lobby-dev
./ptero backend --update-velocity-config --dry-run --velocity-name lobby lobby-dev
```

Velocity config updates:

```sh
./ptero backend --update-velocity-config --velocity-name lobby lobby-dev
./ptero backend --check-reachability --update-velocity-config --velocity-name lobby lobby-dev
```

By default this updates `velocity.toml` at
`$PTERO_VOLUMES_DIR/<velocity-uuid>/velocity.toml`. Override that path with
`PTERO_VELOCITY_TOML` if the Velocity config lives elsewhere.

Backend target selection defaults to allocation-first:

- allocation alias plus port
- allocation IP plus port
- Docker IP only when `--target-mode docker` is selected

Create a server dry run:

```sh
PTERO_DRY_RUN=1 ./ptero create example-server "Example Server" 2
```

List migration targets:

```sh
./panel-migrator list
```

Migration dry run:

```sh
MIGRATOR_DRY_RUN=1 ./panel-migrator example-server
```

More detailed workflow notes live in `PTERODACTYL_PLAN.md`.
