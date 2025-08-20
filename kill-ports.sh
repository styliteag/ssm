#!/bin/bash

# Kill processes on ports 8080 and 5173
# Usage: ./kill-ports.sh

echo "Killing processes on ports 8080 and 5173..."

# Function to kill processes on a specific port
kill_port() {
    local port=$1
    local pids=$(lsof -ti:$port 2>/dev/null)
    
    if [ -z "$pids" ]; then
        echo "No processes found on port $port"
        return
    fi
    
    echo "Found processes on port $port: $pids"
    echo "Killing processes..."
    
    for pid in $pids; do
        echo "Killing process $pid"
        kill -9 $pid 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "Successfully killed process $pid"
        else
            echo "Failed to kill process $pid"
        fi
    done
}

# Kill processes on both ports
kill_port 8000
kill_port 5173

echo "Done!"
