# Plan

To migrate Nerd.nu Minecraft servers from bare metal into Pterodactyl.


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
./ptero backend lobby-dev
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

Dry-run mode now walks the same read-only preflight path as a real migration when run with `MIGRATOR_DRY_RUN_SUDO=1`. Without that flag, it skips the privileged source-process, source-activity, and target-container checks, and prints exactly which checks were skipped and how to include them.


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
5. Check for a running Java server whose process working directory matches the source directory.
6. If one is found, ask you to stop it gracefully with `mark2`, then confirm by typing `STOPPED`.
7. Re-check that the matching Java process is gone and that there is no more known open-file activity in the source directory.
8. Copy files with rsync.
9. Update `server.properties`.
10. Write `.panel-migration.json`.
11. Fix ownership to `pterodactyl:pterodactyl`.

Use these overrides only when intentional:

```sh
MIGRATOR_REPLACE_TARGET=1 ./panel-migrator lobby-dev
MIGRATOR_FORCE=1 ./panel-migrator lobby-dev
```

`MIGRATOR_REPLACE_TARGET=1` moves existing target contents aside before migration. It does not merge over them.

`MIGRATOR_FORCE=1` allows re-migration over a target that already has a migration marker. This can overwrite newer played-on data from the old source state, so use it carefully.

If the source directory still has open-file activity after the Java server stops, clear that activity before continuing. Common examples are shells, editors, or other tools with open files somewhere under the source path.


## Backend config after migration

The migrator updates `server.properties`:

```properties
online-mode=false
server-ip=0.0.0.0
server-port=<allocation-port>
```

### Why?

- server-port=<allocation port>
  - On bare metal, the server may have been bound to a port chosen for the old host layout.
  - In Panel, the server should listen on the allocation assigned to that container.
  - So the migrator rewrites the port to match the selected Panel allocation.
- server-ip=0.0.0.0
  - On bare metal, server-ip may be blank or pinned to a host-specific address.
  - Inside the Panel container, binding to 0.0.0.0 makes the server listen on the container interface in the normal Docker networking model.
  - That is the safest generic containerized setting.
- online-mode=false
  - This is typical when a backend Paper server sits behind Velocity and relies on proxy forwarding rather than doing direct Mojang authentication itself.
  - The doc already assumes a Velocity-backed setup and separately tells you to verify forwarding config and shared secret.

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
./ptero backend lobby-dev
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

Show known open-file activity under a source server directory:

```sh
sudo lsof -nP +D /servers/lobby-dev
```


## Repeat

After one server is migrated and tested, repeat the process for the next world.
