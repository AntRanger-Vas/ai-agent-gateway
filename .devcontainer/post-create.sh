#!/usr/bin/env bash
# Runs once when the Codespace is created: installs the few tools the
# examples need that the base image may lack.
set -euo pipefail

sudo apt-get update -qq
sudo apt-get install -y -qq jq make python3 >/dev/null

echo
echo "Codespace ready: $(go version | cut -d' ' -f3), node $(node --version), $(docker --version | cut -d, -f1)"
echo "Start the gateway lab with:  bash .devcontainer/lab-up.sh"
