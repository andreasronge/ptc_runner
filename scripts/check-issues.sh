#!/bin/bash
# Script to check and update SubAgent epic issues using Claude Code
# Usage: ./scripts/check-issues.sh [start_issue] [end_issue]
#        ./scripts/check-issues.sh 374 386
#        ./scripts/check-issues.sh 374  # single issue

set -e

REPO="andreasronge/ptc_runner"
START_ISSUE="${1:-374}"
END_ISSUE="${2:-$START_ISSUE}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== SubAgent Issue Checker ===${NC}"
echo "Checking issues #$START_ISSUE to #$END_ISSUE"
echo ""

for issue_num in $(seq $START_ISSUE $END_ISSUE); do
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Processing issue #$issue_num${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check if issue exists
    if ! gh issue view "$issue_num" --repo "$REPO" &>/dev/null; then
        echo -e "${RED}Issue #$issue_num not found, skipping${NC}"
        continue
    fi

    # Get issue title for display
    title=$(gh issue view "$issue_num" --repo "$REPO" --json title -q '.title')
    echo "Title: $title"
    echo ""

    # Call Claude Code to check and update the issue
    claude -p "You are checking GitHub issue #$issue_num in the ptc_runner repo.

Your task:
1. Fetch the issue: gh issue view $issue_num --repo $REPO --json body,title
2. Read the specification at docs/ptc_agents/specification.md to verify the issue matches the spec
3. Read docs/guidelines/issue-creation-guidelines.md for the template
4. Compare the issue against the guidelines template. Check for:
   - Current State section (what exists now)
   - Detailed Test Plan (not just 'Tests for X')
   - Edge cases in Implementation Hints
   - Documentation Updates section
   - Correct syntax/terminology matching the spec
   - Dependencies and Enables fields
5. If the issue needs updates, use gh issue edit to update it
6. Output a brief summary: UPDATED or NO CHANGES NEEDED, with reason

Be thorough but concise. Focus on making the issue implementable."

    echo ""
    echo -e "${GREEN}Completed issue #$issue_num${NC}"
    echo ""

    # Small delay to avoid rate limiting
    sleep 2
done

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Done! Processed issues #$START_ISSUE to #$END_ISSUE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
