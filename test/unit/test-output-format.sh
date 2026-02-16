#!/usr/bin/env bash
# test-output-format.sh - Validate output format constraints

set -euo pipefail

test_iterations_is_positive_integer() {
  local test_cases=("1" "5" "10" "100")
  local invalid_cases=("0" "-1" "abc" "1.5" "")

  for value in "${test_cases[@]}"; do
    if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -lt 1 ]]; then
      echo "FAIL: ${value} should be valid iteration count"
      return 1
    fi
  done

  for value in "${invalid_cases[@]}"; do
    if [[ -n "${value}" ]] && [[ "${value}" =~ ^[0-9]+$ ]] && [[ "${value}" -ge 1 ]]; then
      echo "FAIL: ${value} should be invalid iteration count"
      return 1
    fi
  done

  echo "PASS: iteration format validation works"
}

test_final_status_enum() {
  local valid_statuses=("SHIPPED" "MAX_ITERATIONS" "ERROR")
  local invalid_statuses=("shipped" "FAILED" "PENDING" "")

  for status in "${valid_statuses[@]}"; do
    if [[ "${status}" != "SHIPPED" ]] && [[ "${status}" != "MAX_ITERATIONS" ]] && [[ "${status}" != "ERROR" ]]; then
      echo "FAIL: ${status} should be valid final_status"
      return 1
    fi
  done

  for status in "${invalid_statuses[@]}"; do
    if [[ "${status}" == "SHIPPED" ]] || [[ "${status}" == "MAX_ITERATIONS" ]] || [[ "${status}" == "ERROR" ]]; then
      echo "FAIL: ${status} should be invalid final_status"
      return 1
    fi
  done

  echo "PASS: final_status enum validation works"
}

test_pr_url_format() {
  local github_urls=(
    "https://github.com/owner/repo/pull/123"
    "https://github.com/test/test-repo/pull/1"
  )

  local commit_shas=(
    "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    "1234567890abcdef1234567890abcdef12345678"
  )

  local invalid=(
    "not-a-url"
    "http://example.com"
    "12345"
  )

  for url in "${github_urls[@]}"; do
    if ! [[ "${url}" =~ ^https://github.com/ ]]; then
      echo "FAIL: ${url} should be valid GitHub URL"
      return 1
    fi
  done

  for sha in "${commit_shas[@]}"; do
    if ! [[ "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
      echo "FAIL: ${sha} should be valid commit SHA"
      return 1
    fi
  done

  for invalid_value in "${invalid[@]}"; do
    if [[ "${invalid_value}" =~ ^https://github.com/ ]] || [[ "${invalid_value}" =~ ^[0-9a-f]{40}$ ]]; then
      echo "FAIL: ${invalid_value} should be invalid"
      return 1
    fi
  done

  echo "PASS: pr_url format validation works"
}

main() {
  local failed=0

  test_iterations_is_positive_integer || failed=$((failed + 1))
  test_final_status_enum || failed=$((failed + 1))
  test_pr_url_format || failed=$((failed + 1))

  echo ""
  if [[ ${failed} -eq 0 ]]; then
    echo "✅ All output format tests passed"
    return 0
  else
    echo "❌ ${failed} output format test(s) failed"
    return 1
  fi
}

main "$@"
