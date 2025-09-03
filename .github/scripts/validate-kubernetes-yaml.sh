#!/bin/bash

# Script to validate Kubernetes YAML files using kubeconform
# Validates files against Kubernetes API schema with strict mode and missing schema handling
# Supports git-crypt encrypted files by decrypting them temporarily for validation

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

# Check if git-crypt is available
if ! command -v git-crypt &> /dev/null; then
    echo "⚠️ git-crypt is not available - encrypted files will be handled as regular files"
    GIT_CRYPT_AVAILABLE=false
else
    echo "git-crypt version: $(git-crypt --version)"
    GIT_CRYPT_AVAILABLE=true
fi

# Function to check if a file is encrypted by git-crypt
is_file_encrypted() {
    local file="$1"
    
    # Check if git-crypt is available
    if [ "$GIT_CRYPT_AVAILABLE" = false ]; then
        return 1
    fi
    
    # Check if the file matches any .gitattributes pattern that uses filter=git-crypt
    # First, check if .gitattributes exists
    if [ ! -f ".gitattributes" ]; then
        return 1
    fi
    
    # Get the file's attributes using git check-attr
    local filter_attr
    filter_attr=$(git check-attr -z filter "$file" 2>/dev/null | cut -d' ' -f3 || echo "")
    
    if [ "$filter_attr" = "git-crypt" ]; then
        # Additional check: encrypted files typically contain binary data at the beginning
        # Git-crypt encrypted files start with a specific header
        if [ -f "$file" ] && head -c 10 "$file" 2>/dev/null | grep -q "^.GITCRYPT" 2>/dev/null; then
            return 0
        fi
        
        # Alternative check: if file appears to be binary but should be YAML
        if [ -f "$file" ] && file "$file" | grep -q "data" && ! file "$file" | grep -q "text"; then
            return 0
        fi
    fi
    
    return 1
}

# Function to create a temporary decrypted version of an encrypted file
decrypt_file_temporarily() {
    local encrypted_file="$1"
    local temp_dir="$2"
    
    if [ "$GIT_CRYPT_AVAILABLE" = false ]; then
        echo "  ❌ Cannot decrypt file - git-crypt not available"
        return 1
    fi
    
    # Create a temporary decrypted version
    local temp_file="$temp_dir/$(basename "$encrypted_file")"
    
    # Try to decrypt using git show (this shows the decrypted content)
    if git show "HEAD:$encrypted_file" > "$temp_file" 2>/dev/null; then
        echo "$temp_file"
        return 0
    fi
    
    # Alternative: try using git-crypt unlock if we have access to the key
    # This is more complex and may not work in CI environments
    echo "  ⚠️ Could not decrypt file using git show"
    return 1
}

# Function to validate a single Kubernetes file
validate_k8s_file() {
    local file="$1"
    local temp_output
    local file_to_validate="$file"
    local temp_dir=""
    local decrypted_file=""
    local is_encrypted=false
    
    echo "Validating: $file"
    
    # Check if the file is encrypted
    if is_file_encrypted "$file"; then
        echo "  🔒 File is encrypted with git-crypt, attempting to decrypt for validation..."
        is_encrypted=true
        
        # Create temporary directory for decrypted file
        temp_dir=$(mktemp -d)
        
        # Try to decrypt the file
        if decrypted_file=$(decrypt_file_temporarily "$file" "$temp_dir"); then
            echo "  ✅ File decrypted temporarily for validation"
            file_to_validate="$decrypted_file"
        else
            echo "  ❌ Failed to decrypt file - skipping validation"
            SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
            SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file (failed to decrypt)\n"
            return 0
        fi
    fi
    
    # Create temporary file for kubeconform output
    temp_output=$(mktemp)
    
    # Run kubeconform on the file (or its decrypted version)
    kubeconform_exit_code=0
    kubeconform -summary -verbose -output text -strict -ignore-missing-schemas "$file_to_validate" > "$temp_output" 2>&1 || kubeconform_exit_code=$?
    
    # Debug: Show what kubeconform actually outputs
    echo "  Debug - kubeconform exit code: $kubeconform_exit_code"
    echo "  Debug - kubeconform output:"
    sed 's/^/    DEBUG: /' "$temp_output"
    
    # Check the output content for different scenarios
    if [ $kubeconform_exit_code -eq 0 ]; then
        # Exit code 0 means success, but could be valid or skipped
        # Look for patterns that indicate skipped files
        if grep -q -i -E "(schema not found|skipped|ignored|no schema)" "$temp_output" || \
           grep -q -E "could not find schema" "$temp_output" || \
           grep -q -E "missing schema" "$temp_output"; then
            echo "  ⏭️ Skipped (missing schema)"
            SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
            if [ "$is_encrypted" = true ]; then
                SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file (encrypted, missing schema)\n"
            else
                SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file\n"
            fi
            
            # Show skip details
            echo "  Skip details:"
            sed 's/^/    /' "$temp_output"
        else
            echo "  ✅ Valid"
            VALID_K8S_FILES=$((VALID_K8S_FILES + 1))
            if [ "$is_encrypted" = true ]; then
                VALID_FILES_LIST="$VALID_FILES_LIST$file (encrypted)\n"
            else
                VALID_FILES_LIST="$VALID_FILES_LIST$file\n"
            fi
            
            # Show validation details
            if [ -s "$temp_output" ]; then
                echo "  Validation details:"
                sed 's/^/    /' "$temp_output"
            fi
        fi
    else
        echo "  ❌ Invalid"
        INVALID_K8S_FILES=$((INVALID_K8S_FILES + 1))
        if [ "$is_encrypted" = true ]; then
            INVALID_FILES_LIST="$INVALID_FILES_LIST$file (encrypted)\n"
        else
            INVALID_FILES_LIST="$INVALID_FILES_LIST$file\n"
        fi
        
        # Show validation errors
        echo "  Validation errors:"
        sed 's/^/    /' "$temp_output"
    fi
    
    # Clean up temporary files
    rm -f "$temp_output"
    if [ -n "$temp_dir" ]; then
        rm -rf "$temp_dir"
    fi
}

