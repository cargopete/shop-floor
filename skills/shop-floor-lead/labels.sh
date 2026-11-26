#!/usr/bin/env bash
# labels.sh owner/repo [owner/repo ...]: create or update the shop-floor labels.
# SF_GH overrides the gh command, as in launch-worker.sh.
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: labels.sh owner/repo [owner/repo ...]" >&2; exit 1; }
read -r -a GH <<<"${SF_GH:-gh}"
for repo in "$@"; do
  "${GH[@]}" label create needs-decision --repo "$repo" --force --color D93F0B --description "A human has to choose; the question is in the latest comment"
  "${GH[@]}" label create worker-running --repo "$repo" --force --color FBCA04 --description "A headless worker is on this right now"
  "${GH[@]}" label create worker-failed --repo "$repo" --force --color B60205 --description "The last worker run ended without a PR"
  "${GH[@]}" label create agent --repo "$repo" --force --color 0E8A16 --description "Small and clear enough to hand to a worker"
  echo "labels ready on $repo"
done
