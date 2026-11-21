#!/bin/zsh
# Builds CraftPanel for Windows from a Mac (or Linux): self-contained single-file .exe for x64 and arm64, zipped,
# with SHA-256 checksums. The first online run may download Windows runtime packs from NuGet (~70 MB each).
set -euo pipefail
ROOT=${0:A:h:h}
export PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
VER=$(grep -o '<Version>[^<]*' "$ROOT/Directory.Build.props" | cut -d'>' -f2)
OUT="${CRAFTPANEL_BUILD_OUT:-$ROOT/dist}"; mkdir -p "$OUT"
RESTORE_ARGS=()
if [[ "${CRAFTPANEL_OFFLINE:-0}" == "1" ]]; then RESTORE_ARGS=(--no-restore); fi
STAGES=()
cleanup() {
  local stage
  for stage in "${STAGES[@]}"; do
    [[ -n "$stage" && -d "$stage" ]] && rm -rf "$stage"
  done
}
trap cleanup EXIT

echo "== tests"
dotnet run "${RESTORE_ARGS[@]}" --project "$ROOT/tests/CraftPanel.Tests"

for RID in win-x64 win-arm64; do
  echo "== publish $RID"
  if [[ "${CRAFTPANEL_OFFLINE:-0}" == "1" ]]; then
    # Use only the local NuGet cache as a package source; never contact a feed.
    dotnet restore "$ROOT/src/CraftPanel.App" -r "$RID" --source "$HOME/.nuget/packages" -v q
  fi
  STAGE=$(mktemp -d "$OUT/.stage-$RID.XXXXXX")
  STAGES+=("$STAGE")
  dotnet publish "${RESTORE_ARGS[@]}" "$ROOT/src/CraftPanel.App" -c Release -r "$RID" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=false \
    -p:DebugType=none -p:DebugSymbols=false -o "$STAGE" -v q
  rm -f "$STAGE"/*.pdb
  cp "$ROOT/docs/README-windows.txt" "$STAGE/README.txt"
  ZIP="$OUT/CraftPanel-$VER-$RID.zip"; rm -f "$ZIP"
  (cd "$STAGE" && zip -q -9 "$ZIP" *)
  echo "-> $ZIP ($(du -h "$ZIP" | cut -f1))"
done
(cd "$OUT" && shasum -a 256 CraftPanel-$VER-*.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
