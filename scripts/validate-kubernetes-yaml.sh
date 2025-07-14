#!/bin/bash

# Script to validate Kubernetes YAML files using kubeval
# Validates files against Kubernetes API schema

set -e

echo "=== Validating Kubernetes YAML files ==="

# Initialize counters
VALID_K8S_FILES=0
INVALID_K8S_FILES=0
TOTAL_K8S_FILES=0
VALID_FILES_LIST=""
INVALID_FILES_LIST=""

# Check if kubeval is available
if ! command -v kubeval &> /dev/null; then
    echo "❌ kubeval is not available"
    exit 1
fi

echo "kubeval version: $(kubeval --version)"

# Function to validate a single Kubernetes file
validate_k8s_file() {
    local file="$1"
    local temp_output
    
    echo "Validating: $file"
    
    # Create temporary file for kubeval output
    temp_output=$(mktemp)
    
    # Run kubeval on the file
    if kubeval "$file" > "$temp_output" 2>&1; then
        echo "  ✅ Valid"
        VALID_K8S_FILES=$((VALID_K8S_FILES + 1))
        VALID_FILES_LIST="$VALID_FILES_LIST$file\n"
        
        # Show validation details
        if [ -s "$temp_output" ]; then
            echo "  Validation details:"
            sed 's/^/    /' "$temp_output"
        fi
    else
        echo "  ❌ Invalid"
        INVALID_K8S_FILES=$((INVALID_K8S_FILES + 1))
        INVALID_FILES_LIST="$INVALID_FILES_LIST$file\n"
        
        # Show validation errors
        echo "  Validation errors:"
        sed 's/^/    /' "$temp_output"
    fi
    
    # Clean up
    rm -f "$temp_output"
}

# Function to validate multi-document YAML files
validate_multi_doc_file() {
    local file="$1"
    local temp_dir
    local doc_count=0
    
    echo "Checking if $file contains multiple documents..."
    
    # Check if file contains multiple YAML documents (separated by ---)
    if grep -q "^---" "$file"; then
        echo "  Multi-document YAML detected, splitting for validation"
        
        # Create temporary directory for split files
        temp_dir=$(mktemp -d)
        
        # Split the file into individual documents
        awk '
        BEGIN { doc=0; filename="'$temp_dir'/doc-" doc ".yaml" }
        /^---/ { 
            if (doc > 0) close(filename)
            doc++; filename="'$temp_dir'/doc-" doc ".yaml"
            next
        }
        { print > filename }
        END { close(filename) }
        ' "$file"
        
        # Validate each document
        local valid_docs=0
        local invalid_docs=0
        
        for doc_file in "$temp_dir"/doc-*.yaml; do
            if [ -f "$doc_file" ] && [ -s "$doc_file" ]; then
                doc_count=$((doc_count + 1))
                echo "  Validating document $doc_count from $file"
                
                if kubeval "$doc_file" >/dev/null 2>&1; then
                    valid_docs=$((valid_docs + 1))
                    echo "    ✅ Document $doc_count: Valid"
                else
                    invalid_docs=$((invalid_docs + 1))
                    echo "    ❌ Document $doc_count: Invalid"
                    kubeval "$doc_file" 2>&1 | sed 's/^/      /'
                fi
            fi
        done
        
        # Clean up temporary files
        rm -rf "$temp_dir"
        
        # Update counters based on overall file validation
        if [ "$invalid_docs" -eq 0 ] && [ "$valid_docs" -gt 0 ]; then
            echo "  ✅ All documents in $file are valid"
            VALID_K8S_FILES=$((VALID_K8S_FILES + 1))
            VALID_FILES_LIST="$VALID_FILES_LIST$file\n"
        else
            echo "  ❌ Some documents in $file are invalid"
            INVALID_K8S_FILES=$((INVALID_K8S_FILES + 1))
            INVALID_FILES_LIST="$INVALID_FILES_LIST$file\n"
        fi
    else
        # Single document file
        validate_k8s_file "$file"
    fi
}

# Process Kubernetes files
if [ -n "$K8S_YAML_FILES" ]; then
    echo "Validating Kubernetes YAML files..."
    
    while IFS= read -r file; do
        if [ -z "$file" ]; then
            continue
        fi
        
        if [ -f "$file" ]; then
            TOTAL_K8S_FILES=$((TOTAL_K8S_FILES + 1))
            validate_multi_doc_file "$file"
        else
            echo "⚠️ File not found: $file"
        fi
    done <<< "$K8S_YAML_FILES"
else
    echo "No Kubernetes YAML files to validate"
fi

# Remove trailing newlines
VALID_FILES_LIST=$(echo -e "$VALID_FILES_LIST" | sed '/^$/d')
INVALID_FILES_LIST=$(echo -e "$INVALID_FILES_LIST" | sed '/^$/d')

# Set environment variables for GitHub Actions
echo "TOTAL_K8S_FILES=$TOTAL_K8S_FILES" >> "$GITHUB_ENV"
echo "VALID_K8S_FILES=$VALID_K8S_FILES" >> "$GITHUB_ENV"
echo "INVALID_K8S_FILES=$INVALID_K8S_FILES" >> "$GITHUB_ENV"
echo "VALID_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$VALID_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
echo "INVALID_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$INVALID_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"

echo "=== Kubernetes validation summary ==="
echo "Total files validated: $TOTAL_K8S_FILES"
echo "Valid files: $VALID_K8S_FILES"
echo "Invalid files: $INVALID_K8S_FILES"

if [ "$INVALID_K8S_FILES" -gt 0 ]; then
    echo "❌ FAILED: Found invalid Kubernetes YAML files"
    echo "Invalid files:"
    echo -e "$INVALID_FILES_LIST"
    exit 1
else
    echo "✅ PASSED: All Kubernetes YAML files are valid"
    exit 0
fi