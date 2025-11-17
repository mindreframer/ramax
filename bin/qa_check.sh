#!/usr/bin/env bash
set -e

echo ""
echo "=== Running QA Checks ==="
echo ""

echo "1. Running mix format --check-formatted..."
mix format --check-formatted

echo ""
echo "2. Running mix compile..."
mix compile

echo ""
echo "3. Running all tests..."
mix test

echo ""
echo "✅ All QA checks passed!"
echo ""
