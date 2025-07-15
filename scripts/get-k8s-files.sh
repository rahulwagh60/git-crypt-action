#!/bin/bash
# identify-k8s-files.sh

# Inputs: environment variables ANY_CHANGED and ALL_CHANGED_FILES
# Example:
# export ANY_CHANGED="true"
# export ALL_CHANGED_FILES="file1.yaml file2.yaml .github/workflows/workflow.yaml"

K8S_FILES=""
K8S_FILES_FOUND="false"

# Check if any YAML files changed
if [ "$ANY_CHANGED" == "true" ]; then
  echo "Changed YAML files: $ALL_CHANGED_FILES"

  # Process each changed file
  for file in $ALL_CHANGED_FILES; do
    echo "Checking file: $file"

    # Skip workflow files
    if [[ "$file" == .github/workflows/* ]]; then
      echo "  → Skipping workflow file: $file"
      continue
    fi

    # Check if file exists (not deleted)
    if [ -f "$file" ]; then
      # Check for Kubernetes manifest indicators
      if grep -q "apiVersion:" "$file" 2>/dev/null && grep -q "kind:" "$file" 2>/dev/null; then
        echo "  → Kubernetes manifest detected: $file"
        K8S_FILES+="$file\n"
        K8S_FILES_FOUND="true"
      elif [[ "$file" == *k8s* ]] || [[ "$file" == *kubernetes* ]] || [[ "$file" == *manifests* ]]; then
        echo "  → Kubernetes manifest detected by path: $file"
        K8S_FILES+="$file\n"
        K8S_FILES_FOUND="true"
      else
        echo "  → Not a Kubernetes manifest: $file"
      fi
    else
      echo "  → File deleted or not found: $file"
    fi
  done

  # Clean up the files list
  K8S_FILES=$(echo -e "$K8S_FILES" | sed '/^$/d')
else
  echo "No YAML files changed"
fi

# Export results
echo "K8S_FILES_FOUND=$K8S_FILES_FOUND" >> "$GITHUB_ENV"
echo "K8S_YAML_FILES<<EOF" >> "$GITHUB_ENV"
echo -e "$K8S_FILES" >> "$GITHUB_ENV"
echo "EOF" >> "$GITHUB_ENV"
