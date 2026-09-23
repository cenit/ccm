#!/usr/bin/env bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
VENV_DIR="$SCRIPT_DIR/.vros"
REQUIREMENTS_TXT="$SCRIPT_DIR/requirements.txt"
REQUIREMENTS_CPU_TXT="$SCRIPT_DIR/requirements-cpu.txt"

# Parse arguments
CPU_ONLY=0
ACTIVATE_ONLY=0
DEACTIVATE=0
ROS=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --cpu-only)
      CPU_ONLY=1
      shift
      ;;
    --activate-only)
      ACTIVATE_ONLY=1
      shift
      ;;
    --deactivate)
      DEACTIVATE=1
      shift
      ;;
    --ros)
      ROS=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ $DEACTIVATE -eq 1 ]]; then
  deactivate 2>/dev/null || true
  exit 0
fi

if [[ $ROS -eq 1 ]]; then
  # activate ros
  SEARCH="/opt/ros/"
  FILE="setup.bash"
  FILE_PATH=$(find "$SEARCH" -type f -name "$FILE" -print -quit)
  if [[ -n "$FILE_PATH" ]]; then
    source "$FILE_PATH"
    # exec $SHELL
    echo "ROS activated."
  else
      echo "ROS distribution not found."
  fi
fi

if [[ $ACTIVATE_ONLY -eq 1 ]]; then
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  echo "vros activated."
  exec $SHELL
  exit 0
fi

if ! command -v python3 &>/dev/null; then
  echo "Python3 is not installed. Please install it."
  exit 1
fi

if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

python -m pip install --upgrade pip setuptools wheel

if [[ $CPU_ONLY -eq 1 && -f "$REQUIREMENTS_CPU_TXT" ]]; then
  pip install --upgrade -r "$REQUIREMENTS_CPU_TXT"
elif [[ -f "$REQUIREMENTS_TXT" ]]; then
  pip install --upgrade -r "$REQUIREMENTS_TXT"
fi

echo ".venv/" >> "$SCRIPT_DIR/.gitignore" 2>/dev/null || true

echo "Virtual environment setup complete."
