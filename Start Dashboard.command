#!/bin/bash
# Double-click this file on Mac to start The House Dashboard

cd "$(dirname "$0")"

echo ""
echo "  ========================================"
echo "      The House - Dashboard"
echo "      Tom, Jerry & Big Mamma"
echo "  ========================================"
echo ""

# Check Python
if ! command -v python3 &>/dev/null; then
    echo "  ERROR: Python 3 not found."
    echo "  Install from https://www.python.org/downloads/"
    echo ""
    read -rp "  Press Enter to close..."
    exit 1
fi

# Auto-install Flask if missing
if ! python3 -c "import flask" &>/dev/null; then
    echo "  Installing Flask..."
    pip3 install flask >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "  ERROR: Could not install Flask."
        echo "  Try running: pip3 install flask"
        echo ""
        read -rp "  Press Enter to close..."
        exit 1
    fi
    echo "  Flask installed."
    echo ""
fi

# Open browser after a short delay
(sleep 2 && open "http://localhost:5005") &

echo "  Starting dashboard at http://localhost:5005"
echo "  Close this window to stop."
echo ""

python3 "$(dirname "$0")/ui.py"
