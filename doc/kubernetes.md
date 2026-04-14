# Run this image as a Kubernetes Pod

This is a short, practical guide to run the `xfce-rdp` image as a Kubernetes 
Pod, keeping secrets out of plain env-vars in production.

## Setting up users and passwords
The container's entrypoint expects a runtime configuration JSON object with a
top-level `userCredentials` array. Each element must contain `username`,
`password` and optional `sudo` (boolean) fields. For example:
```json
{
  "userCredentials":[
    {"username":"developer","password":"s3cr3t","sudo":true},
    {"username":"alice","password":"alicepw"},
    {"username":"bob","password":"bobpw"}
  ]
}
```
See in the examples of the following sections how to provide this JSON securely
via a Kubernetes Secret, or less securely via an environment variable for quick testing.

## Quick test (not recommended for production)
This is not recommended for production since secrets in Pod specs are visible in
the manifest, but it can be useful for a quick test or demo.

- Run via `kubectl run` with an env var (insecure):

```bash
kubectl run xfce-rdp \
  --image=ghcr.io/manuel-fernandez-rodriguez/xfce-rdp:latest \
  --restart=Never --port=3389 --image-pull-policy=IfNotPresent \
  --env='RUNTIME_CONFIG={"userCredentials":[{"username":"developer","password":"s3cr3t","sudo":true}]}'
```

- Forward the RDP port:
  `kubectl port-forward pod/xfce-rdp 33890:3389`

You can add a memory-backed `/dev/shm` for a quick test using `kubectl run --overrides` 
to modify the Pod spec inline. Example (bash):

```bash
kubectl run xfce-rdp \
  --image=ghcr.io/manuel-fernandez-rodriguez/xfce-rdp:latest \
  --restart=Never --port=3389 --image-pull-policy=IfNotPresent \
  --env='RUNTIME_CONFIG={"userCredentials":[{"username":"developer","password":"s3cr3t","sudo":true}]}' \
  --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"xfce-rdp","volumeMounts":[{"name":"dshm","mountPath":"/dev/shm"}]}],"volumes":[{"name":"dshm","emptyDir":{"medium":"Memory","sizeLimit":"1Gi"}}]}}'
```

PowerShell (use single quotes around the JSON payload):

```powershell
kubectl run xfce-rdp `
  --image=ghcr.io/manuel-fernandez-rodriguez/xfce-rdp:latest `
  --restart=Never --port=3389 --image-pull-policy=IfNotPresent `
  --env='RUNTIME_CONFIG={"userCredentials":[{"username":"developer","password":"s3cr3t","sudo":true}]}' `
  --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"xfce-rdp","volumeMounts":[{"name":"dshm","mountPath":"/dev/shm"}]}],"volumes":[{"name":"dshm","emptyDir":{"medium":"Memory","sizeLimit":"1Gi"}}]}}'
```

Note: `--overrides` is handy for quick testing, but using a Pod manifest (as 
shown in the next section) is clearer and more reproducible. Also, `sizeLimit`
may be ignored on older Kubernetes versions — test on your cluster.

## Recommended: use a Secret mounted as `/run/secrets`
1. Create a secret (key `runtime_config`) containing the runtime config JSON object:
   ```bash
   kubectl create secret generic runtime-config --from-file=runtime_config=./runtime_config.json
   ```

