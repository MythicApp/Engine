#!/bin/zsh

# Define the fixed array of GStreamer libraries
GSTREAMER_LIBS=(
    "libgstapplemedia"
    "libgstasf"
    "libgstaudioconvert"
    "libgstaudioparsers"
    "libgstaudioresample"
    "libgstavi"
    "libgstcoreelements"
    "libgstdebug"
    "libgstdeinterlace"
    "libgstid3demux"
    "libgstisomp4"
    "libgstlibav"
    "libgstopengl"
    "libgstplayback"
    "libgsttypefindfunctions"
    "libgstvideoconvertscale"
    "libgstvideofilter"
    "libgstvideoparsersbad"
    "libgstwavparse"
)

# Define the fixed array of non-GStreamer libraries
LIBS=(
    "libMoltenVK"
    "libSDL2-2.0.0"
)

# Global array to store all discovered dylibs, with unique entries only
typeset -aU all_dylibs
# Queue for iterative processing
typeset -a queue

# Function to resolve @rpath dependencies by searching in Homebrew's lib directory
resolve_rpath() {
  local ref_dylib="$1"

  # Extract the actual filename after @rpath
  local dylib_name="${ref_dylib#@rpath/}"

  # Get Homebrew's lib directory
  local brew_lib_dir="$(brew --prefix)/lib"

  # Check if the dylib exists in Homebrew's lib directory
  local resolved_path="${brew_lib_dir}/${dylib_name}"
  if [[ -f "$resolved_path" ]]; then
    echo "$resolved_path"
  else
    # If not found, return empty string to avoid trying to open unresolved @rpath
    echo ""
  fi
}

# Function to find all dylib dependencies iteratively
find_dylib_dependencies() {
  local dylib="$1"
  
  # Initialize the queue with the initial dylib
  queue+=("$dylib")

  # Process each dylib in the queue
  while [[ ${#queue[@]} -gt 0 ]]; do
    local current_dylib="${queue[1]}"
    queue=("${queue[@]:1}") # Remove the first element from the queue

    # Get all referenced dylibs using otool
    local referenced_dylibs=($(otool -L "$current_dylib" | awk '/^\t/ {print $1}' | grep '\.dylib'))

    for ref_dylib in $referenced_dylibs; do
      # Skip /usr/lib dylibs
      if [[ "$ref_dylib" == /usr/lib/* ]]; then
        continue
      fi

      # Resolve @rpath references by looking in Homebrew's lib directory
      if [[ "$ref_dylib" == @rpath/* ]]; then
        ref_dylib=$(resolve_rpath "$ref_dylib")
        # Skip if @rpath couldn't be resolved
        if [[ -z "$ref_dylib" ]]; then
          echo "Warning: Could not resolve @rpath for $current_dylib" >&2
          continue
        fi
      fi

      # If the dylib is not already in the global array, add it to the array and the queue
      if [[ ! " ${all_dylibs[*]} " =~ " $ref_dylib " ]]; then
        all_dylibs+=("$ref_dylib")
        queue+=("$ref_dylib")
      fi
    done
  done
}

# Function to fix up brew dylib LCs
update_dylib_paths() {
  local dylib_file="$1"
  local path_prefix="$2"
  echo "Processing $dylib_file..."

  otool -L "$dylib_file" | grep -v "$dylib_file" | awk '{print $1}' | while read -r dylib_path; do
    if [[ $dylib_path != /usr/lib* && $dylib_path != /System/* ]]; then
      # For paths not excluded, replace the prefix with @loader_path/
      local lib_name="${dylib_path##*/}"
      local new_dylib_path="${path_prefix}${lib_name}"
      echo "Updating $dylib_path to $new_dylib_path"
      # Use install_name_tool to change the path
      install_name_tool -change "$dylib_path" "$new_dylib_path" "$dylib_file"
      codesign -fs- "$dylib_file"
    fi
  done
}

# Function to copy the libraries into the appropriate directories
copy_libraries() {
  local lib="$1"
  local gstreamer_dir="Libraries/Wine/lib/gstreamer-1.0"
  local lib_dir="Libraries/Wine/lib"

  mkdir -p "$gstreamer_dir" "$lib_dir"

  # Check if the library is a GStreamer library by checking its path
  if [[ "$lib" == *"/gstreamer-1.0/"* ]]; then
    echo "Copying GStreamer library: $lib -> $gstreamer_dir"
    cp "$lib" "$gstreamer_dir"
    update_dylib_paths "$gstreamer_dir/$(basename "$lib")" "@loader_path/../"
  else
    echo "Copying non-GStreamer library: $lib -> $lib_dir"
    cp "$lib" "$lib_dir"
    update_dylib_paths "$lib_dir/$(basename "$lib")" "@loader_path/"
  fi
}

# Get the Homebrew prefix for gstreamer
GSTREAMER_PREFIX=$(brew --prefix gstreamer)

# Get generic Homebrew prefix
PREFIX=$(brew --prefix)

# Iterate over the fixed GStreamer libraries array
for lib in "${GSTREAMER_LIBS[@]}"; do
  dylib_path="${GSTREAMER_PREFIX}/lib/gstreamer-1.0/${lib}.dylib"
  
  if [ -f "$dylib_path" ]; then
    echo "Checking dependencies for: $dylib_path"
    find_dylib_dependencies "$dylib_path"
  else
    echo "Error: $dylib_path not found"
  fi
done

# Iterate over the fixed non-GStreamer libraries array
for lib in "${LIBS[@]}"; do
  dylib_path="${PREFIX}/lib/${lib}.dylib"
  
  if [ -f "$dylib_path" ]; then
    echo "Checking dependencies for: $dylib_path"
    find_dylib_dependencies "$dylib_path"
  else
    echo "Error: $dylib_path not found"
  fi
done

# Copy all found dylibs to the appropriate directories
for dylib in "${all_dylibs[@]}"; do
  copy_libraries "$dylib"
done

# Copy GStreamer include files
cp -a "$(brew --prefix gstreamer)/lib/gstreamer-1.0/include" Libraries/Wine/lib/gstreamer-1.0

# Update specific GStreamer shared object
update_dylib_paths Libraries/Wine/lib/wine/x86_64-unix/winegstreamer.so "@rpath/"