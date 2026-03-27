# dev-box
<img src="https://img.shields.io/badge/Docker-2CA5E0?logo=docker&logoColor=white" /> <img src="https://img.shields.io/badge/Kubernetes-3069DE?logo=kubernetes&logoColor=white" />

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/manuel-fernandez-rodriguez/dev-box/publish-image.yml)](https://github.com/manuel-fernandez-rodriguez/dev-box/actions/workflows/publish-image.yml)
[![GitHub License](https://img.shields.io/github/license/manuel-fernandez-rodriguez/dev-box)](https://github.com/manuel-fernandez-rodriguez/dev-box/blob/main/LICENSE.txt)
[![Github Package](https://img.shields.io/badge/package-dev--box-latest)](https://github.com/manuel-fernandez-rodriguez/dev-box/pkgs/container/dev-box)

Full xfce4 desktop environment with:

- .NET10 SDK
- Visual Studio Code 
- c# DevKit
- Firefox

The environment is accessible via Remote Desktop Protocol (RDP) on any other port you choose.

## Run on Docker
This will run the container with the default username `developer` and the password `s3cr3t`. 
The RDP port will be forwarded to 33890 on the host, and a 1GB of shared memory` will be allocated 
to be able to run Firefox and VS Code.

```bash
docker run -e USER_PASSWORD='s3cr3t' -p 33890:3389 \
  --shm-size=1g -d --name dev-box ghcr.io/manuel-fernandez-rodriguez/dev-box:latest
```
See [docker.md](docker.md) for more detailed instructions.

## Run on Kubernetes
This will run the container with the default username `developer` and the password `s3cr3t`. 
The RDP port will be forwarded to 33890 on the host, and a 1GB of shared memory` will be allocated 
to be able to run Firefox and VS Code.

```bash
kubectl run dev-box \
  --image=ghcr.io/manuel-fernandez-rodriguez/dev-box:latest \
  --restart=Never --port=3389 --image-pull-policy=IfNotPresent \
  --env="USER_PASSWORD=s3cr3t" \
  --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"dev-box","volumeMounts":[{"name":"dshm","mountPath":"/dev/shm"}]}],"volumes":[{"name":"dshm","emptyDir":{"medium":"Memory","sizeLimit":"1Gi"}}]}}'
```
See [kubernetes.md](kubernetes.md) for more detailed instructions.