# Function to validate multi-document YAML files
validate_multi_doc_file() {
    local file="$1"
    local temp_output
    local file_to_validate="$file"
    local temp_dir=""
    local decrypted_file=""
    local is_encrypted=false
    
    echo "Validating file: $file"
    
    # Check if the file is encrypted
    if is_file_encrypted "$file"; then
        echo "  🔒 File is encrypted with git-crypt, attempting to decrypt for validation..."
        is_encrypted=true
        
        # Create temporary directory for decrypted file
        temp_dir=$(mktemp -d)
        
        # Try to decrypt the file
        if decrypted_file=$(decrypt_file_temporarily "$file" "$temp_dir"); then
            echo "  ✅ File decrypted temporarily for validation"
            file_to_validate="$decrypted_file"
        else
            echo "  ❌ Failed to decrypt file - skipping validation"
            SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
            SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file (failed to decrypt)\n"
            return 0
        fi
    fi
    
    # Create temporary file for kubeconform output
    temp_output=$(mktemp)
    
    # kubeconform can handle multi-document YAML files natively
    kubeconform_exit_code=0
    kubeconform -summary -verbose -output text -strict -ignore-missing-schemas "$file_to_validate" > "$temp_output" 2>&1 || kubeconform_exit_code=$?
    
    # Check the output content for different scenarios
    if [ $kubeconform_exit_code -eq 0 ]; then
        # Exit code 0 means success, but could be valid or skipped
        if grep -q -E "(skipped|ignored|missing schema)" "$temp_output"; then
            echo "  ⏭️ Some/all documents in $file were skipped (missing schema)"
            SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
            if [ "$is_encrypted" = true ]; then
                SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file (encrypted, missing schema)\n"
            else
                SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file\n"
            fi
            
            # Show skip details
            echo "  Skip details:"
            sed 's/^/    /' "$temp_output"
        else
            echo "  ✅ All documents in $file are valid"
            VALID_K8S_FILES=$((VALID_K8S_FILES + 1))
            if [ "$is_encrypted" = true ]; then
                VALID_FILES_LIST="$VALID_FILES_LIST$file (encrypted)\n"
            else
                VALID_FILES_LIST="$VALID_FILES_LIST$file\n"
            fi
            
            # Show validation details
            if [ -s "$temp_output" ]; then
                echo "  Validation details:"
                sed 's/^/    /' "$temp_output"
            fi
        fi
    else
        echo "  ❌ Some documents in $file are invalid"
        INVALID_K8S_FILES=$((INVALID_K8S_FILES + 1))
        if [ "$is_encrypted" = true ]; then
            INVALID_FILES_LIST="$INVALID_FILES_LIST$file (encrypted)\n"
        else
            INVALID_FILES_LIST="$INVALID_FILES_LIST$file\n"
        fi
        
        # Show validation errors
        echo "  Validation errors:"
        sed 's/^/    /' "$temp_output"
    fi
    
    # Clean up temporary files
    rm -f "$temp_output"
    if [ -n "$temp_dir" ]; then
        rm -rf "$temp_dir"
    fi
}

# Process Kubernetes files
if [ -n "$K8S_YAML_FILES" ]; then
    echo "Validating Kubernetes YAML files with strict mode, missing schema handling, and git-crypt support..."
    
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
    echo "⏭️ Skipped files (missing schemas or decryption issues):"
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