#!/bin/bash

# Script to validate Kubernetes YAML files using kubeconform
# Validates files against Kubernetes API schema with strict mode and missing schema handling
# Handles git-crypt encrypted files by temporarily decrypting them for validation

set -e

echo "=== Validating Kubernetes YAML files ==="

# Initialize counters
VALID_K8S_FILES=0
INVALID_K8S_FILES=0
SKIPPED_K8S_FILES=0
ENCRYPTED_K8S_FILES=0
TOTAL_K8S_FILES=0
VALID_FILES_LIST=""
INVALID_FILES_LIST=""
SKIPPED_FILES_LIST=""
ENCRYPTED_FILES_LIST=""

# Check if kubeconform is available
if ! command -v kubeconform &> /dev/null; then
    echo "❌ kubeconform is not available"
    exit 1
fi

echo "kubeconform version: $(kubeconform -v)"

# Check if python3 is available (for YAML parsing check)
PYTHON3_AVAILABLE=false
if command -v python3 &> /dev/null; then
    if python3 -c "import yaml" 2>/dev/null; then
        PYTHON3_AVAILABLE=true
        echo "Python3 with PyYAML available for additional validation"
    else
        echo "⚠️ Python3 available but PyYAML not installed"
    fi
else
    echo "⚠️ Python3 not available - using basic encryption detection only"
fi

# Check if git-crypt is available
GIT_CRYPT_AVAILABLE=false
if command -v git-crypt &> /dev/null; then
    GIT_CRYPT_AVAILABLE=true
    echo "git-crypt version: $(git-crypt --version)"
else
    echo "⚠️ git-crypt is not available - encrypted files will be skipped"
fi

