#!/usr/bin/env bash
set -u

SITE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/site/index.html"
README_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/README.md"
WORKFLOW_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/pages.yml"
FAVICON_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/site/favicon.svg"
ROBOTS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/site/robots.txt"
pass=0
fail=0

check() {
  local name=$1 pattern=$2
  if grep -Eq "$pattern" "$SITE_FILE"; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$name" >&2
  fi
}

check "install copy control has an accessible icon label" '<button[^>]*id="copy-command"[^>]*aria-label="Copy install command"[^>]*title="Copy install command"'
check "log copy control has an accessible icon label" '<button[^>]*id="copy-log-command"[^>]*aria-label="Copy log command"[^>]*title="Copy log command"'
check "copy controls use a decorative clipboard icon" '<svg class="copy-icon copy-icon--copy"[^>]*aria-hidden="true"'
check "successful copy exposes a visible checkmark state" '\.copy-button\.is-copied .*copy-icon--success'
check "successful copy animates the button" '@keyframes copy-success'
check "failed copy exposes a visible error state" '\.copy-button\.is-failed .*copy-icon--error'
check "copy handler toggles success and failure states" 'classList\.add\("is-copied"\)|classList\.add\("is-failed"\)'
check "copy feedback is announced accessibly" 'id="copy-status"[^>]*aria-live="polite"'
check "copy action uses clipboard API" 'navigator\.clipboard\.writeText'
check "copy action has a fallback" 'execCommand\(["\x27]copy["\x27]\)'
check "quick start keeps curl download without installing curl" 'curl -fsSL https://termux-earnapp\.dinesh29\.com\.np/earnapp-setup\.sh -o earnapp-setup\.sh'
if grep -Eq 'pkg install curl' "$SITE_FILE"; then
  fail=$((fail + 1))
  printf 'FAIL  quick start does not install curl\n' >&2
else
  pass=$((pass + 1))
  printf 'PASS  quick start does not install curl\n'
fi
check "log command has a copy button" '<button[^>]*id="copy-log-command"[^>]*aria-describedby="copy-log-status"'
check "log copy feedback is announced accessibly" 'id="copy-log-status"[^>]*aria-live="polite"'
if grep -Eq 'pkg install curl' "$README_FILE"; then
  fail=$((fail + 1))
  printf 'FAIL  README does not install curl\n' >&2
else
  pass=$((pass + 1))
  printf 'PASS  README does not install curl\n'
fi
if grep -Fq 'curl -fsSL https://termux-earnapp.dinesh29.com.np/earnapp-setup.sh -o earnapp-setup.sh' "$README_FILE"; then
  pass=$((pass + 1))
  printf 'PASS  README keeps the curl download command\n'
else
  fail=$((fail + 1))
  printf 'FAIL  README keeps the curl download command\n' >&2
fi
check "page includes mobile viewport metadata" 'name="viewport"'
check "page includes a responsive layout breakpoint" '@media'
check "page declares the SVG favicon" '<link rel="icon" type="image/svg\+xml" href="favicon\.svg">'
check "brand link targets the outer page top" '<div class="shell" id="top">'
check "header branding uses a terminal prompt" '<span class="brand-mark"[^>]*>&gt;_</span>'
check "page title targets EarnApp for Termux" '<title>EarnApp for Termux: Android Setup Guide</title>'
check "main heading describes setting up EarnApp in Termux" '<h1 id="hero-title">How to set up EarnApp in Termux</h1>'
check "description summarizes the setup guide" '<meta name="description" content="Community guide to setting up EarnApp on Android with Termux and udocker\.[^"]*">'
check "page declares its canonical URL" '<link rel="canonical" href="https://termux-earnapp\.dinesh29\.com\.np/">'
check "visible guide includes menu and service instructions" 'Select menu option 6|sv status earnapp'
if grep -Fq 'cp site/favicon.svg _site/favicon.svg' "$WORKFLOW_FILE"; then
  pass=$((pass + 1))
  printf 'PASS  Pages artifact includes the favicon\n'
else
  fail=$((fail + 1))
  printf 'FAIL  Pages artifact includes the favicon\n' >&2
fi
if grep -Fq 'cp site/robots.txt _site/robots.txt' "$WORKFLOW_FILE"; then
  pass=$((pass + 1))
  printf 'PASS  Pages artifact includes robots.txt\n'
else
  fail=$((fail + 1))
  printf 'FAIL  Pages artifact includes robots.txt\n' >&2
fi
if grep -Fq 'User-agent: *' "$ROBOTS_FILE" && grep -Fq 'Allow: /' "$ROBOTS_FILE"; then
  pass=$((pass + 1))
  printf 'PASS  robots.txt permits crawling\n'
else
  fail=$((fail + 1))
  printf 'FAIL  robots.txt permits crawling\n' >&2
fi
if [ -s "$(dirname "$SITE_FILE")/favicon.svg" ]; then
  pass=$((pass + 1))
  printf 'PASS  favicon asset exists\n'
else
  fail=$((fail + 1))
  printf 'FAIL  favicon asset exists\n' >&2
fi
if grep -Fq '&gt;_' "$FAVICON_FILE"; then
  pass=$((pass + 1))
  printf 'PASS  favicon branding uses a terminal prompt\n'
else
  fail=$((fail + 1))
  printf 'FAIL  favicon branding uses a terminal prompt\n' >&2
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
