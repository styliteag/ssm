#!/bin/bash

# SSH Key Manager Development Startup Script
# This script starts both the backend and frontend in development mode

CONFDIR=${1:-}

set -e

if [ -n "$CONFDIR" ]; then
    echo "CONFIG: $CONFDIR/config/config.toml"
fi

echo "🚀 Starting SSH Key Manager Development Environment"
echo

# Function to handle cleanup on exit
cleanup() {
    echo
    echo "🛑 Shutting down development servers..."
    jobs -p | xargs -r kill
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Check if backend dependencies are ready
if [ ! -f "backend/Cargo.toml" ]; then
    echo "❌ Backend not found. Make sure you're in the ssm root directory."
    exit 1
fi

# Check if frontend dependencies are installed
if [ ! -d "frontend/node_modules" ]; then
    echo "📦 Installing frontend dependencies..."
    cd frontend
    npm install
    cd ..
fi

# Start backend server
echo "🦀 Starting Rust backend server..."
cd backend
#RUST_LOG=debug cargo run &
if [ -n "$CONFDIR" ]; then      
     CONFIG=$CONFDIR/config/config.toml just dev &
else
     just dev &
fi
BACKEND_PID=$!
cd ..

# Wait a moment for backend to start
echo "⏳ Waiting for backend to initialize..."
sleep 3

# Start frontend development server
echo "⚛️  Starting React frontend server..."
cd frontend
npm run dev &
FRONTEND_PID=$!
cd ..

echo
echo "✅ Development servers started successfully!"
echo "📱 Frontend: http://localhost:5173"
echo "🔧 Backend API: http://localhost:8000"
echo
echo "Press Ctrl+C to stop all servers"
echo

# Wait for background processes
wait