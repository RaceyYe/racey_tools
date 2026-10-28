#!/bin/bash

# Function to convert Windows path to Linux path
convert_windows_to_linux() {
    local win_path="$1"
    # Remove surrounding quotes if present
    win_path="${win_path%\"}"
    win_path="${win_path#\"}"
    win_path="${win_path%\'}"
    win_path="${win_path#\'}"

    # Replace backslashes with forward slashes
    local linux_path="${win_path//\\//}"
    # Check if the path starts with a drive letter (e.g., "D:")
    if [[ "$linux_path" =~ ^[A-Za-z]: ]]; then
        # Extract drive letter (lowercase)
        local drive_letter=$(echo "${linux_path:0:1}" | tr '[:upper:]' '[:lower:]')
        # Extract the rest of the path after "D:"
        local rest_path="${linux_path:2}"
        # Remove leading slash (if present) to avoid double slashes
        rest_path="${rest_path#/}"
        # Construct final Linux path
        linux_path="/mnt/${drive_letter}/${rest_path}"
    fi
    echo "$linux_path"
}

# Function to convert Linux path to Windows path
convert_linux_to_windows() {
    local linux_path="$1"
    # Remove surrounding quotes if present
    linux_path="${linux_path%\"}"
    linux_path="${linux_path#\"}"
    linux_path="${linux_path%\'}"
    linux_path="${linux_path#\'}"

    # Check if the path starts with /mnt/<drive_letter>/
    if [[ "$linux_path" =~ ^/mnt/[A-Za-z]/ ]]; then
        # Extract drive letter (uppercase)
        local drive_letter=$(echo "$linux_path" | cut -d/ -f3 | tr '[:lower:]' '[:upper:]')
        # Extract the rest of the path after "/mnt/<drive_letter>/"
        local rest_path="${linux_path#/mnt/[A-Za-z]/}"
        # Construct Windows path with backslashes
        win_path="${drive_letter}:\\${rest_path//\//\\}"
    else
        # For non-/mnt paths, replace forward slashes with backslashes
        win_path="${linux_path//\//\\}"
    fi
    echo "$win_path"
}

# Function to only replace backslashes with forward slashes
replace_backslashes() {
    local path="$1"
    # Remove surrounding quotes if present
    path="${path%\"}"
    path="${path#\"}"
    path="${path%\'}"
    path="${path#\'}"

    # Replace backslashes with forward slashes
    local converted_path="${path//\\//}"
    echo "$converted_path"
}

# Default conversion type
conversion_type="W2L"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --type|-t)
            conversion_type="$2"
            shift 2
            ;;
        *)
            path="$1"
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$path" ]]; then
    echo "Usage: $0 [--type|-t <W2L|L2W|W>] <path>"
    exit 1
fi

# Perform conversion
if [[ "$conversion_type" == "W2L" ]]; then
    converted_path=$(convert_windows_to_linux "$path")
elif [[ "$conversion_type" == "L2W" ]]; then
    converted_path=$(convert_linux_to_windows "$path")
elif [[ "$conversion_type" == "W" ]]; then
    converted_path=$(replace_backslashes "$path")
else
    echo "Invalid type. Use 'W2L' for Windows to Linux, 'L2W' for Linux to Windows, or 'W' to replace backslashes only."
    exit 1
fi

# Output the result
echo "$converted_path"