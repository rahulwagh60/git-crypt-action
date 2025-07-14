#!/bin/bash

# Script to get changed files in PR that match encryption patterns from .gitattributes
# This script reads .gitattributes and finds files that should be encrypted

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to read .gitattributes file and extract patterns that should be encrypted
get_encrypted_patterns() {
    local gitattributes_file=".gitattributes"
    local patterns=()
    
    if [[ -f "$gitattributes_file" ]]; then
        print_info "Reading encryption patterns from .gitattributes"
        
        # Read patterns from .gitattributes that have 'filter=git-crypt' or 'diff=git-crypt'
        while IFS= read -r line; do
            # Skip comments and empty lines
            if [[ "$line" =~ ^#.*$ ]] || [[ -z "$line" ]]; then
                continue
            fi
            
            # Check if line contains git-crypt filter
            if [[ "$line" =~ filter=git-crypt ]] || [[ "$line" =~ diff=git-crypt ]]; then
                # Extract the pattern (first word in the line)
                pattern=$(echo "$line" | awk '{print $1}')
                patterns+=("$pattern")
                print_info "Found encryption pattern: $pattern"
            fi
        done < "$gitattributes_file"
    else
        print_warning ".gitattributes file not found, using default pattern __*.yaml"
        patterns+=("__*.yaml")
    fi
    
    printf '%s\n' "${patterns[@]}"
}

# Function to check if a file matches any of the encrypted patterns
should_be_encrypted() {
    local file="$1"
    local patterns=("${@:2}")
    
    for pattern in "${patterns[@]}"; do
        # Convert glob pattern to regex for matching
        # Replace * with .* and escape dots
        regex_pattern=$(echo "$pattern" | sed 's/\./\\./g' | sed 's/\*/.*/')
        
        # Check if the file matches the pattern
        if [[ "$file" =~ $regex_pattern ]]; then
            return 0
        fi
    done
    
    return 1
}

# Main function to get changed files
main() {
    print_info "Getting changed files that match encryption patterns..."
    
    # Get encryption patterns from .gitattributes
    mapfile -t patterns < <(get_encrypted_patterns)
    
    if [ ${#patterns[@]} -eq 0 ]; then
        print_warning "No encryption patterns found in .gitattributes"
        echo "HAS_CHANGED_FILES=false" >> $GITHUB_ENV
        return 0
    fi
    
    print_info "Found ${#patterns[@]} encryption patterns"
    
    # Get changed files based on event type
    local changed_files=""
    
    if [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
        print_info "Getting files changed in PR..."
        # Get files changed in the PR (added, modified, renamed)
        changed_files=$(git diff --name-only --diff-filter=AMR $GITHUB_BASE_REF..$GITHUB_HEAD_REF 2>/dev/null | grep -E '\.(yaml|yml)$' || true)
    else
        print_info "Getting all YAML files for workflow_dispatch..."
        # For workflow_dispatch, check all YAML files
        changed_files=$(find . -name "*.yaml" -o -name "*.yml" 2>/dev/null | head -50 || true)
    fi
    
    if [ -z "$changed_files" ]; then
        print_info "No YAML files changed"
        echo "HAS_CHANGED_FILES=false" >> $GITHUB_ENV
        return 0
    fi
    
    print_info "Found changed YAML files:"
    echo "$changed_files"
    
    # Filter files that should be encrypted based on patterns
    local files_to_check=""
    local file_count=0
    
    while IFS= read -r file; do
        if [ -n "$file" ] && [ -f "$file" ]; then
            if should_be_encrypted "$file" "${patterns[@]}"; then
                print_info "File matches encryption pattern: $file"
                if [ -z "$files_to_check" ]; then
                    files_to_check="$file"
                else
                    files_to_check="$files_to_check"$'\n'"$file"
                fi
                file_count=$((file_count + 1))
            fi
        fi
    done <<< "$changed_files"
    
    # Export results to GitHub environment
    if [ $file_count -gt 0 ]; then
        echo "HAS_CHANGED_FILES=true" >> $GITHUB_ENV
        echo "CHANGED_FILES<<EOF" >> $GITHUB_ENV
        echo "$files_to_check" >> $GITHUB_ENV
        echo "EOF" >> $GITHUB_ENV
        
        print_info "Found $file_count files that should be encrypted"
    else
        echo "HAS_CHANGED_FILES=false" >> $GITHUB_ENV
        print_info "No files found that match encryption patterns"
    fi
}

# Run main function
main