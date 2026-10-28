#!/bin/bash

# System Status Module
# Usage: system_status [option]
# Options: disk, memory, cpu, all, summary

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
WARNING_DISK_PERCENT=80
CRITICAL_DISK_PERCENT=90
WARNING_MEM_PERCENT=80
CRITICAL_MEM_PERCENT=90

# Function to print section headers
print_header() {
    echo -e "${CYAN}=== $1 ===${NC}"
}

# Function to print warning
print_warning() {
    echo -e "${YELLOW}⚠  $1${NC}"
}

# Function to print error
print_error() {
    echo -e "${RED}✗  $1${NC}"
}

# Function to print success
print_success() {
    echo -e "${GREEN}✓  $1${NC}"
}

# Disk usage check
check_disk() {
    print_header "DISK USAGE"
    
    # Get disk usage for mounted filesystems
    df -h | grep -E '^/dev/' | while read line; do
        usage_percent=$(echo $line | awk '{print $5}' | sed 's/%//')
        mounted_on=$(echo $line | awk '{print $6}')
        available=$(echo $line | awk '{print $4}')
        size=$(echo $line | awk '{print $2}')
        
        if [ $usage_percent -ge $CRITICAL_DISK_PERCENT ]; then
            echo -e "${RED}${mounted_on}: ${usage_percent}% used (${available} available of ${size}) - CRITICAL${NC}"
        elif [ $usage_percent -ge $WARNING_DISK_PERCENT ]; then
            echo -e "${YELLOW}${mounted_on}: ${usage_percent}% used (${available} available of ${size}) - WARNING${NC}"
        else
            echo -e "${GREEN}${mounted_on}: ${usage_percent}% used (${available} available of ${size})${NC}"
        fi
    done
    
    # Check current directory disk usage
    echo
    print_header "CURRENT DIRECTORY USAGE"
    current_usage=$(du -sh . 2>/dev/null | cut -f1)
    echo "Current directory: $current_usage"
    
    # Top 5 largest directories
    echo
    echo "Top 5 largest directories:"
    du -h --max-depth=1 2>/dev/null | sort -hr | head -6 | tail -5
}

# Memory usage check
check_memory() {
    print_header "MEMORY USAGE"
    
    if command -v free &> /dev/null; then
        total_mem=$(free -h | grep Mem | awk '{print $2}')
        used_mem=$(free -h | grep Mem | awk '{print $3}')
        available_mem=$(free -h | grep Mem | awk '{print $7}')
        mem_percent=$(free | grep Mem | awk '{printf("%.0f"), $3/$2 * 100}')
        
        echo "Total: $total_mem"
        echo "Used: $used_mem"
        echo "Available: $available_mem"
        
        if [ $mem_percent -ge $CRITICAL_MEM_PERCENT ]; then
            echo -e "${RED}Memory usage: ${mem_percent}% - CRITICAL${NC}"
        elif [ $mem_percent -ge $WARNING_MEM_PERCENT ]; then
            echo -e "${YELLOW}Memory usage: ${mem_percent}% - WARNING${NC}"
        else
            echo -e "${GREEN}Memory usage: ${mem_percent}%${NC}"
        fi
    else
        print_warning "free command not available"
    fi
}

# CPU usage check
check_cpu() {
    print_header "CPU USAGE"
    
    if command -v mpstat &> /dev/null; then
        cpu_idle=$(mpstat 1 1 | grep -i average | awk '{print $12}')
        cpu_usage=$(echo "100 - $cpu_idle" | bc -l 2>/dev/null | xprintf "%.0f" 2>/dev/null)
        
        if [ ! -z "$cpu_usage" ]; then
            echo "CPU Usage: ${cpu_usage}%"
            
            if [ $cpu_usage -ge 90 ]; then
                print_warning "High CPU usage detected"
            fi
        fi
    else
        # Alternative method
        load_avg=$(cat /proc/loadavg | cut -d' ' -f1-3)
        cpu_cores=$(nproc 2>/dev/null || echo 1)
        echo "Load average: $load_avg"
        echo "CPU cores: $cpu_cores"
        
        # Simple load analysis
        load1=$(echo $load_avg | cut -d' ' -f1)
        if (( $(echo "$load1 > $cpu_cores" | bc -l 2>/dev/null) )); then
            print_warning "System load is high"
        fi
    fi
}

