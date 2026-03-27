# Run this image as a Kubernetes Pod

This is a short, practical guide to run the `dev-box` image as a Kubernetes Pod,. keeping secrets out of plain env-vars in production.


## Quick test (not recommended for production)
This is not recommended for production since the password will be visible in the Pod spec, but it can be useful for a quick test or demo.

- Run via `kubectl run` with an env var password:

```bash
  kubectl run dev-box \
    --image=ghcr.io/manuel-fernandez-rodriguez/dev-box:latest \
    --restart=Never --port=3389 --image-pull-policy=IfNotPresent \
    --env="USER_PASSWORD=s3cr3t"
```

- Forward the RDP port:
  `kubectl port-forward pod/dev-box 33890:3389`

You can add a memory-backed `/dev/shm` for a quick test using `kubectl run --overrides` to modify the Pod spec inline. Example (bash):

```bash
kubectl run dev-box \
  --image=ghcr.io/manuel-fernandez-rodriguez/dev-box:latest \
  --restart=Never --port=3389 --image-pull-policy=IfNotPresent \
  --env="USER_PASSWORD=s3cr3t" \
  --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"dev-box","volumeMounts":[{"name":"dshm","mountPath":"/dev/shm"}]}],"volumes":[{"name":"dshm","emptyDir":{"medium":"Memory","sizeLimit":"1Gi"}}]}}'
```

PowerShell (use single quotes around the JSON payload):

```powershell
kubectl run dev-box `
  --image=ghcr.io/manuel-fernandez-rodriguez/dev-box:latest `
  --restart=Never --port=3389 --image-pull-policy=IfNotPresent `
  --env='USER_PASSWORD=s3cr3t' `
  --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"dev-box","volumeMounts":[{"name":"dshm","mountPath":"/dev/shm"}]}],"volumes":[{"name":"dshm","emptyDir":{"medium":"Memory","sizeLimit":"1Gi"}}]}}'
```

Note: `--overrides` is handy for quick testing, but using a Pod manifest (as shown in the next section) is clearer and more reproducible. Also, `sizeLimit` may be ignored on older Kubernetes versions — test on your cluster.

## Recommended: use a Secret mounted as `/run/secrets/user_password`
1. Create a secret (key `user_password`):
   `kubectl create secret generic user-password --from-literal=user_password='s3cr3t'`

2. Pod manifest (save as `dev-box-pod.yaml`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dev-box
spec:
  containers:
  - name: dev-box
    image: ghcr.io/manuel-fernandez-rodriguez/dev-box:latest
    imagePullPolicy: IfNotPresent
    ports:
    - containerPort: 3389
    env:
    - name: USER_NAME
      value: developer
    volumeMounts:
    - name: user-secret
      mountPath: /run/secrets
      readOnly: true
    - name: dshm
      mountPath: /dev/shm
  volumes:
  - name: user-secret
    secret:
      secretName: user-password
      items:
      - key: user_password
        path: user_password
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
Also monitor node memory usage and pick a size that leaves safe headroom for other pods.

3. Apply and forward:
  `kubectl apply -f dev-box-pod.yaml`
  `kubectl port-forward pod/dev-box 33890:3389`


## Optional: expose externally via a NodePort Service (save as `dev-box-svc.yaml`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: dev-box-svc
spec:
  type: NodePort
  selector:
    run: dev-box
  ports:
  - port: 3389
    targetPort: 3389
    nodePort: 30089
```

Notes
- If using a local image and Docker Desktop/kind, set `imagePullPolicy: IfNotPresent` or `Never` and ensure the image is loaded on cluster nodes.
- To persist `/home` across restarts, create a `PersistentVolumeClaim` and mount it at `/home` in the Pod.
- Prefer Secrets (mounted files) over env vars for passwords.


# GKE ready-to-apply manifests (includes PVC example)

Follow these steps to push the image to Google Container Registry (replace `PROJECT_ID`) and apply manifests on GKE.

1. Build and push image to GCR

   ```bash
   docker build -t dev-box:latest -f src/Dockerfile .
   docker tag dev-box:latest gcr.io/PROJECT_ID/dev-box:latest
   gcloud auth configure-docker
   docker push gcr.io/PROJECT_ID/dev-box:latest
   ```

2. Manifests

Save the following manifests and apply them with `kubectl apply -f <file>`.

`secret-user-password.yaml` (stores the runtime password as a file under `/run/secrets/user_password`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: user-password
type: Opaque
stringData:
  user_password: "s3cr3t" # replace with your password
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
  name: dev-box
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dev-box
  template:
    metadata:
      labels:
        app: dev-box
    spec:
      containers:
      - name: dev-box
        image: ghcr.io/manuel-fernandez-rodriguez/dev-box:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3389
        env:
        - name: USER_NAME
          value: developer
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
          secretName: user-password
          items:
          - key: user_password
            path: user_password
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
  name: dev-box-lb
spec:
  type: LoadBalancer
  selector:
    app: dev-box
  ports:
  - protocol: TCP
    port: 3389
    targetPort: 3389
```

3. Apply manifests

```bash
kubectl apply -f secret-user-password.yaml
kubectl apply -f pvc.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
```

4. Get external IP of the LoadBalancer

```bash
kubectl get svc dev-box-lb --watch
```

Notes
- Replace `PROJECT_ID` in the `deployment.yaml` image reference with your GCP project ID.
- The `stringData` field in the Secret manifest allows you to provide the password in plain text; Kubernetes will store it as base64. For higher security, create the Secret out-of-band and avoid committing passwords to Git.
- Adjust `storageClassName` in the PVC if your GKE cluster uses a different default storage class.
- If you prefer not to expose a LoadBalancer, remove the `service.yaml` and use `kubectl port-forward` or a NodePort Service instead.
