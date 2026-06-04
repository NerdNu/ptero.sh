# Plan

To migrate Minecraft servers from bare metal into Pterodactyl.

## Current policy

Create the Panel destination first, but do not start the server before migration unless there is a specific reason.

A newly created but never-started Panel server should have an empty volume. That is the safest migration target. Starting it first can create bootstrap files, caches, logs, `server.properties`, `eula.txt`, libraries, and possibly a default world. The migrator will refuse a non-empty target unless explicitly overridden.

The migrator writes a marker file after a successful real migration:

```text
.panel-migration.json
```

If that marker exists, a future migration refuses by default. This protects against accidentally overwriting a server that has already been migrated and possibly played on.

## Tooling

Main Panel API dispatcher:

```sh
./ptero <command> [args...]
```

Source the credentials configuration before using the `ptero` helper script.

```sh
source ~/.pterorc
```

That config should look something like this:

```sh
$ cat ~/.pterorc 
export PTERO_URL="https://panel-vex.nerd.nu"
# Get your own key here, please: https://panel-vex.nerd.nu/admin/api
export PTERO_APP_API_KEY="ptla_pterodactyl_user_api_key_with_lots_of_permissions"
# This is your user -- in my case, nelsnelson: https://panel-vex.nerd.nu/admin/users/view/1
export PTERO_OWNER_ID="1"
# This is the "egg" identifier for Paper: https://panel-vex.nerd.nu/admin/nests/egg/1
export PTERO_EGG_ID="1"
# Always do dry-runs by default; to live-run, use: unset PTERO_DRY_RUN
export PTERO_DRY_RUN=1
```

Useful read-only commands:

```sh
./ptero ping
./ptero users
./ptero allocations
./ptero servers
./ptero egg 1
```

Server creation dry run:

```sh
PTERO_DRY_RUN=1 ./ptero create lobby-dev "Lobby Dev" 2
```

Real server creation:

```sh
./ptero create lobby-dev "Lobby Dev" 2
```

Migration inventory and execution tool:

```sh
./panel-migrator list
MIGRATOR_DRY_RUN=1 ./panel-migrator lobby-dev
MIGRATOR_DRY_RUN=1 MIGRATOR_DRY_RUN_SUDO=1 ./panel-migrator lobby-dev
./panel-migrator lobby-dev
```

## Required config files

### ptero.env

`ptero.env` contains Panel API defaults and the application API key.

Check that `PTERO_APP_API_KEY` is not still the placeholder value:

```sh
grep PTERO_APP_API_KEY ptero.env
```

Expected shape:

```sh
export PTERO_URL="https://panel-vex.nerd.nu"
export PTERO_APP_API_KEY="${PTERO_APP_API_KEY:-ptla_REPLACE_ME}"

export PTERO_OWNER_ID="1"
export PTERO_NODE_ID="1"
export PTERO_DEFAULT_SERVER_TYPE="${PTERO_DEFAULT_SERVER_TYPE:-paper}"
export PTERO_PAPER_EGG_ID="1"

export PTERO_DOCKER_IMAGE="ghcr.io/pterodactyl/yolks:java_21"
export PTERO_MEMORY_MIB="2048"
export PTERO_DISK_MIB="0"
export PTERO_CPU_PERCENT="0"
export PTERO_BACKUPS="3"
export PTERO_DATABASES="0"
export PTERO_EXTRA_ALLOCATIONS="0"

export PTERO_MINECRAFT_VERSION="latest"
export PTERO_SERVER_JARFILE="server.jar"
export PTERO_DL_PATH=""
export PTERO_BUILD_NUMBER="latest"

export PTERO_STARTUP='java -Xms128M -XX:MaxRAMPercentage=95.0 -Dterminal.jline=false -Dterminal.ansi=true -jar {{SERVER_JARFILE}}'
```

`PTERO_OWNER_ID` is the Panel user ID, not the Linux UID of the `pterodactyl` user.

### panel-migrator.json

Example:

```json
{
  "ptero_bin": "./ptero",
  "panel_volume_root": "/docker/data/panel.nerd.nu/volumes",
  "panel_owner": "pterodactyl:pterodactyl",
  "disk_safety_percent": 110,
  "default_rsync_excludes": [
    "plugins/WorldEdit/.archive-unpack/"
  ],
  "servers": [
    {
      "id": "lobby-dev",
      "name": "Lobby Dev",
      "source": "/servers/lobby-dev",
      "allocation_id": 2,
      "type": "paper",
      "service": null,
      "panel_uuid": "001ee416-999e-4640-a287-f9f6a1fbe8c1"
    }
  ]
}
```

The default rsync exclude omits WorldEdit unpack cache data. It is not expected to be world state.

## Migration steps for one server

### 1. Choose the source server

Pick one dev world server.

Confirm the source path exists:

```sh
ls -la /servers/lobby-dev
du -sh /servers/lobby-dev
```

### 2. Pick an allocation

List allocations:

```sh
./ptero allocations
```

Choose an unassigned allocation. For `lobby-dev`, allocation ID `2` maps to port `27001`.

