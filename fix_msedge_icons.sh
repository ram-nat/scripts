#!/bin/bash

app_dir="${HOME}/.local/share/applications"
app_backup_dir="${HOME}/msedge-apps"

if [ ! -d "${app_backup_dir}" ]; then
  echo "Creating ${app_backup_dir}"
  mkdir -p "${app_backup_dir}"
fi

for file in "$app_dir"/msedge-*; do
  cp "${file}" "${app_backup_dir}/"
  filename=$(basename "$file")
  rest="${filename#msedge-}"
  rest="${rest%%.*}"
  new_filename="msedge-_${rest}.desktop"
  mv "${file}" "$app_dir/${new_filename}"
  #wmclass="msedge-_$rest"
  #sed -i "/^StartupWMClass=/c\StartupWMClass=$wmclass" "$file"
done