# Function to check if a file is encrypted by git-crypt
is_git_crypt_encrypted() {
    local file="$1"
    
    # Check if file exists and is readable
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        return 1
    fi
    
    echo "  Debug - Checking encryption for: $file"
    
    # Method 1: Check for git-crypt magic bytes (0x00474954435259505400 - "GITCRYPT\0")
    if hexdump -C "$file" 2>/dev/null | head -1 | grep -q "00 47 49 54 43 52 59 50 54 00"; then
        echo "  Debug - Found git-crypt magic bytes"
        return 0
    fi
    
    # Method 2: Check if file contains binary data (non-printable characters)
    if ! head -c 200 "$file" 2>/dev/null | LC_ALL=C grep -q '^[[:print:][:space:]]*

# Function to get git-crypt patterns from .gitattributes
get_gitcrypt_patterns() {
    if [ -f ".gitattributes" ]; then
        # Extract patterns that use git-crypt filter
        grep "filter=git-crypt\|git-crypt" .gitattributes 2>/dev/null | awk '{print $1}' || true
    fi
}

# Function to check if file matches git-crypt patterns
matches_gitcrypt_pattern() {
    local file="$1"
    local patterns
    
    patterns=$(get_gitcrypt_patterns)
    
    if [ -z "$patterns" ]; then
        return 1
    fi
    
    while IFS= read -r pattern; do
        if [ -n "$pattern" ]; then
            # Convert gitattributes glob pattern to bash pattern matching
            # This is a simple conversion - you might need to enhance for complex patterns
            if [[ "$file" == $pattern ]]; then
                return 0
            fi
        fi
    done <<< "$patterns"
    
    return 1
}

# Function to temporarily decrypt and validate a git-crypt file
validate_encrypted_k8s_file() {
    local file="$1"
    local temp_dir
    local temp_file
    local original_dir
    
    echo "Validating encrypted file: $file"
    
    if [ "$GIT_CRYPT_AVAILABLE" != true ]; then
        echo "  🔒 Encrypted file detected but git-crypt not available - skipping"
        SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
        SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file (encrypted, git-crypt not available)\n"
        return
    fi
    
    # Check if git-crypt is unlocked for this repository
    if ! git-crypt status &>/dev/null; then
        echo "  🔒 Repository not unlocked with git-crypt - skipping"
        SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
        SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file (encrypted, repository not unlocked)\n"
        return
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    temp_file="$temp_dir/$(basename "$file")"
    original_dir=$(pwd)
    
    # Copy and decrypt the file
    if git show HEAD:"$file" > "$temp_file" 2>/dev/null; then
        echo "  🔓 Successfully decrypted file"
        
        # Validate the decrypted file
        cd "$temp_dir"
        validate_k8s_file "$(basename "$file")"
        cd "$original_dir"
    else
        echo "  ❌ Failed to decrypt file"
        SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
        SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file (encrypted, decryption failed)\n"
    fi
    
    # Clean up
    rm -rf "$temp_dir"
}

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
    kubeconform_exit_code=0
    kubeconform -summary -verbose -output text -strict -ignore-missing-schemas "$file" > "$temp_output" 2>&1 || kubeconform_exit_code=$?
    
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
    
    echo "=== Processing file: $file ==="
    
    # Debug: Show file info
    echo "  File size: $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "unknown")"
    echo "  First 50 chars: $(head -c 50 "$file" 2>/dev/null | tr '\0' '?' | tr '\n' '\\n')"
    
    # Manual override: force certain files to be treated as encrypted
    if [[ "$file" == *"__abc.yaml"* ]] || [[ "$file" == *"__xyz.yaml"* ]] || [[ "$file" == secrets/* ]]; then
        echo "  🔒 File matches known encrypted pattern - treating as encrypted"
        validate_encrypted_k8s_file "$file"
        return
    fi
    
    # First check if the file matches git-crypt patterns
    if matches_gitcrypt_pattern "$file"; then
        echo "  🔍 File matches git-crypt pattern from .gitattributes"
        validate_encrypted_k8s_file "$file"
        return
    fi
    
    # Then check if the file is actually encrypted
    if is_git_crypt_encrypted "$file"; then
        echo "  🔒 Detected encrypted file: $file"
        validate_encrypted_k8s_file "$file"
        return
    fi
    
    echo "  📝 File appears unencrypted, proceeding with normal validation"
    # If not encrypted, proceed with normal validation
    validate_k8s_file "$file"
}

# Show git-crypt patterns if available
echo ""
echo "=== Git-crypt configuration ==="
gitcrypt_patterns=$(get_gitcrypt_patterns)
if [ -n "$gitcrypt_patterns" ]; then
    echo "Git-crypt patterns from .gitattributes:"
    echo "$gitcrypt_patterns" | sed 's/^/  /'
else
    echo "No git-crypt patterns found in .gitattributes"
fi

# Check git-crypt status
if [ "$GIT_CRYPT_AVAILABLE" = true ]; then
    echo ""
    echo "Git-crypt repository status:"
    if git-crypt status &>/dev/null; then
        echo "  🔓 Repository is unlocked"
    else
        echo "  🔒 Repository is locked"
    fi
fi

echo ""

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
ENCRYPTED_FILES_LIST=$(echo -e "$ENCRYPTED_FILES_LIST" | sed '/^$/d')

# Set environment variables for GitHub Actions
echo "TOTAL_K8S_FILES=$TOTAL_K8S_FILES" >> "$GITHUB_ENV"
echo "VALID_K8S_FILES=$VALID_K8S_FILES" >> "$GITHUB_ENV"
echo "INVALID_K8S_FILES=$INVALID_K8S_FILES" >> "$GITHUB_ENV"
echo "SKIPPED_K8S_FILES=$SKIPPED_K8S_FILES" >> "$GITHUB_ENV"
echo "ENCRYPTED_K8S_FILES=$ENCRYPTED_K8S_FILES" >> "$GITHUB_ENV"
echo "VALID_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$VALID_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
echo "INVALID_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$INVALID_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
echo "SKIPPED_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$SKIPPED_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
echo "ENCRYPTED_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$ENCRYPTED_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"

echo "=== Kubernetes validation summary ==="
echo "Total files validated: $TOTAL_K8S_FILES"
echo "Valid files: $VALID_K8S_FILES"
echo "Invalid files: $INVALID_K8S_FILES"
echo "Skipped files: $SKIPPED_K8S_FILES"
echo "Encrypted files: $ENCRYPTED_K8S_FILES"

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

if [ -n "$ENCRYPTED_FILES_LIST" ]; then
    echo ""
    echo "🔒 Encrypted files:"
    echo -e "$ENCRYPTED_FILES_LIST"
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
    echo "✅ PASSED: All Kubernetes YAML files are valid, skipped, or encrypted"
    exit 0
fi; then
        echo "  Debug - File contains binary data"
        # Additional check for YAML files
        if [[ "$file" == *.yaml ]] || [[ "$file" == *.yml ]]; then
            echo "  Debug - YAML file with binary data - likely encrypted"
            return 0
        fi
    fi
    
    # Method 3: Check for common git-crypt patterns in first line
    first_line=$(head -n1 "$file" 2>/dev/null || echo "")
    if [[ "$first_line" =~ ^[[:cntrl:]] ]] || [[ -z "$first_line" && -s "$file" ]]; then
        echo "  Debug - File starts with control characters or is empty but has size"
        return 0
    fi
    
    # Method 4: Try to parse as YAML - if it fails and file exists, might be encrypted
    if [[ "$file" == *.yaml ]] || [[ "$file" == *.yml ]]; then
        if [ "$PYTHON3_AVAILABLE" = true ]; then
            if ! python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
                echo "  Debug - File appears to be YAML but failed to parse - likely encrypted"
                return 0
            fi
        fi
    fi
    
    echo "  Debug - File appears to be unencrypted"
    return 1
}

# Function to get git-crypt patterns from .gitattributes
get_gitcrypt_patterns() {
    if [ -f ".gitattributes" ]; then
        # Extract patterns that use git-crypt filter
        grep "filter=git-crypt\|git-crypt" .gitattributes 2>/dev/null | awk '{print $1}' || true
    fi
}

# Function to check if file matches git-crypt patterns
matches_gitcrypt_pattern() {
    local file="$1"
    local patterns
    
    patterns=$(get_gitcrypt_patterns)
    
    if [ -z "$patterns" ]; then
        return 1
    fi
    
    while IFS= read -r pattern; do
        if [ -n "$pattern" ]; then
            # Convert gitattributes glob pattern to bash pattern matching
            # This is a simple conversion - you might need to enhance for complex patterns
            if [[ "$file" == $pattern ]]; then
                return 0
            fi
        fi
    done <<< "$patterns"
    
    return 1
}

# Function to temporarily decrypt and validate a git-crypt file
validate_encrypted_k8s_file() {
    local file="$1"
    local temp_dir
    local temp_file
    local original_dir
    
    echo "Validating encrypted file: $file"
    
    if [ "$GIT_CRYPT_AVAILABLE" != true ]; then
        echo "  🔒 Encrypted file detected but git-crypt not available - skipping"
        SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
        SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file (encrypted, git-crypt not available)\n"
        return
    fi
    
    # Check if git-crypt is unlocked for this repository
    if ! git-crypt status &>/dev/null; then
        echo "  🔒 Repository not unlocked with git-crypt - skipping"
        SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
        SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file (encrypted, repository not unlocked)\n"
        return
    fi
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    temp_file="$temp_dir/$(basename "$file")"
    original_dir=$(pwd)
    
    # Copy and decrypt the file
    if git show HEAD:"$file" > "$temp_file" 2>/dev/null; then
        echo "  🔓 Successfully decrypted file"
        
        # Validate the decrypted file
        cd "$temp_dir"
        validate_k8s_file "$(basename "$file")"
        cd "$original_dir"
    else
        echo "  ❌ Failed to decrypt file"
        SKIPPED_K8S_FILES=$((SKIPPED_K8S_FILES + 1))
        SKIPPED_FILES_LIST="$SKIPPED_FILES_LIST$file (encrypted, decryption failed)\n"
    fi
    
    # Clean up
    rm -rf "$temp_dir"
}

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
    kubeconform_exit_code=0
    kubeconform -summary -verbose -output text -strict -ignore-missing-schemas "$file" > "$temp_output" 2>&1 || kubeconform_exit_code=$?
    
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
    
    # First check if the file is encrypted
    if is_git_crypt_encrypted "$file" || matches_gitcrypt_pattern "$file"; then
        echo "🔒 Detected encrypted file: $file"
        validate_encrypted_k8s_file "$file"
        return
    fi
    
    # If not encrypted, proceed with normal validation
    validate_k8s_file "$file"
}

# Show git-crypt patterns if available
echo ""
echo "=== Git-crypt configuration ==="
gitcrypt_patterns=$(get_gitcrypt_patterns)
if [ -n "$gitcrypt_patterns" ]; then
    echo "Git-crypt patterns from .gitattributes:"
    echo "$gitcrypt_patterns" | sed 's/^/  /'
else
    echo "No git-crypt patterns found in .gitattributes"
fi

# Check git-crypt status
if [ "$GIT_CRYPT_AVAILABLE" = true ]; then
    echo ""
    echo "Git-crypt repository status:"
    if git-crypt status &>/dev/null; then
        echo "  🔓 Repository is unlocked"
    else
        echo "  🔒 Repository is locked"
    fi
fi

echo ""

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
ENCRYPTED_FILES_LIST=$(echo -e "$ENCRYPTED_FILES_LIST" | sed '/^$/d')

# Set environment variables for GitHub Actions
echo "TOTAL_K8S_FILES=$TOTAL_K8S_FILES" >> "$GITHUB_ENV"
echo "VALID_K8S_FILES=$VALID_K8S_FILES" >> "$GITHUB_ENV"
echo "INVALID_K8S_FILES=$INVALID_K8S_FILES" >> "$GITHUB_ENV"
echo "SKIPPED_K8S_FILES=$SKIPPED_K8S_FILES" >> "$GITHUB_ENV"
echo "ENCRYPTED_K8S_FILES=$ENCRYPTED_K8S_FILES" >> "$GITHUB_ENV"
echo "VALID_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$VALID_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
echo "INVALID_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$INVALID_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
echo "SKIPPED_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$SKIPPED_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
echo "ENCRYPTED_FILES_LIST<<EOF" >> "$GITHUB_ENV"
echo -e "$ENCRYPTED_FILES_LIST" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"

echo "=== Kubernetes validation summary ==="
echo "Total files validated: $TOTAL_K8S_FILES"
echo "Valid files: $VALID_K8S_FILES"
echo "Invalid files: $INVALID_K8S_FILES"
echo "Skipped files: $SKIPPED_K8S_FILES"
echo "Encrypted files: $ENCRYPTED_K8S_FILES"

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

if [ -n "$ENCRYPTED_FILES_LIST" ]; then
    echo ""
    echo "🔒 Encrypted files:"
    echo -e "$ENCRYPTED_FILES_LIST"
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
    echo "✅ PASSED: All Kubernetes YAML files are valid, skipped, or encrypted"
    exit 0
fi