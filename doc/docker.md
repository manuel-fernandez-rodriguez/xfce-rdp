# Build
```bash
docker build -t xfce-rdp .
```
# Run
Provide a JSON runtime configuration object via a Docker secret (recommended)
or the `RUNTIME_CONFIG` environment variable. The object must contain a
top-level `userCredentials` array where each element contains `username`,
`password` and, optionally `sudo` (boolean, default: false).

Example runtime config JSON:

```json
{"userCredentials":[{"username":"alice","password":"alicepw","sudo":true},
 {"username":"bob","password":"bobpw"}]}
```

Preferred (secure) — provide runtime config JSON as a Docker secret (Swarm):
```bash
echo '{"userCredentials":[{"username":"developer","password":"s3cr3t","sudo":true}]}' > runtime_config.json
docker secret create runtime_config runtime_config.json
docker service create --name xfce-rdp --secret runtime_config --publish 33890:3389 xfce-rdp:latest
```

Single-host (recommended over plain env) — bind-mount a read-only file into /run/secrets:
```bash
echo '{"userCredentials":[{"username":"developer","password":"s3cr3t","sudo":true}]}' > runtime_config.json
docker run -v "$(pwd)/runtime_config.json:/run/secrets/runtime_config:ro" \
  -p 33890:3389 --shm-size=1g  -d --name xfce-rdp xfce-rdp:latest
```

Less secure — provide runtime config JSON via an environment variable (visible in inspect):
```bash
docker run -e RUNTIME_CONFIG='{"userCredentials":[{"username":"developer","password":"s3cr3t","sudo":true}]}' -p 33890:3389 \
  --shm-size=1g -d --name xfce-rdp xfce-rdp:latest
```

Notes:
- Prefer Docker secrets or a read-only file mount to avoid leaking credentials.

## Persisting home directory

The helper script now mounts an explicit named docker volume at `/home` by
default (a deterministic name based on the container name, e.g. `xfce-rdp-home`).
This avoids anonymous volumes and makes persistence predictable. You have two
recommended options:

- Bind-mount a host directory at `/home` (development / single-host):

```bash
# Provide a host path to mount at /home using the helper script:
./run.sh --home-bind /path/to/host/home
```

- Use a named docker volume (default behavior of `run.sh`):

```bash
# The helper will create and mount a deterministic named volume called
# "${container}-home" (e.g. "xfce-rdp-home") if no --home-bind is provided.
docker volume create devbox-home
docker run -v devbox-home:/home -v "$(pwd)/runtime_config.json:/run/secrets/runtime_config:ro" \
  -p 33890:3389 --shm-size=1g -d --name xfce-rdp xfce-rdp:latest
```

If you run the image without an explicit mount (not using the helper script),
Docker may create an anonymous volume; prefer a named volume or host bind for
predictable lifecycle and easier backups. Use `docker volume ls` and
`docker volume rm <volume_name>` to manage volumes.

## Optional: Add support for RDP drive sharing.
**Note:** _This is not recommended for production since it requires additional 
permissions, so use with caution and only if you understand the security 
implications._

To enable RDP drive redirection, you need to run the container with additional
privileges, adding `--cap-add SYS_ADMIN` and `--device /dev/fuse` to the 
`docker run` command.

