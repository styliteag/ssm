# SSH Key Manager Frontend

A modern React-based frontend for the SSH Key Manager application, built with TypeScript, Vite, and Tailwind CSS.

## Features

- **Modern React Stack**: React 19, TypeScript, Vite
- **Responsive Design**: Mobile-first design with Tailwind CSS
- **Dark Mode**: Automatic dark/light theme switching
- **Authentication**: Session-based authentication with context management
- **API Integration**: Full REST API integration with the Rust backend
- **Component Library**: Custom UI components with consistent styling
- **Notifications**: Toast notification system for user feedback

## Quick Start

```bash
# Install dependencies
npm install

# Start development server
npm run dev

# Build for production
npm run build
```

The frontend will be available at `http://localhost:5173`.

## Architecture

### Tech Stack

- **React 19** - UI framework
- **TypeScript** - Type safety
- **Vite** - Build tool and dev server
- **Tailwind CSS** - Styling framework
- **React Router** - Client-side routing
- **Axios** - HTTP client for API calls
- **Lucide React** - Icon library

### Project Structure

```
src/
├── components/          # Reusable UI components
│   ├── layout/         # Layout components (Header, Sidebar)
│   ├── shared/         # Shared components
│   └── ui/             # Basic UI components (Button, Input, etc.)
├── contexts/           # React contexts for state management
├── pages/              # Page components
├── services/           # API service layer
├── types/             # TypeScript type definitions
├── utils/             # Utility functions
└── hooks/             # Custom React hooks (future)
```

## Development

### Prerequisites

- Node.js 18+ and npm
- SSH Key Manager backend running on port 8000

### Available Scripts

- `npm run dev` - Start development server
- `npm run build` - Build for production
- `npm run lint` - Run ESLint
- `npm run type-check` - Run TypeScript checking

## API Integration

The frontend communicates with the Rust backend via REST API with automatic proxy configuration in development.

## Components

Built with reusable UI components:

- **Button** - Flexible button with variants
- **Input** - Form input with validation
- **Card** - Container component
- **Loading** - Loading indicators

## State Management

Uses React Context for:

- **AuthContext**: User authentication
- **ThemeContext**: Dark/light mode
- **NotificationContext**: Toast notifications

This frontend provides a solid foundation for the SSH Key Manager application with modern React patterns, responsive design, and full TypeScript support.