# Process monitoring
check_processes() {
    print_header "TOP PROCESSES BY CPU"
    ps aux --sort=-%cpu | head -6
    
    echo
    print_header "TOP PROCESSES BY MEMORY"
    ps aux --sort=-%mem | head -6
}

# Conda environment info
check_conda() {
    if command -v conda &> /dev/null; then
        print_header "CONDA ENVIRONMENTS"
        conda info --envs
        
        echo
        current_env=$(conda info | grep "active environment" | cut -d: -f2 | xargs)
        if [ "$current_env" != "None" ] && [ ! -z "$current_env" ]; then
            echo "Active environment: $current_env"
        fi
    fi
}

# Current user and system info
check_system() {
    print_header "SYSTEM INFORMATION"
    echo "User: $(whoami)"
    echo "Hostname: $(hostname)"
    echo "OS: $(uname -s) $(uname -r)"
    echo "Uptime: $(uptime -p 2>/dev/null || uptime)"
    
    echo
    print_header "WORKING DIRECTORY"
    echo "Current: $(pwd)"
    echo "Home: $HOME"
}

# Quick summary
show_summary() {
    print_header "SYSTEM STATUS SUMMARY"
    
    # Disk summary
    disk_usage=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
    echo -n "Disk: / -> $disk_usage% "
    if [ $disk_usage -ge $CRITICAL_DISK_PERCENT ]; then
        echo -e "${RED}CRITICAL${NC}"
    elif [ $disk_usage -ge $WARNING_DISK_PERCENT ]; then
        echo -e "${YELLOW}WARNING${NC}"
    else
        echo -e "${GREEN}OK${NC}"
    fi
    
    # Memory summary
    if command -v free &> /dev/null; then
        mem_percent=$(free | grep Mem | awk '{printf("%.0f"), $3/$2 * 100}')
        echo -n "Memory: $mem_percent% "
        if [ $mem_percent -ge $CRITICAL_MEM_PERCENT ]; then
            echo -e "${RED}CRITICAL${NC}"
        elif [ $mem_percent -ge $WARNING_MEM_PERCENT ]; then
            echo -e "${YELLOW}WARNING${NC}"
        else
            echo -e "${GREEN}OK${NC}"
        fi
    fi
    
    # Load summary
    load_avg=$(cat /proc/loadavg | cut -d' ' -f1)
    cpu_cores=$(nproc 2>/dev/null || echo 1)
    echo -n "Load: $load_avg "
    if (( $(echo "$load_avg > $cpu_cores" | bc -l 2>/dev/null) )); then
        echo -e "${YELLOW}HIGH${NC}"
    else
        echo -e "${GREEN}OK${NC}"
    fi
}

# Main function
main() {
    case "${1:-summary}" in
        "disk")
            check_disk
            ;;
        "memory")
            check_memory
            ;;
        "cpu")
            check_cpu
            ;;
        "processes")
            check_processes
            ;;
        "conda")
            check_conda
            ;;
        "system")
            check_system
            ;;
        "all")
            check_system
            echo
            check_disk
            echo
            check_memory
            echo
            check_cpu
            echo
            check_processes
            echo
            check_conda
            ;;
        "summary"|"")
            show_summary
            ;;
        "help"|"-h"|"--help")
            echo "Usage: system_status [option]"
            echo "Options:"
            echo "  disk       - Disk usage information"
            echo "  memory     - Memory usage information"
            echo "  cpu        - CPU usage information"
            echo "  processes  - Top processes by CPU and memory"
            echo "  conda      - Conda environments information"
            echo "  system     - System information"
            echo "  all        - All information"
            echo "  summary    - Quick summary (default)"
            echo "  help       - This help message"
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use 'system_status help' for usage information"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
