#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

ansible-playbook \
  -i inventories/dev/hosts.ini \
  remote-check.yml \
  --syntax-check

"$HOME/.local/bin/ansible-lint" \
  remote-check.yml \
  roles/cron_service/tasks/main.yml

echo "Syntax and lint checks passed."
