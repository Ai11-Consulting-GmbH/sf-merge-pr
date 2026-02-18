# SFDCMergePR

**3-way merge of GitHub PR changes onto any target Salesforce org** — without overwriting the org's existing code.

## The Problem

Deploying a merged PR to a non-production org (preprod, staging, QA) with a naive file copy **destroys** changes that only exist in that org:

- Hotfixes applied directly to the org
- Org-specific customizations
- Changes from other PRs deployed out of order

## The Solution

This tool uses **git's 3-way merge algorithm** to compute the exact delta (additions + removals) of a PR and surgically apply only those changes on top of the target org's current code.

```
PR Parent (before)         PR Result (after)
     |                          |
     +---- computes delta ------+
                  |
            applies onto
                  |
                  v
        Target Org Code  -->  Merged Result
```

## Installation

### As an AI Agent Skill

Clone the repo into your skills directory:

```bash
# For OpenCode
git clone https://github.com/Ai11-Consulting-GmbH/sf-merge-pr.git ~/.config/opencode/skills/sfdc-merge-pr

# For Claude Code
git clone https://github.com/Ai11-Consulting-GmbH/sf-merge-pr.git ~/.claude/skills/sfdc-merge-pr
```

The skill will be auto-discovered on next session. Invoke it with `/deploy-pr <PR_NUMBER> <TARGET_ORG>`.

### Standalone (no AI agent)

```bash
git clone https://github.com/Ai11-Consulting-GmbH/sf-merge-pr.git
chmod +x SFDCMergePR/merge-pr.sh
```

Run `merge-pr.sh` directly from your Salesforce project directory.

## Quick Start

```bash
# Preview merge (no deployment)
./merge-pr.sh 2265 MyOrg.preprod

# Preview only (explicit dry run)
./merge-pr.sh 2265 MyOrg.preprod --dry-run

# Merge and deploy
./merge-pr.sh 2265 MyOrg.preprod --deploy
```

## Prerequisites

| Requirement | How to verify |
|-------------|---------------|
| **Salesforce CLI (`sf`)** | `sf --version` |
| **Authenticated target org** | `sf org list` |
| **PR already merged** in local git | `git log --oneline --grep="#<PR>"` |
| **Git repo with merge history** | `git fetch` if commits are missing |

## How It Works

| Step | Action |
|------|--------|
| 1 | Finds the merge commit for the PR via `git log --grep` |
| 2 | Extracts before/after Apex class versions from git |
| 3 | Retrieves current versions from the target org (`sf project retrieve start`) |
| 4 | Normalizes line endings (CRLF to LF) |
| 5 | Runs `git merge-file` (3-way merge) for each changed file |
| 6 | Reports results: **CLEAN**, **WHITESPACE-ONLY**, or **CONFLICT** |
| 7 | Optionally deploys clean merges to the target org |

## Merge Report

The script categorizes every file into one of three outcomes:

| Symbol | Category | Meaning |
|--------|----------|---------|
| `+` | **CLEAN** | Merged successfully, ready to deploy |
| `~` | **WHITESPACE-ONLY** | No real changes after merge, skipped |
| `!` | **CONFLICT** | Both the PR and the target org modified the same code section |

## Handling Conflicts

When conflicts occur, the merged files with conflict markers are written to `/tmp/pr-merge-<PR>/merged/`. Resolve them manually or with AI assistance, then deploy with:

```bash
sf project deploy start -m ApexClass:ClassName --target-org MyOrg.preprod
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All merges clean, or deploy succeeded |
| `1` | Conflicts found — needs review |
| `2` | Usage error or prerequisites not met |

## Working Directory

All intermediate files are stored in `/tmp/pr-merge-<PR>/`:

```
/tmp/pr-merge-2265/
  before/        # PR parent versions (from git)
  after/         # PR result versions (from git)
  preprod/       # Target org versions (from sf retrieve)
  merged/        # Final merged results
```

## Limitations

- **Apex classes only** (`.cls` files) — does not handle triggers, LWC, Aura, flows, or other metadata types
- Requires the merge commit message to contain `(#PR_NUMBER)` (standard GitHub merge format)
- The `--deploy` flag refuses to deploy if any file has conflicts (safety measure)

## License

MIT
