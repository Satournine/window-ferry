#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${FERRY_BUILD_ROOT:-$project_root/Build}"
output_root="${1:-$project_root}"
signing_identity="${FERRY_SIGN_IDENTITY:--}"
mkdir -p "$build_root" "$output_root"
export CLANG_MODULE_CACHE_PATH="$build_root/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/swift-cache"
swift build --package-path "$project_root" --scratch-path "$build_root" --cache-path "$build_root/package-cache" ${=FERRY_SWIFTPM_FLAGS:-} -c release
bin_path="$(swift build --package-path "$project_root" --scratch-path "$build_root" --cache-path "$build_root/package-cache" ${=FERRY_SWIFTPM_FLAGS:-} -c release --show-bin-path)"
app_path="$output_root/Window Ferry.app"
record_inputs() {
    shasum -a 256 "$bin_path/WindowFerry" "$project_root/Resources/Info.plist" "$project_root/Resources/AppIcon.icns"
    print -r -- "$signing_identity"
    print -r -- "$app_path"
    shasum -a 256 "$app_path/Contents/MacOS/WindowFerry"
}
if [[ -f "$app_path/Contents/MacOS/WindowFerry" && -f "$app_path/Contents/Info.plist" ]] \
    && record_inputs > "$build_root/CurrentApp.txt" \
    && cmp -s "$build_root/CurrentApp.txt" "$build_root/PackagedApp.txt" \
    && cmp -s "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist" \
    && [[ "$signing_identity" == "-" ]] \
    && codesign --verify --strict "$app_path" 2>/dev/null; then
    print "App already matches this build; keeping its existing signature: $app_path"
    exit 0
fi
staging_root="$(mktemp -d "$build_root/Bundle.XXXXXX")"
trap 'rm -rf -- "$staging_root"' EXIT
staging_app="$staging_root/Window Ferry.app"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
cp "$bin_path/WindowFerry" "$staging_app/Contents/MacOS/WindowFerry"
cp "$project_root/Resources/Info.plist" "$staging_app/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$staging_app/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --sign "$signing_identity" --identifier io.github.satournine.WindowFerry "$staging_app"
codesign --verify --strict "$staging_app"
if [[ -e "$app_path" ]]; then
    previous_root="$(mktemp -d "$build_root/PreviousApp.XXXXXX")"
    mv "$app_path" "$previous_root/Window Ferry.app"
    print "Previous app preserved in $previous_root"
fi
mv "$staging_app" "$app_path"
codesign --verify --strict "$app_path"
record_inputs > "$build_root/PackagedApp.txt"
print "Built $app_path"
if [[ "$signing_identity" == "-" ]]; then
    print "Local ad-hoc signature: after a code change, re-add this exact app in Accessibility settings."
    print "An existing enabled switch can refer to an older build. No macOS permissions were changed."
fi
