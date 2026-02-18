#!/bin/bash
# =============================================================================
# merge-pr.sh — 3-way merge of PR changes onto a target Salesforce org
#
# Usage: ./merge-pr.sh <PR_NUMBER> <TARGET_ORG> [--deploy] [--dry-run]
#
# Steps:
#   1. Finds the merge commit for the given PR
#   2. Extracts before/after versions from git
#   3. Retrieves current versions from the target org
#   4. Normalizes line endings
#   5. Performs 3-way merge (git merge-file)
#   6. Reports results (clean merges, conflicts, whitespace-only)
#   7. Optionally deploys clean merges
#
# Exit codes:
#   0 = all merges clean (or deployed successfully)
#   1 = conflicts found (needs AI/manual review)
#   2 = usage error or prerequisites not met
# =============================================================================

set -eo pipefail

# --- Arguments ---
PR_NUMBER="${1:-}"
TARGET_ORG="${2:-}"
DEPLOY_FLAG="${3:-}"
WORKDIR="/tmp/pr-merge-${PR_NUMBER}"

if [[ -z "$PR_NUMBER" || -z "$TARGET_ORG" ]]; then
    echo "Usage: $0 <PR_NUMBER> <TARGET_ORG> [--deploy|--dry-run]"
    echo ""
    echo "Examples:"
    echo "  $0 2265 user@example.com.preprod"
    echo "  $0 2265 user@example.com.preprod --deploy"
    echo "  $0 2265 user@example.com.preprod --dry-run"
    exit 2
fi

# --- Find merge commit ---
echo "=== Step 1: Finding merge commit for PR #${PR_NUMBER} ==="
MERGE_COMMIT=$(git log --all --oneline --grep="#${PR_NUMBER})" | head -1 | awk '{print $1}')

if [[ -z "$MERGE_COMMIT" ]]; then
    echo "ERROR: Could not find merge commit for PR #${PR_NUMBER}"
    echo "Make sure the PR is merged and the commit message contains '(#${PR_NUMBER})'"
    exit 2
fi
echo "Found merge commit: ${MERGE_COMMIT}"

# --- Get changed files ---
echo ""
echo "=== Step 2: Identifying changed Apex classes ==="
CHANGED_FILES=$(git show "$MERGE_COMMIT" --name-only --pretty=format:"" | grep "force-app/main/default/classes/.*\.cls$" | grep -v meta.xml || true)

if [[ -z "$CHANGED_FILES" ]]; then
    echo "ERROR: No Apex class changes found in PR #${PR_NUMBER}"
    exit 2
fi

# Extract class names
CLASS_NAMES=()
while IFS= read -r file; do
    cls=$(basename "$file" .cls)
    CLASS_NAMES+=("$cls")
    echo "  - $cls"
done <<< "$CHANGED_FILES"

# --- Setup directories ---
echo ""
echo "=== Step 3: Extracting before/after versions ==="
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"/{before,after,preprod,merged}

for cls in "${CLASS_NAMES[@]}"; do
    for ext in ".cls" ".cls-meta.xml"; do
        file="${cls}${ext}"
        path="force-app/main/default/classes/${file}"
        git show "${MERGE_COMMIT}^:${path}" > "$WORKDIR/before/${file}" 2>/dev/null || true
        git show "${MERGE_COMMIT}:${path}" > "$WORKDIR/after/${file}" 2>/dev/null || true
    done
done
echo "Extracted to $WORKDIR"

# --- Retrieve from target org ---
echo ""
echo "=== Step 4: Retrieving from ${TARGET_ORG} ==="
METADATA_ARGS=""
for cls in "${CLASS_NAMES[@]}"; do
    METADATA_ARGS="$METADATA_ARGS -m ApexClass:${cls}"
done

sf project retrieve start $METADATA_ARGS --target-org "$TARGET_ORG" --output-dir "$WORKDIR/preprod" 2>&1 | tail -20
echo ""

# --- Normalize line endings ---
echo "=== Step 5: Normalizing line endings ==="
find "$WORKDIR" -type f \( -name "*.cls" -o -name "*.xml" \) -exec sed -i '' 's/\r$//' {} \;
echo "Done"

# --- 3-way merge ---
echo ""
echo "=== Step 6: Performing 3-way merge ==="

CLEAN_FILES=()
CONFLICT_FILES=()
WHITESPACE_ONLY=()
HAS_CONFLICTS=false

