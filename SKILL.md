---
name: sfdc-merge-pr
description: "Deploy a PR's Apex class changes to a target Salesforce org using 3-way merge (preserves target org state)"
user-invokable: true
allowed-tools:
  - bash
  - read
  - write
  - grep
  - glob
---

# Deploy PR to Target Org

## What This Skill Does

This skill safely deploys a merged GitHub PR's Apex class changes to any target Salesforce org (preprod, staging, etc.) without overwriting the target org's existing code. It uses a **3-way merge strategy** — the same approach git uses for merging branches — to apply only the PR's delta (additions and removals) on top of whatever code the target org currently has.

### Why This Exists

When deploying to non-production orgs, the target org often has a **different code base** than the source branch. A naive deployment (overwriting the whole file) would:
- Destroy changes that exist in the target org but not in the source branch
- Revert fixes that were hotfixed directly into the org
- Break code that depends on org-specific modifications

This skill solves that by computing exactly what the PR changed (the delta) and surgically applying only those changes to the target org's code.

## Usage

```
/deploy-pr <PR_NUMBER> <TARGET_ORG>
```

### Examples
```
/deploy-pr 2265 user@example.com.preprod
/deploy-pr 2345 Staging
/deploy-pr 2374 user@example.com.staging
```

### Arguments
| Argument | Description | Examples |
|----------|-------------|----------|
| `PR_NUMBER` | The GitHub PR number (must already be merged) | `2265`, `2345` |
| `TARGET_ORG` | Salesforce org alias or username | `Staging`, `user@example.com.preprod` |

## How It Works — Combined Shell + AI Approach

### Phase 1: Automated (Shell Script)

Run the merge script to handle the mechanical work:

```bash
bash ./merge-pr.sh <PR_NUMBER> <TARGET_ORG>
```

The script performs these steps automatically:

| Step | What It Does |
|------|-------------|
| 1. Find merge commit | Searches git log for `(#PR_NUMBER)` in commit messages |
| 2. Identify classes | Lists all Apex classes changed in the PR |
| 3. Extract versions | Gets "before" (parent commit) and "after" (merge result) from git |
| 4. Retrieve from org | Runs `sf project retrieve start` to get target org's current code |
| 5. Normalize | Converts CRLF → LF line endings to avoid false conflicts |
| 6. 3-way merge | Runs `git merge-file` for each file — the core merge algorithm |
| 7. Report | Categorizes results: CLEAN, WHITESPACE-ONLY, or CONFLICT |

#### How 3-Way Merge Works

```
    PR Parent (before)              PR Result (after)
         │                               │
         └──── git merge-file computes ───┘
                   the delta
                      │
                applies onto
                      │
                      ▼
              Target Org Code  ──►  Merged Result
```

- **Before**: The code as it was before the PR
- **After**: The code after the PR was merged
- **Target Org**: What's currently in the target Salesforce org
- **Merged Result**: Target org code + only the PR's changes applied

### Phase 2: AI Review

After the script runs, review the output:

1. **Clean merges** (`+`): Verify the diffs make semantic sense
   - No logic accidentally removed or duplicated
   - Renamed variables/methods are consistent across all files
   - The merged code compiles logically

2. **Whitespace-only** (`~`): Skipped automatically — confirm this is correct
   - Sometimes formatting changes ARE intentional (e.g., method signature refactoring that the PR intended)

3. **Conflicts** (`!`): Need manual resolution
   - Read conflict markers in `/tmp/pr-merge-<PR>/merged/`
   - Common causes: same code section modified in both PR and target org
   - Resolve and save the file

4. **Meta.xml compatibility**: Check package version numbers
   - Target org may not have the latest managed package versions
   - When in doubt, use the **target org's** package version numbers
   - This is the most common deploy failure reason

5. **Deploy errors**: If deployment fails
   - `Package Version number does not exist` → use target org's meta.xml versions
   - Compilation errors → a dependency class is missing; include it
   - Test failures → run tests to diagnose

### Phase 3: Deploy

**Option A** — Automatic (if all merges are clean and no conflicts):
```bash
bash ./merge-pr.sh <PR_NUMBER> <TARGET_ORG> --deploy
```

**Option B** — Manual (after resolving conflicts or fixing meta.xml):
```bash
sf project deploy start -m ApexClass:Class1 -m ApexClass:Class2 --target-org <TARGET_ORG>
```

**Option C** — Dry run (preview only, no deployment):
```bash
bash ./merge-pr.sh <PR_NUMBER> <TARGET_ORG> --dry-run
```

## Script Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All merges clean, or deploy succeeded |
| `1` | Conflicts found — needs AI/manual review |
| `2` | Usage error or prerequisites not met |

## File Locations

| Path | Purpose |
|------|---------|
| `./merge-pr.sh` | The automation shell script |
| `/tmp/pr-merge-<PR>/before/` | PR parent versions (from git) |
| `/tmp/pr-merge-<PR>/after/` | PR merged versions (from git) |
| `/tmp/pr-merge-<PR>/preprod/classes/` | Target org versions (from sf retrieve) |
| `/tmp/pr-merge-<PR>/merged/` | Final merged results (deploy these) |

## Prerequisites

- The PR must already be **merged** into the git history
- `sf` CLI must be authenticated to the target org (`sf org list` to verify)
- The git repo must contain the merge commit locally (`git fetch` if needed)

## Known Limitations

- Only handles **Apex classes** (`.cls` files). Does not handle triggers, LWC, Aura, flows, or other metadata types.
- Requires the merge commit message to contain `(#PR_NUMBER)` — the standard GitHub merge format.
- The `--deploy` flag will not deploy if any file has conflicts (safety measure).
