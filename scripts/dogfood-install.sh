#!/bin/bash
set -euo pipefail

APP_NAME="Casper"
PROJECT_PATH="Casper.xcodeproj"
SCHEME_NAME="Casper"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.deriveddata}"
DEFAULT_SOURCE_PACKAGES_PATH="$HOME/Library/Developer/Xcode/DerivedData/Casper-hfmhqrbjcvzfnwfbhqzxsdkhcbxk/SourcePackages"
CLONED_SOURCE_PACKAGES_DIR_PATH="${CLONED_SOURCE_PACKAGES_DIR_PATH:-$DEFAULT_SOURCE_PACKAGES_PATH}"
DESTINATION="${DESTINATION:-platform=macOS}"
APP_BUNDLE_ID="com.rooshi.casper"
DEFAULT_APP_PATH="/Applications/${APP_NAME}.app"
HOME_APP_PATH="$HOME/Applications/${APP_NAME}.app"
APP_INSTALL_PATH="${DOGFOOD_APP_PATH:-}"
LAUNCH_AFTER_INSTALL="${LAUNCH_AFTER_INSTALL:-1}"
QUIET_INSTALL_ON_LAUNCH="${QUIET_INSTALL_ON_LAUNCH:-1}"
INCLUDE_SLOW_TESTS="${DOGFOOD_INCLUDE_SLOW_TESTS:-0}"
SKIP_DEFAULT_TEST_FILTERS="${DOGFOOD_SKIP_DEFAULT_TEST_FILTERS:-0}"
VERBOSE_XCODEBUILD="${DOGFOOD_VERBOSE_XCODEBUILD:-0}"
SKIP_BRAND_ASSET_GENERATION="${DOGFOOD_SKIP_BRAND_ASSETS:-0}"

log_step() {
  echo ""
  echo "[$(/bin/date '+%H:%M:%S')] ==> $1"
}

log_info() {
  echo "    $1"
}

print_log_excerpt() {
  local log_path="$1"
  local line_count="${2:-40}"

  if [ -f "$log_path" ]; then
    echo ""
    echo "---- recent log excerpt: $log_path ----"
    /usr/bin/tail -n "$line_count" "$log_path"
    echo "---- end excerpt ----"
  fi
}

run_xcodebuild_step() {
  local label="$1"
  local log_path="$2"
  shift 2

  log_step "$label"

  if [ "$VERBOSE_XCODEBUILD" = "1" ]; then
    xcodebuild "$@" | /usr/bin/tee "$log_path"
    return "${PIPESTATUS[0]}"
  fi

  if xcodebuild "$@" >"$log_path" 2>&1; then
    log_info "Completed successfully. Full log: $log_path"
    /usr/bin/grep -E '^\*\* (TEST|BUILD) SUCCEEDED \*\*' "$log_path" | /usr/bin/tail -n 1 || true
    return 0
  fi

  log_info "Failed. Full log: $log_path"
  print_log_excerpt "$log_path" 60
  return 1
}

generate_brand_assets() {
  if [ "$SKIP_BRAND_ASSET_GENERATION" = "1" ]; then
    log_step "Skipping brand asset generation because DOGFOOD_SKIP_BRAND_ASSETS=1"
    return 0
  fi

  if [ ! -f "scripts/generate_brand_assets.swift" ]; then
    return 0
  fi

  if [ ! -f "casper-logo.png" ] || [ ! -f "casper-plain.png" ]; then
    log_step "Skipping brand asset generation because source logo files are missing"
    return 0
  fi

  log_step "Refreshing generated brand assets..."
  /usr/bin/swift scripts/generate_brand_assets.swift
}

resolve_install_path() {
  local registered_app_path=""

  if [ -n "$APP_INSTALL_PATH" ]; then
    echo "$APP_INSTALL_PATH"
    return 0
  fi

  # Reuse an existing install location first so macOS TCC grants stay attached
  # to the same app path across dogfood reinstalls.
  registered_app_path="$(/usr/bin/osascript -e "POSIX path of (path to application id \"$APP_BUNDLE_ID\")" 2>/dev/null || true)"
  if [ -n "$registered_app_path" ] && [ -d "$registered_app_path" ]; then
    echo "$registered_app_path"
    return 0
  fi

  if [ -d "$DEFAULT_APP_PATH" ]; then
    echo "$DEFAULT_APP_PATH"
    return 0
  fi

  if [ -d "$HOME_APP_PATH" ]; then
    echo "$HOME_APP_PATH"
    return 0
  fi

  echo "$DEFAULT_APP_PATH"
}

APP_INSTALL_PATH="$(resolve_install_path)"

PRODUCT_APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
INSTALL_PARENT_DIR="$(dirname "$APP_INSTALL_PATH")"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/casper-dogfood.XXXXXX")"
STAGED_APP_PATH="${STAGING_DIR}/${APP_NAME}.app"
TEST_LOG_PATH="${STAGING_DIR}/xcodebuild-test.log"
BUILD_LOG_PATH="${STAGING_DIR}/xcodebuild-build.log"
TEST_ARGS=("$@")

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [ "$SKIP_DEFAULT_TEST_FILTERS" != "1" ]; then
  has_explicit_test_selection=0
  for arg in "${TEST_ARGS[@]}"; do
    case "$arg" in
      -only-testing:*|-skip-testing:*|-testPlan)
        has_explicit_test_selection=1
        ;;
    esac
  done

  if [ "$has_explicit_test_selection" = "0" ] && [ "$INCLUDE_SLOW_TESTS" != "1" ]; then
    TEST_ARGS+=("-skip-testing:CasperTests/CleanupPromptEvalTests")
  fi
fi

generate_brand_assets

run_xcodebuild_step "Running tests before dogfood install..." "$TEST_LOG_PATH" test \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH" \
  -disableAutomaticPackageResolution \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  "${TEST_ARGS[@]}"

run_xcodebuild_step "Building signed app bundle for install..." "$BUILD_LOG_PATH" build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH" \
  -disableAutomaticPackageResolution \
  -skipMacroValidation

if [ ! -d "$PRODUCT_APP_PATH" ]; then
  echo "ERROR: Built app not found at $PRODUCT_APP_PATH"
  exit 1
fi

log_step "Staging fresh app bundle..."
/usr/bin/ditto "$PRODUCT_APP_PATH" "$STAGED_APP_PATH"

log_step "Asking any running Casper instance to quit..."
/usr/bin/osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  if /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    sleep 0.5
  else
    break
  fi
done

log_step "Installing app to $APP_INSTALL_PATH"
/bin/mkdir -p "$INSTALL_PARENT_DIR"
/bin/rm -rf "$APP_INSTALL_PATH"
/bin/mv "$STAGED_APP_PATH" "$APP_INSTALL_PATH"
/usr/bin/xattr -dr com.apple.quarantine "$APP_INSTALL_PATH" >/dev/null 2>&1 || true

if [ "$LAUNCH_AFTER_INSTALL" = "1" ]; then
  log_step "Launching installed app..."
  if [ "$QUIET_INSTALL_ON_LAUNCH" = "1" ]; then
    /usr/bin/open "$APP_INSTALL_PATH" --args --quiet-install
  else
    /usr/bin/open "$APP_INSTALL_PATH"
  fi
else
  log_step "Skipping launch because LAUNCH_AFTER_INSTALL=$LAUNCH_AFTER_INSTALL"
fi

echo ""
echo "Dogfood install complete."
echo "Installed app: $APP_INSTALL_PATH"
