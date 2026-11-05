#!/usr/bin/env bash
# Puts the demo back to its starting point: run it before every rehearsal and before going live.
#   1. demo on GitHub and locally goes back to the demo-start tag, and fix branches and PRs are closed.
#   2. The cart classes in abcDev go back to the demo-start version.
#   3. The demo records are removed and seeded again.
# Add --teardown to remove the demo records and leave them out, for after the evaluation.
set -euo pipefail

REPO="youssef20031/cloudastick-salesforce-assessment"
ORG="abcDev"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../.."

# On Windows, plain "bash" in PowerShell is WSL, which can't see these tools. Use Git Bash.
for tool in git gh sf; do
  if ! command -v "$tool" >/dev/null; then
    echo "$tool not found. Run this from Git Bash, not WSL. Nothing was changed." >&2
    exit 1
  fi
done

if [ "$(git rev-parse --abbrev-ref HEAD)" != "demo" ] && ! git rev-parse --abbrev-ref HEAD | grep -q '^fix/'; then
  echo "Run this from the demo branch or a fix/ branch." >&2
  exit 1
fi

echo "== Closing open demo pull requests"
gh pr list --repo "$REPO" --base demo --state open --json number --jq '.[].number' | while read -r number; do
  gh pr close "$number" --repo "$REPO" --delete-branch
done

echo "== Moving demo back to demo-start"
git switch demo
# --keep leaves unrelated uncommitted changes alone, and stops rather than overwrite one.
git reset --keep demo-start
git push --force origin demo-start:refs/heads/demo

for branch in $(git for-each-ref --format='%(refname:short)' 'refs/heads/fix/*'); do
  git branch -D "$branch"
done
for branch in $(git ls-remote --heads origin 'fix/*' | sed 's#.*refs/heads/##'); do
  git push origin --delete "$branch"
done

echo "== Restoring the cart classes in abcDev"
sf project deploy start --target-org "$ORG" --wait 30 \
  --source-dir force-app/main/default/classes/abc_CartService.cls \
  --source-dir force-app/main/default/classes/abc_CartServiceTest.cls \
  --test-level RunSpecifiedTests --tests abc_CartServiceTest --tests abc_CartRestResourceTest

run_apex() {
  local log
  log="$(sf apex run --target-org "$ORG" --file "$1" 2>&1)" || { echo "$log" >&2; exit 1; }
  if ! grep -q 'Executed successfully' <<<"$log"; then
    echo "$log" >&2
    exit 1
  fi
  grep -E 'USER_DEBUG.*DEMO' <<<"$log" | sed 's/.*DEBUG|//'
}

echo "== Removing the demo records"
run_apex scripts/demo/teardown.apex

if [ "${1:-}" = "--teardown" ]; then
  echo "== Done: demo records removed and not seeded again."
  exit 0
fi

echo "== Seeding the demo records"
run_apex scripts/demo/seed.apex

echo "== Ready."
