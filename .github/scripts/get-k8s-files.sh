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

# Function to check if a file is likely a Kubernetes manifest
is_kubernetes_file() {
    local file="$1"
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        return 1
    fi
    
    # Exclude files in .github/workflows/ to avoid GitHub Actions workflows
    if echo "$file" | grep -E "^\.github/workflows/" >/dev/null; then
        echo "  → Excluded: $file (in .github/workflows/)"
        return 1
    fi
    
    # Check file path patterns that commonly contain Kubernetes manifests
    if echo "$file" | grep -E "(k8s|kubernetes|manifests|deployment|service|ingress|configmap|secret)" >/dev/null; then
        echo "  → Path-based match: $file"
        return 0
    fi
    
    # Check file content for ALL Kubernetes-specific fields
    if grep -q "apiVersion:" "$file" 2>/dev/null && \
       grep -q "kind:" "$file" 2>/dev/null && \
       grep -q "metadata:" "$file" 2>/dev/null && \
       grep -q "spec:" "$file" 2>/dev/null; then
        echo "  → Content-based match: $file"
        return 0
    fi
    
    return 1
}

# Process changed files
if [ -n "$CHANGED_FILES" ]; then
    echo "Checking changed YAML files for Kubernetes manifests..."
    
    for file in $CHANGED_FILES; do
        if [ -f "$file" ]; then
            echo "Checking file: $file"
            
            if is_kubernetes_file "$file"; then
                K8S_FILES="$K8S_FILES$file\n"
                K8S_FILES_FOUND="true"
                echo "  ✅ Kubernetes manifest detected"
            else
                echo "  ➖ Not a Kubernetes manifest"
            fi
        else
            echo "  ✗ $file (deleted, skipping)"
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