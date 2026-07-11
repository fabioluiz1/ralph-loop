#!/usr/bin/env bash
# Enforces the commit message convention. Git passes the message file as $1.
#   line 1: type(#N): title  (title >= 10 chars)
#   line 2: blank
#   line 3+: body (required)
set -euo pipefail

header=$(sed -n '1p' "$1")
line2=$(sed -n '2p' "$1")
body=$(sed -n '3p' "$1")

re='^(feat|fix|docs|refactor|test|chore)\(#[0-9]+\): .{10,}$'
if ! [[ "$header" =~ $re ]]; then
  echo "header must match 'type(#N): title' (title >=10 chars)" >&2
  exit 1
fi

if [[ -n "$line2" ]]; then
  echo "line 2 must be blank (header/body separator)" >&2
  exit 1
fi

if [[ -z "$body" ]]; then
  echo "a body paragraph is required after the blank line" >&2
  exit 1
fi
