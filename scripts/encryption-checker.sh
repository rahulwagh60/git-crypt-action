#!/bin/bash

# encryption-checker.sh - Comprehensive YAML file encryption validator
# Usage: ./encryption-checker.sh <file1> <file2> ... or ./encryption-checker.sh -f <file_list>

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
TOTAL_FILES=0
ENCRYPTED_FILES=0
UNENCRYPTED_FILES=0
SUSPICIOUS_FILES=0
UNENCRYPTED_LIST=()
SUSPICIOUS_LIST=()

# Function to print colored output
print_status() {
    local status="$1"
    local message="$2"
    case "$status" in
        "SUCCESS") echo -e "${GREEN}✅ $message${NC}" ;;
        "ERROR") echo -e "${RED}❌ $message${NC}" ;;
        "WARNING") echo -e "${YELLOW}⚠️  $message${NC}" ;;
        "INFO") echo -e "${BLUE}ℹ️  $message${NC}" ;;
    esac
}

# Function to check if file contains readable YAML structure
check_yaml_structure() {
    local file="$1"
    
    # Check for common YAML patterns that shouldn't be visible in encrypted files
    if grep -qE "^[[:space:]]*[a-zA-Z][a-zA-Z0-9_-]*[[:space:]]*:" "$file" 2>/dev/null; then
        return 0  # Contains YAML structure
    fi
    
    # Check for common Kubernetes YAML patterns
    if grep -qE "(apiVersion|kind|metadata|spec|data):" "$file" 2>/dev/null; then
        return 0  # Contains K8s YAML structure
    fi
    
    # Check for common secret patterns
    if grep -qE "(password|token|key|secret|cert|credential)" "$file" 2>/dev/null; then
        return 0  # Contains potential secret keywords
    fi
    
    return 1  # No readable YAML structure found
}

# Function to check file encoding
check_file_encoding() {
    local file="$1"
    local encoding
    
    # Get file encoding using file command
    encoding=$(file -b --mime-encoding "$file" 2>/dev/null || echo "unknown")
    
    case "$encoding" in
        "us-ascii"|"utf-8"|"ascii")
            return 0  # Text encoding (likely unencrypted)
            ;;
        "binary")
            return 1  # Binary encoding (likely encrypted)
            ;;
        *)
            return 2  # Unknown encoding
            ;;
    esac
}

# Function to check file type
check_file_type() {
    local file="$1"
    local file_type
    
    # Get file type using file command
    file_type=$(file -b "$file" 2>/dev/null || echo "unknown")
    
    # Check if file type indicates plain text
    if echo "$file_type" | grep -qiE "(ASCII|UTF-8|text|yaml|json)"; then
        return 0  # Plain text file
    fi
    
    # Check if file type indicates binary/encrypted data
    if echo "$file_type" | grep -qiE "(data|binary|encrypted)"; then
        return 1  # Binary/encrypted file
    fi
    
    return 2  # Unknown file type
}

# Function to check entropy (randomness) of file content
check_entropy() {
    local file="$1"
    local entropy
    
    # Calculate entropy using hexdump and awk
    entropy=$(hexdump -C "$file" 2>/dev/null | \
        awk '{for(i=2;i<=9;i++) if($i!="") print $i}' | \
        sort | uniq -c | \
        awk 'BEGIN{sum=0; count=0} {sum+=$1*log($1); count+=$1} END{if(count>0) print -sum/count+log(count); else print 0}' 2>/dev/null || echo "0")
    
    # High entropy (>4.5) usually indicates encrypted/compressed data
    if awk "BEGIN {exit !($entropy > 4.5)}"; then
        return 1  # High entropy (likely encrypted)
    else
        return 0  # Low entropy (likely plain text)
    fi
}

