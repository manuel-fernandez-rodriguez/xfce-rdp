#!/usr/bin/env bash
set -euo pipefail

# Minimal helper to build the dev-box Docker image using the Dockerfile in src/
# Usage: ./build.sh [tag]
# Example: ./build.sh local/youruser/dev-box:latest

tag="${1:-local/dev-box:latest}"
scriptdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dockerfile="$scriptdir/src/Dockerfile"
build_context="$scriptdir/src"

echo "Building image '$tag' using Dockerfile: $dockerfile (context: $build_context)"
docker build -f "$dockerfile" -t "$tag" "$build_context"

echo "Built image: $tag"
