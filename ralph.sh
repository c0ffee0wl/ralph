#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool amp|claude|claudo] [max_iterations]

set -e

# Parse arguments
TOOL="claudo"  # Default to claudo
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    *)
      # Assume it's max_iterations if it's a number
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# Validate tool choice
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" && "$TOOL" != "claudo" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp', 'claude', or 'claudo'."
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
BACKUP_DIR="/tmp/ralph-backup-$$"

# Function to restore Ralph files if they were deleted
restore_ralph_files() {
  local files_restored=0

  # Check each critical file
  for file in "CLAUDE.md" "prompt.md" "ralph.sh" "prd.json" "progress.txt"; do
    if [ ! -f "$SCRIPT_DIR/$file" ] && [ -f "$BACKUP_DIR/$file" ]; then
      echo "  Restoring $file from backup..."
      cp "$BACKUP_DIR/$file" "$SCRIPT_DIR/$file"
      files_restored=1
    fi
  done

  # If backup didn't have the file, try git
  for file in "CLAUDE.md" "prompt.md" "ralph.sh"; do
    if [ ! -f "$SCRIPT_DIR/$file" ]; then
      (cd "$SCRIPT_DIR" && git checkout HEAD -- "$file" 2>/dev/null) || true
      if [ -f "$SCRIPT_DIR/$file" ]; then
        echo "  Restored $file from git"
        files_restored=1
      fi
    fi
  done

  if [ $files_restored -eq 1 ]; then
    echo "  Ralph files restored successfully."
  fi
}

# Backup Ralph files before starting (protection against project init commands)
backup_ralph_files() {
  mkdir -p "$BACKUP_DIR"
  for file in "CLAUDE.md" "prompt.md" "ralph.sh" "prd.json" "progress.txt"; do
    if [ -f "$SCRIPT_DIR/$file" ]; then
      cp "$SCRIPT_DIR/$file" "$BACKUP_DIR/$file"
    fi
  done
  echo "Ralph files backed up to $BACKUP_DIR"
}

# Clean up backup on exit
cleanup_backup() {
  if [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
  fi
}
trap cleanup_backup EXIT

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    # Strip "ralph/" prefix from branch name for folder
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
    
    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"
    
    # Reset progress file for new run
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"

# Backup Ralph files before starting iterations
backup_ralph_files

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  # Restore Ralph files if they were deleted by previous iteration
  # (e.g., by hexo init, create-react-app, or similar project scaffolding)
  if [ ! -d "$SCRIPT_DIR" ]; then
    echo "  WARNING: Ralph directory was deleted! Recreating..."
    mkdir -p "$SCRIPT_DIR"
  fi
  restore_ralph_files

  # Verify the required prompt file exists for the selected tool
  if [[ "$TOOL" == "amp" ]]; then
    if [ ! -f "$SCRIPT_DIR/prompt.md" ]; then
      echo "  ERROR: Cannot restore prompt.md required for amp. Aborting."
      exit 1
    fi
  else
    if [ ! -f "$SCRIPT_DIR/CLAUDE.md" ]; then
      echo "  ERROR: Cannot restore CLAUDE.md required for $TOOL. Aborting."
      exit 1
    fi
  fi

  # Run the selected tool with the ralph prompt
  if [[ "$TOOL" == "amp" ]]; then
    OUTPUT=$(cat "$SCRIPT_DIR/prompt.md" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
  elif [[ "$TOOL" == "claudo" ]]; then
    OUTPUT=$(claudo --git --host -- --print < "$SCRIPT_DIR/CLAUDE.md" 2>&1 | tee /dev/stderr) || true
  else
    # Claude Code: use --dangerously-skip-permissions for autonomous operation, --print for output
    OUTPUT=$(claude --dangerously-skip-permissions --print < "$SCRIPT_DIR/CLAUDE.md" 2>&1 | tee /dev/stderr) || true
  fi
  
  # Check for completion signal
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  # Sync updated prd.json and progress.txt to backup for next iteration
  for file in "prd.json" "progress.txt"; do
    if [ -f "$SCRIPT_DIR/$file" ]; then
      cp "$SCRIPT_DIR/$file" "$BACKUP_DIR/$file"
    fi
  done

  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
