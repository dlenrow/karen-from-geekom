#!/bin/bash

# Paths and variables
BASE_OS_FILE_LIST="/tmp/base_os_files.txt"
ROOT_DIR="/"
HOME_DIR="/home/drl"
TMP_DIR="/root/tmp_backup"
ALL_FILES_LIST="$TMP_DIR/all_current_files.txt"
FILES_TO_BACKUP="$TMP_DIR/files_to_backup.txt"

# Create a temporary directory for intermediate files
mkdir -p "$TMP_DIR"
if [[ ! -w "$TMP_DIR" ]]; then
    echo "Error: Cannot write to temporary directory $TMP_DIR"
    exit 1
fi

# Check if the base OS file list exists
if [[ ! -f "$BASE_OS_FILE_LIST" ]]; then
    echo "Error: Base OS file list $BASE_OS_FILE_LIST does not exist."
    exit 1
fi

echo "Generating a list of all files in the system..."
# Generate the list of all files, including /home/drl explicitly
{
    sudo find "$ROOT_DIR" -xdev -type f
    sudo find "$HOME_DIR" -xdev -type f
} | sort | uniq > "$ALL_FILES_LIST"

if [[ ! -s "$ALL_FILES_LIST" ]]; then
    echo "Error: Failed to generate the list of all current files."
    exit 1
fi

echo "Identifying files to back up..."
# Find files in current system that are not part of the base OS
grep -vxFf "$BASE_OS_FILE_LIST" "$ALL_FILES_LIST" > "$FILES_TO_BACKUP"

if [[ ! -s "$FILES_TO_BACKUP" ]]; then
    echo "No files to back up. The system matches the base OS exactly."
    exit 0
fi

echo "Calculating backup size..."
# Calculate total size and file count of files to back up
TOTAL_SIZE=0
TOTAL_FILES=0

while IFS= read -r file; do
    if [[ -e "$file" ]]; then
        FILE_SIZE=$(stat --format=%s "$file")
        TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))
        TOTAL_FILES=$((TOTAL_FILES + 1))
    fi
done < "$FILES_TO_BACKUP"

# Convert total size to human-readable format
TOTAL_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "$TOTAL_SIZE")

echo "Backup Summary:"
echo "Total files to back up: $TOTAL_FILES"
echo "Total size of backup: $TOTAL_SIZE_HUMAN"

# Cleanup temporary files
rm -rf "$TMP_DIR"

