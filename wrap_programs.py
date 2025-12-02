#!/usr/bin/env python3
"""
Script to wrap program definitions with {"program": ...} wrapper format.
Handles both single-line and multi-line programs with nested braces and parentheses.
"""

import re
import sys
from pathlib import Path


def find_matching_paren(text, start_pos):
    """
    Find the closing parenthesis that matches the opening one at start_pos.
    Handles nested parentheses correctly.

    Args:
        text: The full text to search
        start_pos: Position of the opening '('

    Returns:
        Position of the matching ')' or -1 if not found
    """
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
    """
    Wrap JSON content with {"program": ...} if it's not already wrapped.

    Args:
        json_content: The JSON string content (without ~s() wrapper)

    Returns:
        Wrapped JSON content
    """
    # Strip leading/trailing whitespace to check the content
    stripped = json_content.strip()

    # Check if already wrapped with {"program": ...}
    if stripped.startswith('{"program":') or stripped.startswith('{ "program":'):
        return json_content

    # Wrap the content
    return '{"program": ' + json_content + '}'


def process_file(file_path):
    """
    Process a test file and wrap all program definitions.

    Args:
        file_path: Path to the test file

    Returns:
        Number of programs wrapped
    """
    path = Path(file_path)

    if not path.exists():
        print(f"ERROR: File not found: {file_path}")
        return 0

    content = path.read_text()

    # Pattern to find: program = ~s(
    pattern = r'program\s*=\s*~s\('

    matches = []
    for match in re.finditer(pattern, content):
        start = match.end() - 1  # Position of the '(' after ~s
        end = find_matching_paren(content, start)

        if end == -1:
            print(f"WARNING: Could not find matching ')' for program at position {start}")
            continue

        # Extract the JSON content (between the parentheses)
        json_content = content[start + 1:end]

        matches.append({
            'start': start + 1,
            'end': end,
            'original': json_content,
            'wrapped': wrap_program_json(json_content)
        })

    # Process matches in reverse order to preserve positions
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

    # Write back if modifications were made
    if modifications > 0:
        path.write_text(modified_content)
        print(f"✓ {file_path}")
        print(f"  - Found: {len(matches)} program definitions")
        print(f"  - Wrapped: {modifications} programs")
    else:
        print(f"✓ {file_path}")
        print(f"  - Found: {len(matches)} program definitions")
        print(f"  - Already wrapped: all programs already have wrapper")

    return modifications


def main():
    """Main entry point."""
    base_dir = Path('/home/runner/work/ptc_runner/ptc_runner')

    files = [
        base_dir / 'test' / 'ptc_runner_test.exs',
        base_dir / 'test' / 'ptc_runner' / 'e2e_test.exs'
    ]

    print("=" * 70)
    print("Wrapping program definitions with {\"program\": ...}")
    print("=" * 70)
    print()

    total_wrapped = 0

    for file_path in files:
        wrapped = process_file(str(file_path))
        total_wrapped += wrapped
        print()

    print("=" * 70)
    print(f"TOTAL: Wrapped {total_wrapped} program definitions")
    print("=" * 70)

    return 0 if total_wrapped >= 0 else 1


if __name__ == '__main__':
    sys.exit(main())
