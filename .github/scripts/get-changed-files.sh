#!/bin/bash

# Script to get changed YAML files for encryption check
# Sets environment variables for use in GitHub Actions

set -e

echo "=== Getting changed YAML files for encryption check ==="

# Initialize variables
CHANGED_FILES=""
HAS_CHANGED_FILES="false"

# Get the base and head commits for comparison
if [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
    BASE_SHA="$GITHUB_BASE_REF"
    HEAD_SHA="$GITHUB_HEAD_REF"
    echo "PR mode: comparing $BASE_SHA...$HEAD_SHA"
    
    # Get changed files in the PR
    CHANGED_FILES=$(git diff --name-only "origin/$BASE_SHA"..."origin/$HEAD_SHA" -- '*.yaml' '*.yml' 2>/dev/null || echo "")
else
    # For workflow_dispatch, compare with the previous commit
    echo "Manual trigger mode: comparing HEAD~1...HEAD"
    CHANGED_FILES=$(git diff --name-only HEAD~1...HEAD -- '*.yaml' '*.yml' 2>/dev/null || echo "")
fi

# Filter out deleted files (only check added/modified files)
FILTERED_FILES=""
if [ -n "$CHANGED_FILES" ]; then
    echo "Initial changed files found:"
    echo "$CHANGED_FILES"
    
    for file in $CHANGED_FILES; do
        if [ -f "$file" ]; then
            FILTERED_FILES="$FILTERED_FILES$file\n"
            echo "  ✓ $file (exists)"
        else
            echo "  ✗ $file (deleted, skipping)"
        fi
    done
    
    # Remove trailing newline
    FILTERED_FILES=$(echo -e "$FILTERED_FILES" | sed '/^$/d')
fi

if [ -n "$FILTERED_FILES" ]; then
    HAS_CHANGED_FILES="true"
    echo "Final filtered files for encryption check:"
    echo "$FILTERED_FILES"
    
    # Count files
    FILE_COUNT=$(echo "$FILTERED_FILES" | wc -l)
    echo "Total files to check: $FILE_COUNT"
else
    echo "No YAML files changed in this PR/commit"
fi

# Set environment variables for GitHub Actions
echo "HAS_CHANGED_FILES=$HAS_CHANGED_FILES" >> "$GITHUB_ENV"
echo "CHANGED_YAML_FILES<<EOF" >> "$GITHUB_ENV"
echo -e "$FILTERED_FILES" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"

echo "=== Changed files detection complete ==="