# Build
```bash
docker build -t dev-box .
```
# Run
Provide a JSON array of user objects via a Docker secret (recommended) or the
`USERS_CREDENTIALS` environment variable. Each object must contain `username`,
`password` and, optionally `sudo` (boolean, default: false). 

Example JSON:

```json
[{"username":"alice","password":"alicepw","sudo":true},
 {"username":"bob","password":"bobpw"}]
```

Preferred (secure) — provide users JSON as a Docker secret (Swarm):
```bash
echo '[{"username":"developer","password":"s3cr3t","sudo":true}]' > users.json
docker secret create users_credentials users.json
docker service create --name dev-box --secret users_credentials --publish 33890:3389 dev-box:latest
```

Single-host (recommended over plain env) — bind-mount a read-only file into /run/secrets:
```bash
echo '[{"username":"developer","password":"s3cr3t","sudo":true}]' > users.json
docker run -v "$(pwd)/users.json:/run/secrets/users_credentials:ro" \
  -p 33890:3389 --shm-size=1g  -d --name dev-box dev-box:latest
```

Less secure — provide JSON via an environment variable (visible in inspect):
```bash
docker run -e USERS_CREDENTIALS='[{"username":"developer","password":"s3cr3t","sudo":true}]' -p 33890:3389 \
  --shm-size=1g -d --name dev-box dev-box:latest
```

Notes:
- Prefer Docker secrets or a read-only file mount to avoid leaking credentials.

## Persisting home directory
```
# Create a named volume and mount it at /home so user homes persist across
# container restarts. The entrypoint will only chown the volume if ownership
# doesn't match the created user's UID.
docker volume create devbox-home
docker run -v devbox-home:/home -v "$(pwd)/users.json:/run/secrets/users_credentials:ro" \
  -p 33890:3389 --shm-size=1g -d --name dev-box dev-box:latest
```

Note that, even if not mounting a volume, the volume will still be created as an unnamed volume.
c# DevKit extension can take a fair amount of space (500MB+), so once the container has been created once,
the volume can be found with `docker volume ls` and removed with `docker volume rm <volume_name>` if you want to save space.

