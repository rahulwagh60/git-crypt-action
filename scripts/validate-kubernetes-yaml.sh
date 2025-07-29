#!/bin/bash

# Script to validate Kubernetes YAML files using kubeconform
# Validates files against Kubernetes API schema with strict mode and missing schema handling

set -e

echo "=== Validating Kubernetes YAML files ==="

# Initialize counters
VALID_K8S_FILES=0
INVALID_K8S_FILES=0
SKIPPED_K8S_FILES=0
TOTAL_K8S_FILES=0
VALID_FILES_LIST=""
INVALID_FILES_LIST=""
SKIPPED_FILES_LIST=""

# Check if kubeconform is available
if ! command -v kubeconform &> /dev/null; then
    echo "❌ kubeconform is not available"
    exit 1
fi

echo "kubeconform version: $(kubeconform -v)"

# Function to validate a single Kubernetes file
validate_k8s_file() {
    local file="$1"
    local temp_output
    
    echo "Validating: $file"
    
    # Create temporary file for kubeconform output
    temp_output=$(mktemp)
    
    # Run kubeconform on the file with verbose output and new flags
    # -summary: show summary of validation results
    # -verbose: show detailed validation information
    # -output: use text output format
    # -strict: disallow additional properties not in schema
    # -ignore-missing-schemas: skip validation for resources with missing schemas
    if kubeconform -summary -verbose -output text -strict -ignore-missing-schemas "$file" > "$temp_output" 2>&1; then
        # Check if file was skipped due to missing schema
        if grep -q "skipped" "$temp_output" || grep -q "ignored" "$temp_output"; then
            echo "  ⏭️ Skipped (missing schema)"
            SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
            SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file\n"
            
            # Show skip details
            echo "  Skip details:"
            sed 's/^/    /' "$temp_output"
        else
            echo "  ✅ Valid"
            VALID_K8S_FILES=$((VALID_K8S_FILES + 1))
            VALID_FILES_LIST="$VALID_FILES_LIST$file\n"
            
            # Show validation details
            if [ -s "$temp_output" ]; then
                echo "  Validation details:"
                sed 's/^/    /' "$temp_output"
            fi
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
    local temp_output
    
    echo "Validating file: $file"
    
    # Create temporary file for kubeconform output
    temp_output=$(mktemp)
    
    # kubeconform can handle multi-document YAML files natively
    # -summary: show summary of validation results
    # -verbose: show detailed validation information
    # -output: use text output format
    # -strict: disallow additional properties not in schema
    # -ignore-missing-schemas: skip validation for resources with missing schemas
    if kubeconform -summary -verbose -output text -strict -ignore-missing-schemas "$file" > "$temp_output" 2>&1; then
        # Check if file was skipped due to missing schema
        if grep -q "skipped" "$temp_output" || grep -q "ignored" "$temp_output"; then
            echo "  ⏭️ Some/all documents in $file were skipped (missing schema)"
            SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
            SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file\n"
            
            # Show skip details
            echo "  Skip details:"
            sed 's/^/    /' "$temp_output"
        else
            echo "  ✅ All documents in $file are valid"
            VALID_K8S_FILES=$((VALID_K8S_FILES + 1))
            VALID_FILES_LIST="$VALID_FILES_LIST$file\n"
            
            # Show validation details
            if [ -s "$temp_output" ]; then
                echo "  Validation details:"
                sed 's/^/    /' "$temp_output"
            fi
        fi
    else
        echo "  ❌ Some documents in $file are invalid"
        INVALID_K8S_FILES=$((INVALID_K8S_FILES + 1))
        INVALID_FILES_LIST="$INVALID_FILES_LIST$file\n"
        
        # Show validation errors
        echo "  Validation errors:"
        sed 's/^/    /' "$temp_output"
    fi
    
    # Clean up
    rm -f "$temp_output"
}

# Process Kubernetes files
if [ -n "$K8S_YAML_FILES" ]; then
    echo "Validating Kubernetes YAML files with strict mode and missing schema handling..."
    
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
SKIPPED_FILES_LIST=$(echo -e "$SKIPPED_FILES_LIST" | sed '/^$/d')

# Set environment variables for GitHub Actions
echo "TOTAL_K8S_FILES=$TOTAL_K8S_FILES" >> "$GITHUB_ENV"
echo "VALID_K8S_FILES=$VALID_K8S_FILES" >> "$GITHUB_ENV"
echo "INVALID_K8S_FILES=$INVALID_K8S_FILES" >> "$GITHUB_ENV"
echo "SKIPPED_K8S_FILES=$SKIPPED_K8S_FILES" >> "$GITHUB_ENV"
echo "VALID_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$VALID_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
echo "INVALID_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$INVALID_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
echo "SKIPPED_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$SKIPPED_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"

echo "=== Kubernetes validation summary ==="
echo "Total files validated: $TOTAL_K8S_FILES"
echo "Valid files: $VALID_K8S_FILES"
echo "Invalid files: $INVALID_K8S_FILES"
echo "Skipped files: $SKIPPED_K8S_FILES"

# Show file lists if they exist
if [ -n "$VALID_FILES_LIST" ]; then
    echo ""
    echo "✅ Valid files:"
    echo -e "$VALID_FILES_LIST"
fi

if [ -n "$SKIPPED_FILES_LIST" ]; then
    echo ""
    echo "⏭️ Skipped files (missing schemas):"
    echo -e "$SKIPPED_FILES_LIST"
fi

if [ -n "$INVALID_FILES_LIST" ]; then
    echo ""
    echo "❌ Invalid files:"
    echo -e "$INVALID_FILES_LIST"
fi

if [ "$INVALID_K8S_FILES" -gt 0 ]; then
    echo "❌ FAILED: Found invalid Kubernetes YAML files"
    exit 1
else
    echo "✅ PASSED: All Kubernetes YAML files are valid or skipped"
    exit 0
fi