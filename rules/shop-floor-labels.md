---
description: The shop-floor label convention for GitHub issues and PRs. Use when creating, triaging or labelling issues and PRs, or launching workers.
alwaysApply: false
---

# Labels

| label | on | means | who sets it |
|---|---|---|---|
| `needs-decision` | issue or PR | a human has to choose something; the question is in the latest comment | the lead or a worker |
| `worker-running` | issue | a headless worker is on it right now; leave it alone | the launcher (removed when the run ends) |
| `worker-failed` | issue | the last run ended without a PR (cap hit, crash or gave up); the result is in a comment | the launcher, or the lead after reading the result |
| `agent` | issue | small and clear enough to hand to a worker | the lead |
| `followup` | issue | found while doing something else; out of scope then, worth doing later | anyone, via the shop-floor-followups skill |

Rules of thumb:

- A `needs-decision` comment states the question, the options, and what you'd
  pick and why, so the answer can be one word.
- Remove `needs-decision` once it's answered, and say what was decided.
- Never leave `worker-running` on an issue nobody is working on. If a run died,
  swap it for `worker-failed`.
- `needs-me` (in this repo) lists `needs-decision` and `worker-failed` items,
  failing PRs and green PRs. Anything else isn't waiting on a human.
  `followup` issues are backlog: `needs-me` counts them under the list.
- Create the labels once per repo with the lead skill's `labels.sh`.