2. Pod manifest (save as `xfce-rdp-pod.yaml`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: xfce-rdp
spec:
  containers:
  - name: xfce-rdp
    image: ghcr.io/manuel-fernandez-rodriguez/xfce-rdp:latest
    imagePullPolicy: IfNotPresent
    ports:
    - containerPort: 3389
    volumeMounts:
    - name: user-secret
      mountPath: /run/secrets
      readOnly: true
    - name: dshm
      mountPath: /dev/shm
  volumes:
  - name: user-secret
    secret:
      secretName: runtime-config
      items:
      - key: runtime_config
        path: runtime_config
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: "1Gi"
```

Note: How to decide the right value for sizeLimit:

- Test with sizeLimit: "1Gi" and watch inside the Pod:
- `df -h /dev/shm`
- `ps aux --sort=-rss | head` and `free -m`
- Check app logs for `ENOSPC` or renderer/sandbox errors.
- If you see crashes, increase to 2Gi (or higher) and re-test.

Also monitor node memory usage and pick a size that leaves safe headroom for 
other pods.

3. Apply and forward:
  `kubectl apply -f xfce-rdp-pod.yaml`
  `kubectl port-forward pod/xfce-rdp 33890:3389`


## Optional: expose externally via a NodePort Service (save as `xfce-rdp-svc.yaml`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: xfce-rdp-svc
spec:
  type: NodePort
  selector:
    run: xfce-rdp
  ports:
  - port: 3389
    targetPort: 3389
    nodePort: 30089
```

Notes
- If using a local image and Docker Desktop/kind, set 
  `imagePullPolicy: IfNotPresent` or `Never` and ensure the image is loaded 
  on cluster nodes.
- To persist `/home` across restarts, create a `PersistentVolumeClaim` and mount
  it at `/home` in the Pod.
- Prefer Secrets (mounted files) over env vars for passwords.


## GKE ready-to-apply manifests (includes PVC example)

Follow these steps to push the image to Google Container Registry (replace 
`PROJECT_ID`) and apply manifests on GKE.

1. Build and push image to GCR

```bash
docker build -t xfce-rdp:latest -f src/Dockerfile .
docker tag xfce-rdp:latest gcr.io/PROJECT_ID/xfce-rdp:latest
gcloud auth configure-docker
docker push gcr.io/PROJECT_ID/xfce-rdp:latest
```

2. Manifests

Save the following manifests and apply them with `kubectl apply -f <file>`.

`secret-runtime-config.yaml` (stores the runtime config JSON object as a file under
`/run/secrets/runtime_config`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: runtime-config
type: Opaque
data:
  # base64-encode your runtime_config.json and paste here, or use --from-file when creating
  runtime_config: ""
```

Example creation (recommended):

```bash
kubectl create secret generic runtime-config --from-file=runtime_config=./runtime_config.json
```

`pvc.yaml` (PersistentVolumeClaim for `/home` persistence):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: devbox-home-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard
```

`deployment.yaml` (Deployment that mounts the Secret and PVC):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xfce-rdp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: xfce-rdp
  template:
    metadata:
      labels:
        app: xfce-rdp
    spec:
      containers:
      - name: xfce-rdp
        image: ghcr.io/manuel-fernandez-rodriguez/xfce-rdp:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3389
        volumeMounts:
        - name: user-secret
          mountPath: /run/secrets
          readOnly: true
        - name: home
          mountPath: /home
        # Provide a memory-backed /dev/shm like Docker's --shm-size
        - name: dshm
          mountPath: /dev/shm
      volumes:
      - name: user-secret
        secret:
          secretName: runtime-config
          items:
          - key: runtime_config
            path: runtime_config
      - name: home
        persistentVolumeClaim:
          claimName: devbox-home-pvc
      - name: dshm
        emptyDir:
          medium: Memory
          sizeLimit: "1Gi"
```

`service.yaml` (exposes RDP using a GKE LoadBalancer):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: xfce-rdp-lb
spec:
  type: LoadBalancer
  selector:
    app: xfce-rdp
  ports:
  - protocol: TCP
    port: 3389
    targetPort: 3389
```

3. Apply manifests

```bash
kubectl apply -f secret-runtime-config.yaml
kubectl apply -f pvc.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
```

4. Get external IP of the LoadBalancer

```bash
kubectl get svc xfce-rdp-lb --watch
```

Notes
- Replace `PROJECT_ID` in the `deployment.yaml` image reference with your GCP 
  project ID.
  - Create the Secret with `--from-file` as shown to avoid embedding plaintext in
    manifests. The Secret will mount a file at `/run/secrets/runtime_config` containing
    the runtime configuration JSON. The entrypoint validates and writes the
    configuration to `/etc/xfce-rdp/runtime_config.json` inside the container. Hooks
    and helper scripts are expected under `/etc/xfce-rdp/` and `/etc/xfce-rdp/hooks`.
- Adjust `storageClassName` in the PVC if your GKE cluster uses a different 
  default storage class.
- If you prefer not to expose a LoadBalancer, remove the `service.yaml` and use
  `kubectl port-forward` or a NodePort Service instead.
