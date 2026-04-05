#!/usr/bin/env bash
set -euo pipefail

# Minimal helper to build the xfce-rdp Docker image using the Dockerfile in src/
# Usage: ./build.sh [tag]
# Example: ./build.sh local/youruser/xfce-rdp:latest

tag="${1:-local/xfce-rdp:latest}"
scriptdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dockerfile="$scriptdir/src/Dockerfile"
build_context="$scriptdir/src"

echo "Building image '$tag' using Dockerfile: $dockerfile (context: $build_context)"
docker build -f "$dockerfile" -t "$tag" "$build_context"

echo "Built image: $tag"
