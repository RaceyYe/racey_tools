#!/bin/bash
# version 1.2 (2024-01-20): Add parallel processing with -j flag

set -euo pipefail

#============================================================================
# DEFAULT VALUES
#============================================================================
base_dir="$(pwd)"  # Default to current directory (absolute path)
output_dir=""
create_output_dir=false
contained_element=""
folder_depth=""
regex_patterns=()
mode="full"  # Options: full (full path) or base (basename only)
move_files=false
copy_files=false
parallel_jobs=1  # Default to sequential
exclude_metadata=true  # Always exclude macOS metadata files

#============================================================================
# USAGE FUNCTION
#============================================================================
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Find files matching specific patterns in a directory, with optional move/copy to output directory.

OPTIONS:
    -b, --base-dir DIR       Base directory to search (default: current directory)
                             Automatically converted to absolute path
    -c, --contain ELEMENT    Filter results containing this string (filename only)
    -d, --depth NUM          Maximum depth to search (e.g., 1, 2, 3)
    -p, --pattern PATTERNS   Regex patterns to match (can specify multiple)
    -o, --option MODE        Output mode: 'full' (full path) or 'base' (basename only)
    -O, --output-dir DIR     Output directory to move/copy found files
                             (requires -p flag or pre-existing directory)
    -P, --create-output      Create output directory if it doesn't exist
                             (must be used with -O/--output-dir)
    -m, --move               Move files to output directory instead of just listing
    -C, --copy               Copy files to output directory instead of just listing
                             (preserves original files)
    -j, --jobs NUM           Number of parallel jobs for copy/move (default: 1)
                             Use -j 4 for 4 parallel copies, -j 0 for auto-detect
    -h, --help               Display this help message

NOTES:
    - Full paths are always shown from root (/) when using --option full
    - When using -O/--output-dir without -P, the directory must already exist
    - Using -m/--move or -C/--copy requires -O/--output-dir to be specified
    - -m and -C are mutually exclusive (cannot use both)
    - Multiple patterns can be specified after -p/--pattern
    - macOS metadata files (._* and .DS_Store) are automatically excluded
    - Parallel processing (-j) requires GNU Parallel for best performance

EXAMPLES:
    # Find all R1 fastq files in current directory (absolute paths)
    $(basename "$0") -p "*R1*.fq"
    
    # Find R1 and R2 files, output basenames only
    $(basename "$0") -p "*R1*.fq" "*R2*.fq" -o base
    
    # Search specific directory with depth limit
    $(basename "$0") -b /data/fastq -d 2 -p "*.fastq.gz"
    
    # Find files containing "sample" in the name
    $(basename "$0") -p "*.fq" -c sample
    
    # Find files and move to existing output directory
    $(basename "$0") -p "*.fastq.gz" -O /data/processed -m
    
    # Find files and copy to existing output directory (preserve originals)
    $(basename "$0") -p "*.fastq.gz" -O /data/backup -C
    
    # Copy files using 8 parallel jobs (faster)
    $(basename "$0") -p "*.fastq.gz" -O /data/backup -C -j 8
    
    # Copy with auto-detected optimal parallel jobs
    $(basename "$0") -p "*.fastq.gz" -O /data/backup -C -j 0
    
    # Find files and move to new output directory (create if needed)
    $(basename "$0") -b /data/raw -p "*.fq" -O /data/cleaned -P -m
    
    # Find R1 files in subdirectories and copy to output with parallel
    $(basename "$0") -b /data/fastq -d 3 -p "*R1*.fq.gz" -O /data/R1_files -P -C -j 4

EOF
    exit 1
}

