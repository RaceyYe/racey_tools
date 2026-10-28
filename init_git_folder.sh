#!/bin/bash

# init_pipeline.sh - Initialize a bioinformatics pipeline repository
# Usage: ./init_pipeline.sh <repository_name>

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if repository name was provided
if [ $# -eq 0 ]; then
    echo -e "${RED}Error: No repository name provided${NC}"
    echo "Usage: ./init_pipeline.sh <repository_name>"
    exit 1
fi

REPO_NAME="$1"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Initializing pipeline repository: ${REPO_NAME}${NC}"
echo -e "${GREEN}========================================${NC}"

# Create the main directory
mkdir -p "$REPO_NAME"
cd "$REPO_NAME"

# Initialize Git repository
git init

# Create the directory structure
echo -e "${YELLOW}Creating directory structure...${NC}"

# Main directories
mkdir -p config
mkdir -p workflow/rules
mkdir -p scripts/{py,r,rs,sh}
mkdir -p envs
mkdir -p logs
mkdir -p test_data

# Create placeholder files to maintain directory structure
touch config/README.md
touch workflow/Snakefile
touch workflow/rules/README.md
touch scripts/py/README.md
touch scripts/r/README.md
touch scripts/rs/README.md
touch scripts/sh/README.md
touch envs/README.md
touch logs/.gitkeep
touch test_data/.gitkeep

# Create the .gitignore file
echo -e "${YELLOW}Creating .gitignore...${NC}"

cat > .gitignore << 'EOF'
# Python
__pycache__/
*.pyc
*.pyo
*.pyd
.Python
*.so
*.egg
*.egg-info/
dist/
build/
*.egg-info/

# Conda
envs/
*.conda
*.yml.lock
conda-meta/

# Snakemake
.snakemake/
*.snakemake
*_tmp/

# Logs
logs/
*.log

# Results
test_data/
results/
output/
*.out

# Large sequencing files
*.fastq
*.fastq.gz
*.fq
*.fq.gz
*.bam
*.sam
*.cram
*.crai
*.bai
*.sai
*.vcf
*.vcf.gz
*.gff
*.gff.gz
*.gtf
*.gtf.gz

# Jupyter
.ipynb_checkpoints/
*.ipynb
*.ipynb_*

# Mac/Linux
.DS_Store
Thumbs.db
*.swp
*~
*.tmp
*.temp

# IDE
.vscode/
.idea/
*.iml
.editorconfig

# Environment files
.env
.venv
venv/

# Benchmarking
.benchmark/
benchmark/

# Temporary files
tmp/
temp/
*.tmp
*.temp
EOF

# Create a README.md with basic structure
echo -e "${YELLOW}Creating README.md...${NC}"

cat > README.md << 'EOF'
# Pipeline Repository

## Directory Structure
EOF
