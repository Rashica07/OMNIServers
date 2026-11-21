#!/bin/zsh
# Runs the Windows edition's UI natively on a Mac, for looking around and testing. Uses its own data folder
# ("~/Library/Application Support/CraftPanel Windows Edition" and ~/.local/share/...) so it never touches the SwiftUI Mac app's
# servers, settings or PIN lock.
# Set CRAFTPANEL_DATA=/some/folder to keep a throwaway copy instead.
export PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
cd "${0:A:h:h}" && exec dotnet run --project src/CraftPanel.App -c Release