#============================================================================
# ARGUMENT PARSING
#============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--base-dir)
            base_dir="$2"
            shift 2
            ;;
        -c|--contain)
            contained_element="$2"
            shift 2
            ;;
        -d|--depth)
            folder_depth="$2"
            shift 2
            ;;
        -p|--pattern)
            regex_patterns=()  # Clear defaults
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                regex_patterns+=("$1")
                shift
            done
            ;;
        -o|--option)
            mode="$2"
            shift 2
            ;;
        -O|--output-dir)
            output_dir="$2"
            shift 2
            ;;
        -P|--create-output)
            create_output_dir=true
            shift
            ;;
        -m|--move)
            move_files=true
            shift
            ;;
        -C|--copy)
            copy_files=true
            shift
            ;;
        -j|--jobs)
            parallel_jobs="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option $1"
            usage
            ;;
    esac
done

#============================================================================
# PATH NORMALIZATION
#============================================================================
# Convert base_dir to absolute path
if [[ ! "$base_dir" =~ ^/ ]]; then
    base_dir="$(cd "$base_dir" 2>/dev/null && pwd)" || {
        echo "Error: Cannot access directory '$base_dir'" >&2
        exit 1
    }
fi

# Convert output_dir to absolute path if specified
if [[ -n "$output_dir" ]]; then
    if [[ ! "$output_dir" =~ ^/ ]]; then
        # If relative path, make it absolute from current working directory
        output_dir="$(cd "$(dirname "$output_dir")" 2>/dev/null && pwd)/$(basename "$output_dir")" || {
            # If parent doesn't exist, create absolute path from pwd
            output_dir="$(pwd)/$output_dir"
        }
    fi
    # Remove trailing slash if present
    output_dir="${output_dir%/}"
fi

#============================================================================
# VALIDATION
#============================================================================
# Check if base directory exists
if [[ ! -d "$base_dir" ]]; then
    echo "Error: Directory '$base_dir' does not exist" >&2
    exit 1
fi

# Validate mode option
if [[ "$mode" != "full" && "$mode" != "base" ]]; then
    echo "Error: Invalid mode '$mode'. Must be 'full' or 'base'" >&2
    exit 1
fi

# Validate parallel jobs
if [[ ! "$parallel_jobs" =~ ^[0-9]+$ ]]; then
    echo "Error: -j/--jobs must be a positive integer or 0 for auto" >&2
    exit 1
fi

# Auto-detect optimal parallel jobs
if [[ "$parallel_jobs" -eq 0 ]]; then
    if command -v nproc &> /dev/null; then
        parallel_jobs=$(nproc)
    elif command -v sysctl &> /dev/null; then
        parallel_jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    else
        parallel_jobs=4
    fi
    echo "Auto-detected $parallel_jobs CPU cores" >&2
fi

# Validate output directory options
if [[ "$create_output_dir" == true && -z "$output_dir" ]]; then
    echo "Error: -P/--create-output requires -O/--output-dir to be specified" >&2
    exit 1
fi

if [[ "$move_files" == true && -z "$output_dir" ]]; then
    echo "Error: -m/--move requires -O/--output-dir to be specified" >&2
    exit 1
fi

if [[ "$copy_files" == true && -z "$output_dir" ]]; then
    echo "Error: -C/--copy requires -O/--output-dir to be specified" >&2
    exit 1
fi

if [[ "$move_files" == true && "$copy_files" == true ]]; then
    echo "Error: -m/--move and -C/--copy are mutually exclusive" >&2
    exit 1
fi

if [[ -n "$output_dir" ]]; then
    if [[ "$create_output_dir" == true ]]; then
        # Create output directory if it doesn't exist
        if [[ ! -d "$output_dir" ]]; then
            echo "Creating output directory: $output_dir"
            mkdir -p "$output_dir" || {
                echo "Error: Failed to create output directory '$output_dir'" >&2
                exit 1
            }
        fi
    else
        # Check that output directory exists
        if [[ ! -d "$output_dir" ]]; then
            echo "Error: Output directory '$output_dir' does not exist" >&2
            echo "Use -P/--create-output flag to create it automatically" >&2
            exit 1
        fi
    fi
fi

