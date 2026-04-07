# Extending the xfce-rdp base image

This document describes how to extend the `xfce-rdp` base image at build time and at container start time.

## Runtime configuration schema (brief)

The container entrypoint consumes a single runtime configuration JSON object. The object MUST contain a top-level
`userCredentials` array where each element is an object with at least the following fields:

- `username` (string, non-empty)
- `password` (string, non-empty)

Optional per-user fields supported by the base image include:

- `sudo` (boolean) — when `true` the user will be granted passwordless sudo
- `singleApp` (string) — a command line to run a single-application session for that user

Example (minimal):

```json
{"userCredentials":[{"username":"developer","password":"s3cr3t","sudo":true}]}
```

The runtime configuration may contain additional top-level keys which derived images
or hooks can use to pass extra settings. A [machine-readable JSON Schema](runtime_config.schema.json) 
is provided — use it with tools like `ajv` or
`jq` to validate your config before deploying. Example validation with `jq`:

```bash
# quick structural check using jq
jq empty runtime_config.json

# or validate required fields using the schema with ajv (npm):
npx ajv-cli validate -s runtime_config.schema.json -d runtime_config.json
```

## Build-time: installing additional packages

### Approach
  Derived images should install additional packages directly in their `Dockerfile`.

  Example:

  ```Dockerfile
  FROM {repo}/xfce-rdp:latest
  RUN apt-get update && \
      apt-get install -y --no-install-recommends pkg1 pkg2 && \
      rm -rf /var/lib/apt/lists/*
  ```

###  Best practices:
  - Combine `apt-get update` and `apt-get install` in a single `RUN` to avoid cache issues.
  - Clean up apt lists after installing to keep image size small.
  - Pin package versions if you need reproducible builds.
  - Document any assumptions about the base image in your derived Dockerfile comments.

## Runtime: deterministic entrypoint hook runner

- Hook root directory: `/etc/xfce-rdp/hooks/entrypoint`

### Phases (processed in order):
  - `pre`
  - `main`
  - `post`

###  Naming convention
  - Scripts must use a three-digit numeric prefix followed by a descriptive name, e.g. `010-setup-home.sh`, `100-configure-audio.sh`, `900-finalize.sh`.
  - Three digits allow room for inserting new scripts between existing ones.

###  Execution order and behavior
  - The entrypoint will process `pre`, then `main`, then `post` directories.
  - Within each directory, scripts are sorted using a natural version sort (`sort -V`) which respects the numeric prefixes.
  - Only script files (`+.sh`) are run; non-script files are ignored.

###  Environment variables controlling behavior:
  - `SKIP_ENTRYPOINT_HOOKS=1` -> skip running all hooks (useful for debugging).
  - `ENTRYPOINT_STRICT` -> if set to `1` (default) the entrypoint exits on first failing hook; if `0` it logs failures and continues.

###  Hook script contract:
A hook script must:
  - Be a bash script (e.g. `#!/usr/bin/env bash`).
  - Be idempotent, as it will be run at every container start.
  - Be writable only by the user running the entrypoint (root by default), but readable for others (`chmod 644`).
  - Define a function named `hook`.
  - Log actions to stdout/stderr.
  - Return `0` on success, non-zero on failure.
  - Avoid long-running blocking tasks. If a hook must start a background service, ensure it is supervised properly or backgrounded explicitly.

 - Hook function parameters and environment:
    - The hook runner calls `hook` (if defined) with the runtime config JSON path 
      (e.g. `/etc/xfce-rdp/runtime_config.json`) as the first positional parameter 
      followed by any extra args forwarded by the caller. For example, entrypoint 
      hooks are called with just the runtime config path, while startwm hooks may 
      be called with the runtime config path and the current username.
    - Environment variables exported for the hook while it runs: 
        - `HOOK_ROOT` (root dir passed to runner)
        - `HOOK_PHASE` (phase name)
        - `HOOK_STRICT` (0/1 behavior on failure).

    Example: iterate userCredentials from the provided runtime config path (first arg):

    ```bash
    hook() {
      runtime_config_path="$1"
      mapfile -t user_data < <(jq -c '.userCredentials[]' "$runtime_config_path" 2>/dev/null || true)
      for u in "${user_data[@]}"; do
        username=$(jq -r '.username // empty' <<<"$u")
        echo "[hooks] Processing $username" >&2
      done
      return 0
    }
    ```

###  Notes about bind mounts and volumes:
  - Consumers may mount files or scripts into `/etc/xfce-rdp/hooks/entrypoint/{pre|main|post}` at runtime. The runner tolerates empty or missing directories and will ignore non-script files (`*.sh`).
  - Mounting `/etc/xfce-rdp/` directly is not recommended as it would override the entrypoint.sh script itself.

## Examples:
  - Add a hook from a derived image at build time:

    ```Dockerfile
    FROM {repo}/xfce-rdp:latest
    COPY hooks/010-setup-home.sh /etc/xfce-rdp/hooks/entrypoint/pre/500-sample-hook.sh
    RUN chmod 644 /etc/xfce-rdp/hooks/entrypoint/pre/500-sample-hook.sh
    ```
  - Then in `500-sample-hook.sh`, something like:
    ```bash
    #!/usr/bin/env bash
    hook() {
      runtime_config_path="$1"
      mapfile -t user_data < <(jq -c '.userCredentials[]' "$runtime_config_path" 2>/dev/null || true)
      for u in "${user_data[@]}"; do
         username=$(jq -r '.username // empty' <<<"$u")
         echo "[hooks] Processing $username" >&2
      done
      return 0
    }
    ```
  - Or provide hooks via a volume at runtime:

    ```sh
    docker run -v $(pwd)/myhooks:/etc/xfce-rdp/hooks/entrypoint/main yourimage:tag
    ```  

3) Documentation and contract

- Keep hook scripts simple, idempotent and documented.
- Add to your derived image README references to any hooks you add and the numeric prefixes you use so other maintainers can insert scripts in the right place.

