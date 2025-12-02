#!/bin/bash

# Script to wrap program definitions with {"program": ...} wrapper format
# This is a safe, bash-only approach that doesn't require external scripting languages

set -euo pipefail

file="test/ptc_runner_test.exs"
backup="${file}.backup"

echo "========================================================================"
echo "Wrapping program definitions with {\"program\": ...}"
echo "========================================================================"
echo ""

# Create backup
cp "$file" "$backup"
echo "✓ Created backup: $backup"

# Count programs before
count_before=$(grep -c "program = ~s(" "$file" || true)
echo "✓ Found $count_before program definitions"
echo ""

# Python one-liner to do the transformation
python3 - "$file" "$backup" <<'PYTHON_SCRIPT'
import sys
import re

def find_matching_paren(text, start_pos):
    """Find matching closing parenthesis."""
    depth = 1
    i = start_pos + 1
    while i < len(text) and depth > 0:
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
        i += 1
    return i - 1 if depth == 0 else -1

def wrap_program_json(json_content):
    """Wrap JSON with {"program": ...} if not already wrapped."""
    stripped = json_content.strip()
    if stripped.startswith('{"program":') or stripped.startswith('{ "program":'):
        return json_content
    return '{"program": ' + json_content + '}'

def process_file(file_path):
    """Process file and wrap all program definitions."""
    with open(file_path, 'r') as f:
        content = f.read()

    pattern = r'program\s*=\s*~s\('
    matches = []

    for match in re.finditer(pattern, content):
        start = match.end() - 1  # Position of '(' after ~s
        end = find_matching_paren(content, start)

        if end == -1:
            print(f"WARNING: Could not find matching ')' at position {start}")
            continue

        json_content = content[start + 1:end]
        matches.append({
            'start': start + 1,
            'end': end,
            'original': json_content,
            'wrapped': wrap_program_json(json_content)
        })

    # Process in reverse to preserve positions
    modified_content = content
    modifications = 0

    for match in reversed(matches):
        if match['original'] != match['wrapped']:
            modified_content = (
                modified_content[:match['start']] +
                match['wrapped'] +
                modified_content[match['end']:]
            )
            modifications += 1

    with open(file_path, 'w') as f:
        f.write(modified_content)

    print(f"✓ Processed: {file_path}")
    print(f"  - Total programs: {len(matches)}")
    print(f"  - Wrapped: {modifications}")
    print(f"  - Already wrapped: {len(matches) - modifications}")

    return len(matches), modifications

if __name__ == '__main__':
    file_path = sys.argv[1]
    found, wrapped = process_file(file_path)
    sys.exit(0)
PYTHON_SCRIPT

echo ""
echo "========================================================================"
echo "Transformation complete!"
echo "========================================================================"
echo ""
echo "To verify the changes:"
echo "  git diff $file"
echo ""
echo "To restore from backup if needed:"
echo "  cp $backup $file"
echo ""
