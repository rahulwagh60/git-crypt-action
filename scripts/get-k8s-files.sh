#!/bin/bash

# Script to get changed Kubernetes YAML files
# Identifies files that are likely Kubernetes manifests

set -e

echo "=== Getting changed Kubernetes YAML files ==="

# Initialize variables
K8S_FILES=""
K8S_FILES_FOUND="false"

# Get the base and head commits for comparison
if [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
    BASE_SHA="${GITHUB_BASE_REF:-main}"
    HEAD_SHA="$GITHUB_SHA"
    echo "PR mode: comparing origin/$BASE_SHA...$HEAD_SHA"
    
    # Debug: Show what we're comparing
    echo "Base ref: $GITHUB_BASE_REF"
    echo "Head SHA: $GITHUB_SHA"
    echo "Event name: $GITHUB_EVENT_NAME"
    
    # Get changed files in the PR - using the correct syntax for PR comparison
    CHANGED_FILES=$(git diff --name-only "origin/$BASE_SHA...$HEAD_SHA" -- '*.yaml' '*.yml' 2>/dev/null || echo "")
    
    # Alternative method if the above doesn't work
    if [ -z "$CHANGED_FILES" ]; then
        echo "Trying alternative method with merge-base..."
        BASE_COMMIT=$(git merge-base "origin/$BASE_SHA" "$HEAD_SHA")
        CHANGED_FILES=$(git diff --name-only "$BASE_COMMIT...$HEAD_SHA" -- '*.yaml' '*.yml' 2>/dev/null || echo "")
    fi
    
    # Another fallback method
    if [ -z "$CHANGED_FILES" ]; then
        echo "Trying direct comparison with HEAD~1..."
        CHANGED_FILES=$(git diff --name-only HEAD~1...HEAD -- '*.yaml' '*.yml' 2>/dev/null || echo "")
    fi
else
    # For workflow_dispatch, compare with the previous commit
    echo "Manual trigger mode: comparing HEAD~1...HEAD"
    CHANGED_FILES=$(git diff --name-only HEAD~1...HEAD -- '*.yaml' '*.yml' 2>/dev/null || echo "")
fi

# Debug: Show all changed files
echo "Debug: All changed files found:"
if [ -n "$CHANGED_FILES" ]; then
    echo "$CHANGED_FILES"
else
    echo "No YAML files found in git diff"
    
    # Additional debugging - show all changed files (not just YAML)
    echo "Debug: All changed files (any type):"
    if [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
        git diff --name-only "origin/$BASE_SHA...$HEAD_SHA" 2>/dev/null || echo "No files found"
    else
        git diff --name-only HEAD~1...HEAD 2>/dev/null || echo "No files found"
    fi
fi

# Function to check if a file is likely a Kubernetes manifest
is_kubernetes_file() {
    local file="$1"
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        echo "   → File does not exist: $file"
        return 1
    fi
    
    # Exclude files in .github/workflows/ to avoid GitHub Actions workflows
    if echo "$file" | grep -E "^\.github/workflows/" >/dev/null; then
        echo "   → Excluded: $file (in .github/workflows/)"
        return 1
    fi
    
    # Check file path patterns that commonly contain Kubernetes manifests
    if echo "$file" | grep -E "(k8s|kubernetes|manifests|deployment|service|ingress|configmap|secret)" >/dev/null; then
        echo "   → Path-based match: $file"
        return 0
    fi
    
    # Check file content for Kubernetes-specific fields
    # Look for apiVersion and kind at minimum (most reliable indicators)
    if grep -q "apiVersion:" "$file" 2>/dev/null && \
       grep -q "kind:" "$file" 2>/dev/null; then
        echo "   → Content-based match: $file (has apiVersion and kind)"
        return 0
    fi
    
    # Secondary check: look for just apiVersion (for cases like ConfigMaps that might not have spec)
    if grep -q "apiVersion:" "$file" 2>/dev/null; then
        echo "   → Potential Kubernetes file: $file (has apiVersion)"
        return 0
    fi
    
    return 1
}

# Process changed files
if [ -n "$CHANGED_FILES" ]; then
    echo "Checking changed YAML files for Kubernetes manifests..."
    
    for file in $CHANGED_FILES; do
        echo "Checking file: $file"
        if [ -f "$file" ]; then
            if is_kubernetes_file "$file"; then
                K8S_FILES="$K8S_FILES$file\n"
                K8S_FILES_FOUND="true"
                echo "   ✅ Kubernetes manifest detected"
            else
                echo "   ➖ Not a Kubernetes manifest"
            fi
        else
            echo "   ✗ $file (deleted or not found, skipping)"
        fi
    done
    
    # Remove trailing newline
    K8S_FILES=$(echo -e "$K8S_FILES" | sed '/^$/d')
else
    echo "No YAML files changed in this PR/commit"
fi

if [ "$K8S_FILES_FOUND" = "true" ]; then
    echo "Found Kubernetes YAML files:"
    echo "$K8S_FILES"
    
    # Count files
    FILE_COUNT=$(echo "$K8S_FILES" | wc -l)
    echo "Total Kubernetes files to validate: $FILE_COUNT"
else
    echo "No Kubernetes YAML files found in changes"
fi

# Set environment variables for GitHub Actions
echo "K8S_FILES_FOUND=$K8S_FILES_FOUND" >> "$GITHUB_ENV"
echo "K8S_YAML_FILES<<EOF" >> "$GITHUB_ENV"
echo -e "$K8S_FILES" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"

echo "=== Kubernetes files detection complete ==="