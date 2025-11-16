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
echo "3. Running MCR001 tests..."
mix test test/moo_courses_web/mcr001_1a_test.exs test/moo_courses_web/mcr001_2a_test.exs test/moo_courses_web/auth_test.exs

echo ""
echo "✅ All QA checks passed!"
echo ""
