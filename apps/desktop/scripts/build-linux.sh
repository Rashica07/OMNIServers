#!/bin/zsh
# Builds OMNIServers for Linux: self-contained single-file binary for x64 and arm64, packed as .tar.gz with checksums.
# The first online run may download Linux runtime packs from NuGet.
set -euo pipefail
ROOT=${0:A:h:h}
export PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
VER=$(grep -o '<Version>[^<]*' "$ROOT/Directory.Build.props" | cut -d'>' -f2)
OUT="${CRAFTPANEL_BUILD_OUT:-$ROOT/dist}"; mkdir -p "$OUT"
for RID in linux-x64 linux-arm64; do
  echo "== publish $RID"
  STAGE=$(mktemp -d "$OUT/.stage-$RID.XXXXXX")
  dotnet publish "$ROOT/src/CraftPanel.App" -c Release -r "$RID" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=false \
    -p:DebugType=none -p:DebugSymbols=false -o "$STAGE" -v q
  rm -f "$STAGE"/*.pdb(N)
  mv "$STAGE/CraftPanel" "$STAGE/omniservers"; chmod +x "$STAGE/omniservers"
  cp "$ROOT/../../LICENSE" "$STAGE/LICENSE"
  cp "$ROOT/docs/README-linux.txt" "$STAGE/README.txt"
  TGZ="$OUT/OMNIServers-$VER-$RID.tar.gz"; rm -f "$TGZ"
  tar -C "$STAGE" -czf "$TGZ" .
  rm -rf "$STAGE"
  echo "-> $TGZ ($(du -h "$TGZ" | cut -f1))"
done
(cd "$OUT" && shasum -a 256 OMNIServers-$VER-linux-*.tar.gz > SHA256SUMS-linux.txt && cat SHA256SUMS-linux.txt)
