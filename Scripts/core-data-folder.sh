#!/bin/bash
# Shared, read-only data-folder selection for the core install/preflight scripts.
# Call oe_core_data_folder [explicit-folder]; the resolved root is printed.

oe_core_data_folder() {
  local explicit_folder="${1:-}" data_folder="" expected_identifier=""
  local path_present=0 identifier_present=0 bookmark_present=0
  local marker identifier version

  if [ -n "$explicit_folder" ]; then
    data_folder="$explicit_folder"
  else
    if data_folder=$(defaults read org.openemu.OpenEmu OEDataFolderPath 2>/dev/null); then
      path_present=1
    fi
    if expected_identifier=$(defaults read org.openemu.OpenEmu OEDataFolderIdentifier 2>/dev/null); then
      identifier_present=1
    fi
    if defaults read org.openemu.OpenEmu OEDataFolderBookmark >/dev/null 2>&1; then
      bookmark_present=1
    fi

    if [ "$path_present" -eq 0 ] && [ "$identifier_present" -eq 0 ] && [ "$bookmark_present" -eq 0 ]; then
      # Compatibility with OpenEmu builds that predate selectable data folders.
      printf '%s\n' "$HOME/Library/Application Support/OpenEmu"
      return 0
    fi
    if [ "$path_present" -ne 1 ] || [ "$identifier_present" -ne 1 ] || [ -z "$data_folder" ]; then
      echo "error: OpenEmu's remembered data folder is incomplete. Launch OpenEmu to locate it, or use --data-folder." >&2
      return 2
    fi
  fi

  if [ ! -d "$data_folder" ]; then
    echo "error: OpenEmu data folder does not exist or is not a directory: $data_folder" >&2
    echo "       Connect its disk or use --data-folder with an existing OpenEmu data folder." >&2
    return 2
  fi
  data_folder=$(cd "$data_folder" && pwd -P) || return 2
  if [ "$data_folder" = / ]; then
    echo "error: the filesystem root cannot be an OpenEmu data folder." >&2
    return 2
  fi

  marker="$data_folder/.openemu-data-folder.plist"
  if [ ! -f "$marker" ] || [ -L "$marker" ]; then
    echo "error: not an identified OpenEmu data folder: $data_folder" >&2
    echo "       Select this folder in OpenEmu first; no data was installed." >&2
    return 2
  fi
  version=$(/usr/libexec/PlistBuddy -c 'Print :version' "$marker" 2>/dev/null) || version=""
  identifier=$(/usr/libexec/PlistBuddy -c 'Print :identifier' "$marker" 2>/dev/null) || identifier=""
  if [ "$version" != 1 ] || ! [[ "$identifier" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "error: the OpenEmu data-folder marker is invalid: $marker" >&2
    return 2
  fi
  if [ -z "$explicit_folder" ] && [ "$(printf '%s' "$identifier" | tr '[:lower:]' '[:upper:]')" != "$(printf '%s' "$expected_identifier" | tr '[:lower:]' '[:upper:]')" ]; then
    echo "error: the remembered path points to a different OpenEmu data folder. Launch OpenEmu to locate the original folder." >&2
    return 2
  fi
  if [ -L "$data_folder/Cores" ] || { [ -e "$data_folder/Cores" ] && [ ! -d "$data_folder/Cores" ]; }; then
    echo "error: the data folder's Cores entry must be a directory, not a file or symbolic link." >&2
    return 2
  fi
  printf '%s\n' "$data_folder"
}
