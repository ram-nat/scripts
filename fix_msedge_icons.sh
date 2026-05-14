#!/bin/bash
set -euo pipefail

app_dir="${HOME}/.local/share/applications"
app_backup_dir="${HOME}/msedge-apps"
edge_wrapper="${HOME}/.local/bin/msedge-igpu"
timestamp="$(date +%Y%m%d-%H%M%S)"

if [ ! -d "${app_backup_dir}" ]; then
  echo "Creating ${app_backup_dir}"
  mkdir -p "${app_backup_dir}"
fi

shopt -s nullglob

for file in "$app_dir"/msedge-*.desktop; do
  filename=$(basename "$file")

  if [[ "$filename" == msedge-_* ]]; then
    echo "Skipping already fixed file: $filename"
    continue
  fi

  rest="${filename#msedge-}"
  rest="${rest%.desktop}"
  new_filename="msedge-_${rest}.desktop"
  destination="${app_dir}/${new_filename}"

  if [[ -e "$destination" ]]; then
    echo "Skipping ${filename}: destination already exists: ${new_filename}"
    continue
  fi

  echo "Fixing ${filename}"
  cp -a "${file}" "${app_backup_dir}/${filename}.bak-${timestamp}"
  mv "${file}" "$destination"

  if [[ -x "$edge_wrapper" ]]; then
    perl -0pi -e "s#^Exec=env [^\n]*?/opt/microsoft/msedge/microsoft-edge#Exec=${edge_wrapper}#mg; s#^Exec=/opt/microsoft/msedge/microsoft-edge#Exec=${edge_wrapper}#mg; s#^Exec=/usr/bin/microsoft-edge-stable#Exec=${edge_wrapper}#mg; s#^Exec=microsoft-edge-stable#Exec=${edge_wrapper}#mg" "$destination"
  fi

  #wmclass="msedge-_$rest"
  #sed -i "/^StartupWMClass=/c\StartupWMClass=$wmclass" "$destination"
done
