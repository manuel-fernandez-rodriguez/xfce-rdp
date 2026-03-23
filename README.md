# Description
Full xfce4 desktop environment with Visual Studio Code, .NET10 SDK, Firefox, and other tools pre-installed. 
You can connect to it using Remote Desktop Protocol (RDP) on port 33890 (or any other port you choose).

# Build
```
docker build -t dev-box .
```
# Run
The examples in this section assume the default username of `developer`.

See the section on [Setting the default user's name](#set-user-name) later on for instructions on how to set a different username.

## Setting the default user's password {#set-user-password}
Preferred (secure) — provide password as a Docker secret (Swarm):
```
echo "s3cr3t" | docker secret create user_password -
docker service create --name dev-box --secret user_password --publish 33890:3389 dev-box:latest
```

Single-host (recommended over plain env) — bind-mount a read-only file into /run/secrets:
```
echo "s3cr3t" > user_password
docker run -v "$(pwd)/user_password:/run/secrets/user_password:ro" \
  -p 33890:3389 --shm-size=1g  -d --name dev-box dev-box:latest
```

Less secure — provide password via an environment variable (visible in inspect):
```
docker run -e USER_PASSWORD='s3cr3t' -p 33890:3389 \
  --shm-size=1g -d --name dev-box dev-box:latest
```
Notes:
- Prefer Docker secrets or a read-only file mount to avoid leaking credentials.

## Setting the default user's name {#set-user-name}
If not specified the username will default to `developer`. To specify a different username, 
set the USER_NAME environment variable. The entrypoint will create a user with that name 
and the specified password (always required, see the [preceding section](#set-user-password).
```
docker run -e USER_NAME=debian -e USER_PASSWORD='s3cr3t' -p 33890:3389 \
  --shm-size=1g -d --name dev-box dev-box:latest
```


## Persisting home directory
```
# Create a named volume and mount it at /home so user homes persist across
# container restarts. The entrypoint will only chown the volume if ownership
# doesn't match the created user's UID.
docker volume create devbox-home
docker run -v devbox-home:/home -v "$(pwd)/user_password:/run/secrets/user_password:ro" \
  -e USER_NAME=debian -p 33890:3389 --shm-size=1g -d --name dev-box dev-box:latest
```

or, using an environment variable for the password, and the default username:
```
docker volume create devbox-home
docker run -v devbox-home:/home -e USER_PASSWORD='s3cr3t' \
  -p 33890:3389 --shm-size=1g -d --name dev-box dev-box:latest
```
Note that, even if not mounting a volume, the volume will still be created as an unnamed volume.
c# DevKit extension can take a fair amount of space (500MB+), so once the container has been created once,
the volume can be found with `docker volume ls` and removed with `docker volume rm <volume_name>` if you want to save space.