for cls in "${CLASS_NAMES[@]}"; do
    for ext in ".cls" ".cls-meta.xml"; do
        file="${cls}${ext}"
        before="$WORKDIR/before/${file}"
        after="$WORKDIR/after/${file}"
        preprod="$WORKDIR/preprod/classes/${file}"
        merged="$WORKDIR/merged/${file}"

        # Skip if preprod file doesn't exist
        if [[ ! -f "$preprod" ]]; then
            echo "  SKIP $file (not in target org)"
            continue
        fi

        # Skip if before/after don't exist
        if [[ ! -f "$before" || ! -f "$after" ]]; then
            echo "  SKIP $file (not in PR)"
            continue
        fi

        # Copy preprod to merged directory
        cp "$preprod" "$merged"

        # Perform 3-way merge
        set +e
        git merge-file "$merged" "$before" "$after" 2>/dev/null
        rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            # Check if there are real changes (not just whitespace)
            if diff -q -w "$preprod" "$merged" > /dev/null 2>&1; then
                echo "  WHITESPACE-ONLY $file (no real changes)"
                WHITESPACE_ONLY+=("$file")
                # Reset to preprod version
                cp "$preprod" "$merged"
            else
                echo "  CLEAN $file"
                CLEAN_FILES+=("$file")
            fi
        else
            echo "  CONFLICT $file ($rc conflicts)"
            CONFLICT_FILES+=("$file")
            HAS_CONFLICTS=true
        fi
    done
done

# --- Report ---
echo ""
echo "============================================"
echo "  MERGE REPORT — PR #${PR_NUMBER} → ${TARGET_ORG}"
echo "============================================"
echo ""

if [[ ${#CLEAN_FILES[@]} -gt 0 ]]; then
    echo "CLEAN MERGES (ready to deploy):"
    for f in "${CLEAN_FILES[@]}"; do
        echo "  + $f"
    done
    echo ""
fi

if [[ ${#WHITESPACE_ONLY[@]} -gt 0 ]]; then
    echo "WHITESPACE-ONLY (skipped):"
    for f in "${WHITESPACE_ONLY[@]}"; do
        echo "  ~ $f"
    done
    echo ""
fi

if [[ ${#CONFLICT_FILES[@]} -gt 0 ]]; then
    echo "CONFLICTS (need manual/AI review):"
    for f in "${CONFLICT_FILES[@]}"; do
        echo "  ! $f"
    done
    echo ""
fi

# --- Show diffs for clean merges ---
if [[ ${#CLEAN_FILES[@]} -gt 0 ]]; then
    echo "--- Changes to be applied ---"
    for f in "${CLEAN_FILES[@]}"; do
        result=$(diff -u "$WORKDIR/preprod/classes/$f" "$WORKDIR/merged/$f" 2>/dev/null || true)
        if [[ -n "$result" ]]; then
            echo ""
            echo "=== $f ==="
            echo "$result"
        fi
    done
else
    echo "No changes to apply."
fi

# --- Deploy or dry-run ---
if [[ "$DEPLOY_FLAG" == "--deploy" && ${#CLEAN_FILES[@]} -gt 0 && "$HAS_CONFLICTS" == "false" ]]; then
    echo ""
    echo "=== Step 7: Deploying to ${TARGET_ORG} ==="

    # Copy merged files to project
    PROJECT_CLASSES="force-app/main/default/classes"
    for f in "${CLEAN_FILES[@]}"; do
        cp "$WORKDIR/merged/$f" "$PROJECT_CLASSES/$f"
    done

    # Build deploy command
    DEPLOY_CLASSES=()
    for cls in "${CLASS_NAMES[@]}"; do
        # Only include classes that have clean merges
        for f in "${CLEAN_FILES[@]}"; do
            if [[ "$f" == "${cls}.cls" ]]; then
                DEPLOY_CLASSES+=("-m" "ApexClass:${cls}")
                break
            fi
        done
    done

    if [[ ${#DEPLOY_CLASSES[@]} -gt 0 ]]; then
        sf project deploy start "${DEPLOY_CLASSES[@]}" --target-org "$TARGET_ORG" 2>&1 | tail -30
    fi

elif [[ "$DEPLOY_FLAG" == "--dry-run" ]]; then
    echo ""
    echo "DRY RUN — no changes deployed"
    echo "Merged files available in: $WORKDIR/merged/"

else
    echo ""
    echo "Merged files available in: $WORKDIR/merged/"
    if [[ "$HAS_CONFLICTS" == "true" ]]; then
        echo "Resolve conflicts before deploying."
        exit 1
    fi
    echo "Run with --deploy to deploy, or --dry-run to preview only."
fi

echo ""
echo "Working directory: $WORKDIR"