# Function to check for common unencrypted patterns
check_unencrypted_patterns() {
    local file="$1"
    
    # Common patterns that should not appear in encrypted files
    local patterns=(
        "apiVersion:"
        "kind:"
        "metadata:"
        "spec:"
        "data:"
        "stringData:"
        "password:"
        "token:"
        "secret:"
        "key:"
        "cert:"
        "credential:"
        "BEGIN CERTIFICATE"
        "BEGIN PRIVATE KEY"
        "BEGIN RSA PRIVATE KEY"
        "Bearer "
        "Basic "
    )
    
    for pattern in "${patterns[@]}"; do
        if grep -q "$pattern" "$file" 2>/dev/null; then
            return 0  # Found unencrypted pattern
        fi
    done
    
    return 1  # No unencrypted patterns found
}

# Function to check git-crypt status
check_git_crypt_status() {
    local file="$1"
    
    # Check if git-crypt is available
    if ! command -v git-crypt &> /dev/null; then
        return 2  # git-crypt not available
    fi
    
    # Check if file is tracked by git-crypt
    if git-crypt status "$file" 2>/dev/null | grep -q "encrypted"; then
        return 1  # File is encrypted by git-crypt
    elif git-crypt status "$file" 2>/dev/null | grep -q "not encrypted"; then
        return 0  # File is not encrypted by git-crypt
    else
        return 2  # Cannot determine git-crypt status
    fi
}

# Function to perform comprehensive encryption check
check_file_encryption() {
    local file="$1"
    local result="UNKNOWN"
    local confidence=0
    local reasons=()
    
    print_status "INFO" "Checking file: $file"
    
    # Check if file exists and is readable
    if [[ ! -f "$file" ]]; then
        print_status "ERROR" "File not found: $file"
        return 1
    fi
    
    if [[ ! -r "$file" ]]; then
        print_status "ERROR" "File not readable: $file"
        return 1
    fi
    
    # Check 1: File type analysis
    if check_file_type "$file"; then
        reasons+=("plain text file type")
        ((confidence += 25))
    else
        reasons+=("binary/encrypted file type")
        ((confidence -= 25))
    fi
    
    # Check 2: File encoding analysis
    local encoding_result
    check_file_encoding "$file"
    encoding_result=$?
    
    if [[ $encoding_result -eq 0 ]]; then
        reasons+=("text encoding")
        ((confidence += 20))
    elif [[ $encoding_result -eq 1 ]]; then
        reasons+=("binary encoding")
        ((confidence -= 20))
    fi
    
    # Check 3: YAML structure analysis
    if check_yaml_structure "$file"; then
        reasons+=("readable YAML structure")
        ((confidence += 30))
    else
        reasons+=("no readable YAML structure")
        ((confidence -= 15))
    fi
    
    # Check 4: Unencrypted patterns
    if check_unencrypted_patterns "$file"; then
        reasons+=("contains unencrypted patterns")
        ((confidence += 35))
    else
        reasons+=("no unencrypted patterns found")
        ((confidence -= 10))
    fi
    
    # Check 5: Entropy analysis
    if check_entropy "$file"; then
        reasons+=("low entropy")
        ((confidence += 15))
    else
        reasons+=("high entropy")
        ((confidence -= 20))
    fi
    
    # Check 6: git-crypt status (if available)
    local git_crypt_result
    check_git_crypt_status "$file"
    git_crypt_result=$?
    
    if [[ $git_crypt_result -eq 0 ]]; then
        reasons+=("git-crypt: not encrypted")
        ((confidence += 40))
    elif [[ $git_crypt_result -eq 1 ]]; then
        reasons+=("git-crypt: encrypted")
        ((confidence -= 40))
    fi
    
    # Determine final result based on confidence score
    if [[ $confidence -ge 50 ]]; then
        result="UNENCRYPTED"
    elif [[ $confidence -le -30 ]]; then
        result="ENCRYPTED"
    else
        result="SUSPICIOUS"
    fi
    
    # Print detailed analysis
    echo "  Confidence Score: $confidence"
    echo "  Reasons: ${reasons[*]}"
    echo "  Result: $result"
    echo ""
    
    case "$result" in
        "UNENCRYPTED")
            print_status "ERROR" "UNENCRYPTED: $file"
            UNENCRYPTED_LIST+=("$file")
            ((UNENCRYPTED_FILES++))
            return 1
            ;;
        "ENCRYPTED")
            print_status "SUCCESS" "ENCRYPTED: $file"
            ((ENCRYPTED_FILES++))
            return 0
            ;;
        "SUSPICIOUS")
            print_status "WARNING" "SUSPICIOUS: $file (requires manual verification)"
            SUSPICIOUS_LIST+=("$file")
            ((SUSPICIOUS_FILES++))
            return 2
            ;;
    esac
}

