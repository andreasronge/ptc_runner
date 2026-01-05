#!/bin/bash
# Wrapper script that checks all open non-epic GitHub issues
# Usage: ./scripts/check-issues-with-progress.sh

set -e

REPO="andreasronge/ptc_runner"
DEBUG="${DEBUG:-false}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Create temp file for results
RESULTS_FILE=$(mktemp)
trap "rm -f $RESULTS_FILE" EXIT

echo -e "${YELLOW}=== Issue Checker with Progress ===${NC}"
echo "Fetching open non-epic issues..."

# Get all open issues that don't have "epic" label and don't have "Epic:" in title
ISSUES=$(gh issue list --state open --json number,title,labels --jq '
  .[] |
  select(.labels | map(.name | ascii_downcase) | index("epic") | not) |
  select(.title | startswith("Epic:") | not) |
  .number
' | sort -n)

if [ -z "$ISSUES" ]; then
    echo -e "${RED}No open non-epic issues found${NC}"
    exit 0
fi

TOTAL=$(echo "$ISSUES" | wc -l | tr -d ' ')
echo "Found $TOTAL open non-epic issues"
echo ""

CURRENT=0
UPDATED=0
NO_CHANGES=0

for issue_num in $ISSUES; do
    CURRENT=$((CURRENT + 1))

    # Progress bar
    echo -e "${BLUE}[$CURRENT/$TOTAL]${NC} Processing issue #$issue_num..."

    # Get issue title
    title=$(gh issue view "$issue_num" --repo "$REPO" --json title -q '.title')
    echo -e "  Title: ${title:0:60}..."

    # Get updated_at before
    BEFORE=$(gh issue view "$issue_num" --repo "$REPO" --json updatedAt -q '.updatedAt')

    # Build prompt using heredoc to avoid escaping issues
    PROMPT=$(cat <<PROMPT_END
You are checking GitHub issue #$issue_num in the ptc_runner repo.

Your task:
1. Fetch the issue: gh issue view $issue_num --repo $REPO --json body,title
2. Read the specification at docs/ptc-lisp-v2-requirements.md to verify the issue matches the spec
3. Read docs/guidelines/issue-creation-guidelines.md for the template and sizing guidelines
4. Compare the issue against the guidelines template. Check for:
   - Current State section (what exists now, based on actual codebase analysis)
   - Detailed Test Plan (not just 'Tests for X')
   - Edge cases in Implementation Hints
   - Documentation Updates section
   - Correct syntax/terminology matching the spec
   - Dependencies and Related issues fields
5. Verify requirements coverage:
   - Check that Requirements covered section lists valid REQ-* IDs from the requirements doc
   - Each listed requirement should exist in docs/ptc-lisp-v2-requirements.md
   - Add a brief description (copied from req doc) next to each requirement ID
   - Example: REQ-VAR-1 (Vars print as hash-quote name), REQ-VAR-2 (No full namespace path)
6. Check issue sizing per guidelines:
   - Too large if: >5 acceptance criteria, touches >5 files, or says and also
   - If too large: split into multiple issues, create new issues with gh issue create, then update the epic issue (#564) to include links to new issues
7. If the issue needs updates, use gh issue edit to update it
8. Output ONLY one line at the end: either RESULT: UPDATED - reason or RESULT: NO_CHANGES - reason

Be thorough but concise. Focus on making the issue implementable.
PROMPT_END
)

    # Run claude with timeout (5 minutes max per issue)
    OUTPUT=$(timeout 300 claude -p "$PROMPT" 2>&1) || {
        echo -e "  ${RED}✗ TIMEOUT or ERROR${NC}"
        echo "$issue_num:TIMEOUT:Claude timed out after 5 minutes" >> "$RESULTS_FILE"
        continue
    }

    # Debug: show Claude's raw output
    if [ "$DEBUG" = "true" ]; then
        echo -e "  ${YELLOW}--- DEBUG: Claude output start ---${NC}"
        echo "$OUTPUT" | head -50
        echo -e "  ${YELLOW}--- DEBUG: Claude output end ---${NC}"
    fi

    # Check updated_at after
    AFTER=$(gh issue view "$issue_num" --repo "$REPO" --json updatedAt -q '.updatedAt')

    # Determine result
    if [ "$BEFORE" != "$AFTER" ]; then
        echo -e "  ${GREEN}✓ UPDATED${NC} (timestamp changed)"
        UPDATED=$((UPDATED + 1))
        REASON=$(echo "$OUTPUT" | grep -i "RESULT:" | tail -1 || echo "Updated")
        echo "$issue_num:UPDATED:$REASON" >> "$RESULTS_FILE"
    else
        # Check Claude's output for result
        if echo "$OUTPUT" | grep -qi "RESULT:.*UPDATED"; then
            echo -e "  ${YELLOW}? CLAIMED UPDATED but timestamp unchanged${NC}"
            REASON=$(echo "$OUTPUT" | grep -i "RESULT:" | tail -1)
            echo "$issue_num:CLAIMED_UPDATED:$REASON" >> "$RESULTS_FILE"
        else
            echo -e "  ${BLUE}○ NO CHANGES NEEDED${NC}"
            NO_CHANGES=$((NO_CHANGES + 1))
            REASON=$(echo "$OUTPUT" | grep -i "RESULT:" | tail -1 || echo "No changes needed")
            echo "$issue_num:NO_CHANGES:$REASON" >> "$RESULTS_FILE"
        fi
    fi

    # Small delay
    sleep 1
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Summary${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Total processed: $TOTAL"
echo -e "  ${GREEN}Updated:${NC}          $UPDATED"
echo -e "  ${BLUE}No changes:${NC}       $NO_CHANGES"
echo ""
echo -e "${YELLOW}Detailed Results:${NC}"
cat "$RESULTS_FILE" | while IFS=: read -r num status reason; do
    case "$status" in
        UPDATED) echo -e "  ${GREEN}#$num${NC}: $reason" ;;
        NO_CHANGES) echo -e "  ${BLUE}#$num${NC}: $reason" ;;
        *) echo -e "  ${YELLOW}#$num${NC}: $status - $reason" ;;
    esac
done
echo ""
