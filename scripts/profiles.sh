#!/bin/bash
# Lists Xcode's cached signing profiles for Bike Dash (diagnostics).
source "$(dirname "$0")/lib.sh"

cached_profiles | while IFS= read -r file; do
  printf '%s\n  %s\n' "$(basename "$file")" "$(describe_profile "$file")"
done