# Function to print usage
print_usage() {
    echo "Usage: $0 [OPTIONS] <file1> <file2> ..."
    echo "   or: $0 -f <file_list>"
    echo ""
    echo "Options:"
    echo "  -f, --file-list    Read file list from file (one file per line)"
    echo "  -h, --help         Show this help message"
    echo "  -v, --verbose      Enable verbose output"
    echo "  -q, --quiet        Suppress non-essential output"
    echo ""
    echo "Examples:"
    echo "  $0 secret1.yaml secret2.yaml"
    echo "  $0 -f changed_files.txt"
    echo "  find . -name '__*.yaml' | $0 -f -"
}

# Function to print summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "           ENCRYPTION SCAN SUMMARY"
    echo "=========================================="
    echo "Total files scanned: $TOTAL_FILES"
    echo "Encrypted files: $ENCRYPTED_FILES"
    echo "Unencrypted files: $UNENCRYPTED_FILES"
    echo "Suspicious files: $SUSPICIOUS_FILES"
    echo ""
    
    if [[ $UNENCRYPTED_FILES -gt 0 ]]; then
        print_status "ERROR" "UNENCRYPTED FILES FOUND:"
        for file in "${UNENCRYPTED_LIST[@]}"; do
            echo "  - $file"
        done
        echo ""
    fi
    
    if [[ $SUSPICIOUS_FILES -gt 0 ]]; then
        print_status "WARNING" "SUSPICIOUS FILES (manual verification needed):"
        for file in "${SUSPICIOUS_LIST[@]}"; do
            echo "  - $file"
        done
        echo ""
    fi
    
    if [[ $UNENCRYPTED_FILES -eq 0 && $SUSPICIOUS_FILES -eq 0 ]]; then
        print_status "SUCCESS" "All files are properly encrypted!"
    fi
}

# Main function
main() {
    local file_list=()
    local use_file_list=false
    local file_list_path=""
    local verbose=false
    local quiet=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--file-list)
                use_file_list=true
                file_list_path="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            -q|--quiet)
                quiet=true
                shift
                ;;
            -*)
                echo "Unknown option: $1"
                print_usage
                exit 1
                ;;
            *)
                file_list+=("$1")
                shift
                ;;
        esac
    done
    
    # Determine file list
    if [[ "$use_file_list" == true ]]; then
        if [[ "$file_list_path" == "-" ]]; then
            # Read from stdin
            while IFS= read -r line; do
                [[ -n "$line" ]] && file_list+=("$line")
            done
        else
            # Read from file
            if [[ ! -f "$file_list_path" ]]; then
                print_status "ERROR" "File list not found: $file_list_path"
                exit 1
            fi
            while IFS= read -r line; do
                [[ -n "$line" ]] && file_list+=("$line")
            done < "$file_list_path"
        fi
    fi
    
    # Check if we have files to process
    if [[ ${#file_list[@]} -eq 0 ]]; then
        print_status "ERROR" "No files specified"
        print_usage
        exit 1
    fi
    
    # Process each file
    TOTAL_FILES=${#file_list[@]}
    local exit_code=0
    
    for file in "${file_list[@]}"; do
        if ! check_file_encryption "$file"; then
            exit_code=1
        fi
    done
    
    # Print summary
    print_summary
    
    # Exit with appropriate code
    if [[ $UNENCRYPTED_FILES -gt 0 ]]; then
        exit 1
    elif [[ $SUSPICIOUS_FILES -gt 0 ]]; then
        exit 2
    else
        exit 0
    fi
}

# Run main function
main "$@"