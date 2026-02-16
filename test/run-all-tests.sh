#!/usr/bin/env bash
# run-all-tests.sh - Run all shell script-level tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "🧪 Running shell script-level integration tests"
echo ""

total_tests=0
failed_tests=0

run_test_file() {
  local test_file="$1"
  local test_name
  test_name="$(basename "${test_file}")"

  echo "▶ Running ${test_name}..."
  total_tests=$((total_tests + 1))

  if bash "${test_file}"; then
    echo "  ✅ ${test_name} passed"
  else
    echo "  ❌ ${test_name} failed"
    failed_tests=$((failed_tests + 1))
  fi
  echo ""
}

# Run unit tests
echo "=== Unit Tests ==="
for test_file in "${SCRIPT_DIR}"/unit/test-*.sh; do
  if [[ -f "${test_file}" ]]; then
    run_test_file "${test_file}"
  fi
done

# Run integration tests
echo "=== Integration Tests ==="
for test_file in "${SCRIPT_DIR}"/integration/test-*.sh; do
  if [[ -f "${test_file}" ]]; then
    run_test_file "${test_file}"
  fi
done

# Summary
echo "=== Summary ==="
echo "Total tests: ${total_tests}"
echo "Failed: ${failed_tests}"
echo "Passed: $((total_tests - failed_tests))"
echo ""

if [[ ${failed_tests} -eq 0 ]]; then
  echo "✅ All tests passed!"
  exit 0
else
  echo "❌ ${failed_tests} test(s) failed"
  exit 1
fi