# If no patterns specified, use a default
if [[ ${#regex_patterns[@]} -eq 0 ]]; then
    regex_patterns=("*")
fi

#============================================================================
# BUILD FIND COMMAND
#============================================================================
find_cmd="find \"$base_dir\""

# Add depth limit if specified
if [[ -n "$folder_depth" ]]; then
    find_cmd="$find_cmd -maxdepth $folder_depth"
fi

# Add type filter (files only)
find_cmd="$find_cmd -type f"

# Exclude macOS metadata files
if [[ "$exclude_metadata" == true ]]; then
    find_cmd="$find_cmd ! -name \"._*\" ! -name \".DS_Store\" ! -name \"Thumbs.db\""
fi

# Add pattern matching
if [[ ${#regex_patterns[@]} -gt 0 ]]; then
    find_cmd="$find_cmd \("
    for i in "${!regex_patterns[@]}"; do
        if [[ $i -gt 0 ]]; then
            find_cmd="$find_cmd -o"
        fi
        find_cmd="$find_cmd -name \"${regex_patterns[$i]}\""
    done
    find_cmd="$find_cmd \)"
fi

#============================================================================
# DISPLAY SEARCH INFO
#============================================================================
echo "=== File Search ===" >&2
echo "Search directory: $base_dir" >&2
if [[ -n "$folder_depth" ]]; then
    echo "Max depth: $folder_depth" >&2
fi
echo "Patterns: ${regex_patterns[*]}" >&2
if [[ -n "$contained_element" ]]; then
    echo "Contains filter: $contained_element" >&2
fi
if [[ -n "$output_dir" ]]; then
    echo "Output directory: $output_dir" >&2
    if [[ "$move_files" == true ]]; then
        echo "Action: MOVE files" >&2
    elif [[ "$copy_files" == true ]]; then
        echo "Action: COPY files (preserving originals)" >&2
    else
        echo "Action: LIST only (use -m to move, -C to copy)" >&2
    fi
    if [[ "$move_files" == true || "$copy_files" == true ]]; then
        echo "Parallel jobs: $parallel_jobs" >&2
    fi
fi
echo "" >&2

#============================================================================
# COLLECT AND FILTER FILES
#============================================================================
echo "Finding and filtering files..." >&2

# Use temp file to store filtered file list
temp_file=$(mktemp)
trap 'rm -f "$temp_file"' EXIT

# Execute find and filter
eval "$find_cmd" | sort | while IFS= read -r filepath; do
    filename="$(basename "$filepath")"
    
    # Apply contain filter if specified (only check filename, not full path)
    if [[ -n "$contained_element" ]]; then
        if [[ ! "$filename" =~ $contained_element ]]; then
            continue
        fi
    fi
    
    # Output based on mode
    if [[ "$mode" == "base" ]]; then
        echo "$filename"
    else
        echo "$filepath"
    fi
    
    # Store filepath for potential copy/move
    echo "$filepath" >> "$temp_file"
done

#============================================================================
# PROCESS FILES (COPY/MOVE)
#============================================================================
file_count=$(wc -l < "$temp_file")

if [[ "$move_files" == true || "$copy_files" == true ]]; then
    echo "" >&2
    echo "Processing $file_count files..." >&2
    
    if [[ $file_count -eq 0 ]]; then
        echo "No files to process" >&2
        exit 0
    fi
    
    # Function for parallel processing
    process_files() {
        local action="$1"  # "cp" or "mv"
        local output_dir="$2"
        local temp_file="$3"
        local max_jobs="$4"
        
        if [[ $max_jobs -eq 1 ]]; then
            # Sequential processing
            while IFS= read -r filepath; do
                filename="$(basename "$filepath")"
                dest_path="$output_dir/$filename"
                
                if [[ -e "$dest_path" ]]; then
                    echo "  Warning: Destination exists, skipping: $dest_path" >&2
                else
                    $action "$filepath" "$dest_path" && {
                        echo "  ${action^^} to: $dest_path" >&2
                    } || {
                        echo "  Error: Failed to $action: $filepath" >&2
                    }
                fi
            done < "$temp_file"
        else
            # Parallel processing with background jobs
            local job_count=0
            local pids=()
            
            while IFS= read -r filepath; do
                filename="$(basename "$filepath")"
                dest_path="$output_dir/$filename"
                
                if [[ -e "$dest_path" ]]; then
                    echo "  Warning: Destination exists, skipping: $dest_path" >&2
                    continue
                fi
                
                # Launch background job
                (
                    if $action "$filepath" "$dest_path"; then
                        echo "  ${action^^} to: $dest_path" >&2
                    else
                        echo "  Error: Failed to $action: $filepath" >&2
                    fi
                ) &
                
                pids+=($!)
                ((job_count++))
                
                # Control number of parallel jobs
                if [[ $job_count -ge $max_jobs ]]; then
                    # Wait for any job to finish
                    wait -n 2>/dev/null || true
                    ((job_count--))
                fi
            done < "$temp_file"
            
            # Wait for all remaining jobs
            for pid in "${pids[@]}"; do
                wait "$pid" 2>/dev/null || true
            done
        fi
    }
    
    # Check for GNU Parallel (preferred method)
    if command -v parallel &> /dev/null && [[ $parallel_jobs -gt 1 ]]; then
        echo "Using GNU Parallel with $parallel_jobs jobs..." >&2
        
        if [[ "$copy_files" == true ]]; then
            # Filter out existing files first
            awk -v outdir="$output_dir" '{
                file=$0
                gsub(/.*\//, "", file)
                if (!system("test -e " outdir "/" file)) {
                    print "Warning: Destination exists, skipping: " outdir "/" file > "/dev/stderr"
                } else {
                    print
                }
            }' "$temp_file" | parallel -j "$parallel_jobs" --bar \
                'cp {} '"$output_dir"'/ && echo "  COPIED to: '"$output_dir"'/{/}" >&2'
        elif [[ "$move_files" == true ]]; then
            awk -v outdir="$output_dir" '{
                file=$0
                gsub(/.*\//, "", file)
                if (!system("test -e " outdir "/" file)) {
                    print "Warning: Destination exists, skipping: " outdir "/" file > "/dev/stderr"
                } else {
                    print
                }
            }' "$temp_file" | parallel -j "$parallel_jobs" --bar \
                'mv {} '"$output_dir"'/ && echo "  MOVED to: '"$output_dir"'/{/}" >&2'
        fi
    else
        # Fallback to built-in parallel or sequential
        if [[ $parallel_jobs -gt 1 ]]; then
            echo "Using built-in parallel processing with $parallel_jobs jobs..." >&2
            echo "Tip: Install GNU Parallel for better performance and progress bar" >&2
        else
            echo "Using sequential processing..." >&2
        fi
        
        if [[ "$copy_files" == true ]]; then
            process_files "cp" "$output_dir" "$temp_file" "$parallel_jobs"
        elif [[ "$move_files" == true ]]; then
            process_files "mv" "$output_dir" "$temp_file" "$parallel_jobs"
        fi
    fi
fi

#============================================================================
# SUMMARY
#============================================================================
if [[ -n "$output_dir" ]]; then
    echo "" >&2
    echo "=== Summary ===" >&2
    if [[ "$move_files" == true || "$copy_files" == true ]]; then
        actual_count=$(find "$output_dir" -maxdepth 1 -type f ! -name "._*" ! -name ".DS_Store" | wc -l)
        echo "Files found: $file_count" >&2
        echo "Files in output directory: $actual_count" >&2
        if [[ "$move_files" == true ]]; then
            echo "Original files have been moved" >&2
        elif [[ "$copy_files" == true ]]; then
            echo "Original files have been preserved" >&2
        fi
    else
        echo "Files found: $file_count" >&2
        echo "Use -m/--move flag to move files, or -C/--copy flag to copy files" >&2
    fi
fi