### 3. Add or update the server in panel-migrator.json

Each server needs:

```json
{
  "id": "lobby-dev",
  "name": "Lobby Dev",
  "source": "/servers/lobby-dev",
  "allocation_id": 2,
  "type": "paper",
  "service": null,
  "panel_uuid": null
}
```

If the Panel server already exists, set `panel_uuid` to the existing server UUID.

If the Panel server exists but the config does not know about it yet:

```sh
./panel-migrator adopt lobby-dev <panel-server-uuid>
```

### 4. Create the Panel destination

Dry run first:

```sh
PTERO_DRY_RUN=1 ./ptero create lobby-dev "Lobby Dev" 2
```

Then create for real:

```sh
./ptero create lobby-dev "Lobby Dev" 2
```

After creation, verify:

```sh
./ptero servers
./panel-migrator list
```

Do not start the server yet.

### 5. Run a migration dry run

Normal dry run:

```sh
MIGRATOR_DRY_RUN=1 ./panel-migrator lobby-dev
```

If the unprivileged dry run cannot read some source files, run a privileged dry run:

```sh
MIGRATOR_DRY_RUN=1 MIGRATOR_DRY_RUN_SUDO=1 ./panel-migrator lobby-dev
```

The plan should show:

```text
Target entries:   0
Marker:           absent
Target policy:    empty; safe to seed
Disk policy:      ok
Rsync excludes:   plugins/WorldEdit/.archive-unpack/
```

If `Disk policy` is insufficient, stop and free space or move the target volume storage before migrating.

The default disk margin is 110%. To test another margin:

```sh
MIGRATOR_DRY_RUN=1 MIGRATOR_DISK_SAFETY_PERCENT=125 ./panel-migrator lobby-dev
```

### 6. Run the real migration

Run:

```sh
./panel-migrator lobby-dev
```

Type exactly:

```text
MIGRATE
```

The migrator will:

1. Refuse if `.panel-migration.json` already exists, unless `MIGRATOR_FORCE=1`.
2. Refuse a non-empty target, unless `MIGRATOR_REPLACE_TARGET=1`.
3. Refuse if the target Panel container is running.
4. Check disk space with the configured safety margin.
5. Stop the old systemd service if one is configured.
6. Copy files with rsync.
7. Update `server.properties`.
8. Write `.panel-migration.json`.
9. Fix ownership to `pterodactyl:pterodactyl`.

Use these overrides only when intentional:

```sh
MIGRATOR_REPLACE_TARGET=1 ./panel-migrator lobby-dev
MIGRATOR_FORCE=1 ./panel-migrator lobby-dev
```

`MIGRATOR_REPLACE_TARGET=1` moves existing target contents aside before migration. It does not merge over them.

`MIGRATOR_FORCE=1` allows re-migration over a target that already has a migration marker. This can overwrite newer played-on data from the old source state, so use it carefully.

## Backend config after migration

The migrator updates `server.properties`:

```properties
online-mode=false
server-ip=0.0.0.0
server-port=<allocation-port>
```

For Paper behind Velocity, also confirm `config/paper-global.yml` has Velocity forwarding enabled and uses the same forwarding secret as Velocity:

```yaml
proxies:
  velocity:
    enabled: true
    online-mode: true
    secret: "<same secret as Velocity forwarding.secret>"
```

Velocity should have:

```toml
online-mode = true
player-info-forwarding-mode = "modern"
forwarding-secret-file = "forwarding.secret"
```

## Start and test

Start the backend from Panel.

Check the backend console.

Find the backend container IP if Velocity is still using container-internal routing:

```sh
sudo docker inspect <backend-container-or-uuid> | jq -r '.[0].NetworkSettings.Networks | to_entries[] | "\(.key) \(.value.IPAddress)"'
```

Update `velocity.toml` to point to the backend container IP and backend port.

Then restart Velocity and test through:

```text
vex.nerd.nu:25566
```

## Useful discovery commands

List Panel volumes:

```sh
sudo ls -lt /docker/data/panel.nerd.nu/volumes
```

Check target volume contents:

```sh
sudo find /docker/data/panel.nerd.nu/volumes/<uuid> -mindepth 1 -maxdepth 1 | head
```

Check migration marker:

```sh
sudo cat /docker/data/panel.nerd.nu/volumes/<uuid>/.panel-migration.json
```

Find running Java servers:

```sh
ps -eo pid,user,cmd | grep -Ei 'java|paper|spigot|purpur|minecraft' | grep -v grep
```

Find a process working directory:

```sh
sudo readlink -f /proc/<pid>/cwd
```

Find possible systemd services:

```sh
systemctl list-unit-files | grep -Ei 'minecraft|paper|spigot|purpur|lobby|survival|creative'
```

Inspect a service:

```sh
systemctl cat <service-name>
```

## Repeat

After one server is migrated and tested, repeat the process for the next world.
EOF

```

This updates the plan to match the current tooling and changes the old "start once, then stop it" instruction to the safer "create but do not start before migration" flow. Confidence: 98/100.
```


