#!/bin/bash

# Script to check if YAML files are encrypted according to .gitattributes patterns
# Uses git-crypt to determine encryption status

echo "running check encryption script"
set -e

echo "=== Checking YAML file encryption status ==="

# Initialize counters
ENCRYPTED_COUNT=0
UNENCRYPTED_COUNT=0
ENCRYPTED_FILES=""
UNENCRYPTED_FILES=""

# Check if .gitattributes exists
if [ ! -f ".gitattributes" ]; then
    echo "⚠️ No .gitattributes file found - assuming no encryption requirements"
    echo "ENCRYPTED_COUNT=0" >> "$GITHUB_ENV"
    echo "UNENCRYPTED_COUNT=0" >> "$GITHUB_ENV"
    echo "ENCRYPTED_FILES=" >> "$GITHUB_ENV"
    echo "UNENCRYPTED_FILES=" >> "$GITHUB_ENV"
    exit 0
fi

echo "Found .gitattributes file, checking encryption patterns..."

# Function to check if a file should be encrypted based on .gitattributes
should_be_encrypted() {
    local file="$1"
    
    # Check if file matches any git-crypt patterns in .gitattributes
    # Look for lines with "filter=git-crypt" or "diff=git-crypt"
    while IFS= read -r line; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
            continue
        fi
        
        # Check if line contains git-crypt filter
        if [[ "$line" =~ filter=git-crypt ]] || [[ "$line" =~ diff=git-crypt ]]; then
            # Extract the pattern (first word/field)
            pattern=$(echo "$line" | awk '{print $1}')
            
            # Convert gitattributes pattern to shell glob pattern
            # Basic conversion - more complex patterns might need additional logic
            shell_pattern="$pattern"
            
            # Check if file matches pattern
            if [[ "$file" == $shell_pattern ]]; then
                return 0  # Should be encrypted
            fi
        fi
    done < .gitattributes
    
    return 1  # Should not be encrypted
}

# # Function to check if a file is actually encrypted
# is_file_encrypted() {
#     local file="$1"
    
#     # Check if git-crypt is available
#     if ! command -v git-crypt &> /dev/null; then
#         echo "⚠️ git-crypt not available, checking file content manually"
        
#         # Basic check: encrypted files typically have binary content or specific markers
#         # git-crypt encrypted files start with specific bytes
#         if file "$file" | grep -q "data" || head -c 10 "$file" | grep -q $'\x00GITCRYPT' 2>/dev/null; then
#             return 0  # Likely encrypted
#         else
#             # Check if file looks like readable YAML
#             if head -n 5 "$file" | grep -E "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*:" &>/dev/null; then
#                 return 1  # Looks like plain text YAML
#             fi
#         fi
        
#         return 0  # Default to encrypted if uncertain
#     fi
    
#     # Use git-crypt to check encryption status
#     # git-crypt status returns 0 if file is encrypted, 1 if not
#     if git-crypt status "$file" 2>/dev/null | grep -q "encrypted"; then
#         return 0  # Encrypted
#     else
#         return 1  # Not encrypted
#     fi
# }

# Function to check if a file is actually encrypted
is_file_encrypted() {
    local file="$1"

    # Check if file type is "data" (typically indicates binary/encrypted content)
    if file "$file" | grep -q "data"; then
        return 0  # Encrypted
    else
        return 1  # Not encrypted
    fi

    # # Check if file type is "data" (commonly indicates binary/encrypted content)
    # if file "$file" | grep -q "data"; then
    #     return 0  # Encrypted
    # fi

    # # Check for specific git-crypt marker bytes
    # if head -c 10 "$file" 2>/dev/null | grep -q $'\x00GITCRYPT'; then
    #     return 0  # Encrypted
    # fi

    # # Check if file looks like plain text YAML
    # if head -n 5 "$file" | grep -E "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*:" &>/dev/null; then
    #     return 1  # Not encrypted (human-readable YAML)
    # fi

    # If unsure, default to encrypted
    # return 1
}


# Process each changed file
if [ -n "$CHANGED_YAML_FILES" ]; then
    echo "Checking encryption status of changed YAML files..."
    
    while IFS= read -r file; do
        if [ -z "$file" ]; then
            continue
        fi
        
        echo "Checking file: $file"
        
        # Check if file should be encrypted according to .gitattributes
        if should_be_encrypted "$file"; then
            echo "  → File should be encrypted (matches .gitattributes pattern)"
            
            # Check if file is actually encrypted
            if is_file_encrypted "$file"; then
                echo "  ✅ File is encrypted"
                ENCRYPTED_COUNT=$((ENCRYPTED_COUNT + 1))
                ENCRYPTED_FILES="$ENCRYPTED_FILES$file\n"
            else
                echo "  ❌ File is NOT encrypted but should be"
                UNENCRYPTED_COUNT=$((UNENCRYPTED_COUNT + 1))
                UNENCRYPTED_FILES="$UNENCRYPTED_FILES$file\n"
            fi
        else
            echo "  ℹ️ File does not need encryption (no matching .gitattributes pattern)"
        fi
    done <<< "$CHANGED_YAML_FILES"
else
    echo "No changed YAML files to check"
fi

# Remove trailing newlines
ENCRYPTED_FILES=$(echo -e "$ENCRYPTED_FILES" | sed '/^$/d')
UNENCRYPTED_FILES=$(echo -e "$UNENCRYPTED_FILES" | sed '/^$/d')

# Set environment variables for GitHub Actions
echo "ENCRYPTED_COUNT=$ENCRYPTED_COUNT" >> "$GITHUB_ENV"
echo "UNENCRYPTED_COUNT=$UNENCRYPTED_COUNT" >> "$GITHUB_ENV"
echo "ENCRYPTED_FILES<<EOF" >> "$GITHUB_ENV"
echo -e "$ENCRYPTED_FILES" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
echo "UNENCRYPTED_FILES<<EOF" >> "$GITHUB_ENV"
echo -e "$UNENCRYPTED_FILES" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"

echo "=== Encryption check summary ==="
echo "Encrypted files: $ENCRYPTED_COUNT"
echo "Unencrypted files: $UNENCRYPTED_COUNT"

if [ "$UNENCRYPTED_COUNT" -gt 0 ]; then
    echo "❌ FAILED: Found unencrypted files that should be encrypted"
    echo "Unencrypted files:"
    echo -e "$UNENCRYPTED_FILES"
    exit 1
else
    echo "✅ PASSED: All required files are properly encrypted"
    exit 0
fi