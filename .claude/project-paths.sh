#!/bin/bash
# .claude/project-paths.sh — Project-specific configuration
# Sourced by shared hooks and pipeline skills.
# Fill in values for your project's stack.

# Build & Test Commands
export BUILD_CMD=""          # e.g., "npm run build", "python manage.py check", "go build ./..."
export TYPECHECK_CMD=""      # e.g., "npx tsc --noEmit", "mypy .", "go vet ./..."
export TEST_CMD=""           # e.g., "npm test", "pytest", "go test ./..."
export LINT_CMD=""           # e.g., "npm run lint", "flake8", "golangci-lint run"

# Package Manager
export LOCKFILE=""           # e.g., "package-lock.json", "requirements.txt", "go.sum"
export PKG_MANAGER=""        # e.g., "npm", "pip", "go"

# Source Directories
export SRC_ROOT=""           # e.g., "client/src", "app/", "internal/"
export COMPONENT_DIR=""      # e.g., "client/src/components/ui" (leave empty if N/A)
export MIGRATION_DIR=""      # e.g., "supabase/migrations", "*/migrations/"
export HOOK_DIR=""           # e.g., "client/src/hooks" (leave empty if N/A)

# Status Commands
export STATUS_CMD=""         # e.g., "supabase status", "python manage.py check"

# Deployment
export DEPLOY_PLATFORM=""    # e.g., "vercel", "fly", "railway", "k8s"
