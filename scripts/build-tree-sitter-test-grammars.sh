#!/usr/bin/env bash
set -euo pipefail

out_dir="${1:-test/fixtures/tree-sitter}"
extension="${RLM_SHARED_OBJECT_EXTENSION:-$(swipl -q -g 'current_prolog_flag(shared_object_extension,E),write(E),halt.')}"
read -r -a tree_sitter_cflags <<<"$(pkg-config --cflags tree-sitter)"
mkdir -p "$out_dir"

find_parser() {
  local language="$1"
  find "/usr/src/tree-sitter/${language}" \
    -type f \
    -path '*/parser/src/parser.c' \
    -print \
    -quit
}

compile_grammar() {
  local language="$1"
  local parser
  local source_dir
  local output="${out_dir}/${language}.${extension}"
  local -a sources
  local compiler="${CC:-cc}"

  parser="$(find_parser "$language")"
  if [[ -z "$parser" ]]; then
    echo "missing packaged Tree-sitter parser source for ${language}" >&2
    return 1
  fi

  source_dir="$(dirname "$parser")"
  sources=("$parser")
  if [[ -f "${source_dir}/scanner.c" ]]; then
    sources+=("${source_dir}/scanner.c")
  fi
  if [[ -f "${source_dir}/scanner.cc" ]]; then
    sources+=("${source_dir}/scanner.cc")
    compiler="${CXX:-c++}"
  fi

  "$compiler" \
    -shared \
    -fPIC \
    -O2 \
    "${tree_sitter_cflags[@]}" \
    -o "$output" \
    "${sources[@]}"

  echo "built ${language} grammar: ${output}"
}

compile_incompatible_c_grammar() {
  local parser
  local source_dir
  local temp_dir
  local output="${out_dir}/c-incompatible.${extension}"
  local -a sources

  parser="$(find_parser c)"
  if [[ -z "$parser" ]]; then
    echo "missing packaged Tree-sitter C parser source" >&2
    return 1
  fi

  source_dir="$(dirname "$parser")"
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  sed -E \
    's/^#define LANGUAGE_VERSION[[:space:]]+[0-9]+/#define LANGUAGE_VERSION 999/' \
    "$parser" > "${temp_dir}/parser.c"
  if ! grep -q '^#define LANGUAGE_VERSION 999$' "${temp_dir}/parser.c"; then
    echo "could not rewrite generated C grammar ABI fixture" >&2
    return 1
  fi

  sources=("${temp_dir}/parser.c")
  if [[ -f "${source_dir}/scanner.c" ]]; then
    cp "${source_dir}/scanner.c" "${temp_dir}/scanner.c"
    sources+=("${temp_dir}/scanner.c")
  fi

  "${CC:-cc}" \
    -shared \
    -fPIC \
    -O2 \
    "${tree_sitter_cflags[@]}" \
    -o "$output" \
    "${sources[@]}"

  rm -rf "$temp_dir"
  trap - RETURN
  echo "built incompatible ABI grammar fixture: ${output}"
}

compile_grammar c
compile_grammar lua
compile_grammar query
compile_incompatible_c_grammar
