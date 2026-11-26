#!/usr/bin/env bash
# labels.sh owner/repo [owner/repo ...]: create or update the shop-floor labels.
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: labels.sh owner/repo [owner/repo ...]" >&2; exit 1; }
for repo in "$@"; do
  gh label create needs-decision --repo "$repo" --force --color D93F0B --description "A human has to choose; the question is in the latest comment"
  gh label create worker-running --repo "$repo" --force --color FBCA04 --description "A headless worker is on this right now"
  gh label create worker-failed --repo "$repo" --force --color B60205 --description "The last worker run ended without a PR"
  gh label create agent --repo "$repo" --force --color 0E8A16 --description "Small and clear enough to hand to a worker"
  echo "labels ready on $repo"
done
