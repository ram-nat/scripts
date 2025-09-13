#!/bin/bash

app_dir="${HOME}/.local/share/applications"

for file in "$app_dir"/msedge-*; do
  filename=$(basename "$file")
  rest="${filename#msedge-}"
  rest="${rest%%.*}"
  wmclass="msedge-_$rest"
  sed -i "/^StartupWMClass=/c\StartupWMClass=$wmclass" "$file"
done
