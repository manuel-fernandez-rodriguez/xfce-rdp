<div align="center">

# xfce-rdp
[![Docker](https://img.shields.io/badge/Docker-2CA5E0?logo=docker&logoColor=white)](docker.md)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-3069DE?logo=kubernetes&logoColor=white)](kubernetes.md)
[![Debian](https://img.shields.io/badge/Debian-A81D33?logo=debian)](https://www.debian.org/)

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/manuel-fernandez-rodriguez/xfce-rdp/publish-image.yml)](https://github.com/manuel-fernandez-rodriguez/xfce-rdp/actions/workflows/publish-image.yml)
[![GitHub License](https://img.shields.io/github/license/manuel-fernandez-rodriguez/xfce-rdp)](https://github.com/manuel-fernandez-rodriguez/xfce-rdp/blob/main/LICENSE.txt)
[![Github Package](https://img.shields.io/badge/package-xfce--rdp-latest)](https://github.com/manuel-fernandez-rodriguez/xfce-rdp/pkgs/container/xfce-rdp)

</div>

## Overview
**Debian Trixie** multiuser desktop environment based on **XFCE4**, accessible 
via Remote Desktop Protocol (RDP), with preinstalled:

- .NET10 SDK
- Visual Studio Code
- C# DevKit
- Firefox

## Quick Run on Docker

```bash
docker run -e RUNTIME_CONFIG='{"userCredentials":[{"username":"developer","password":"s3cr3t","sudo":true}]}' \
  -p 33890:3389 --shm-size=1g -d --name xfce-rdp xfce-rdp:latest
```

See more detailed instructions on [Docker setup](docker.md).

## Quick Run on Kubernetes

```bash
kubectl run xfce-rdp \
  --image=ghcr.io/manuel-fernandez-rodriguez/xfce-rdp:latest \
  --restart=Never --port=3389 --image-pull-policy=IfNotPresent \
  --env="RUNTIME_CONFIG={\"userCredentials\":[{\"username\":\"developer\",\"password\":\"s3cr3t\",\"sudo\":true}]}" \
  --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"xfce-rdp","volumeMounts":[{"name":"dshm","mountPath":"/dev/shm"}]}],"volumes":[{"name":"dshm","emptyDir":{"medium":"Memory","sizeLimit":"1Gi"}}]}}'
```

See more detailed instructions on [Kubernetes setup](kubernetes.md).

## Extending the image
The image is designed to be extended with custom hooks that run at container startup.

See [Extending the xfce-rdp base image](extending.md) for best practices and examples on how to add your own initialization logic without modifying the base image.