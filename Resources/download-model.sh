#!/usr/bin/env bash
# Downloads KokoroTTS model weights to ~/Library/Application Support/NetNewsWire/TTS/
# so the app can find them at runtime.

set -euo pipefail

DEST_DIR="$HOME/Library/Application Support/NetNewsWire/TTS"
mkdir -p "$DEST_DIR"

BASE_URL="https://github.com/hashb/KokoroTTS/releases/download/v1.2.1"

FILENAMES=(
    "kokoro-v1_0.safetensors"
    "voices.npz"
)

HASHES=(
    "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
    "56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f"
)

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: SHA-256 mismatch for $file"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        return 1
    fi
    echo "  verified: $file"
}

echo "Downloading models to: $DEST_DIR"

for i in "${!FILENAMES[@]}"; do
    filename="${FILENAMES[$i]}"
    expected_hash="${HASHES[$i]}"
    dest="$DEST_DIR/$filename"

    if [[ -f "$dest" ]]; then
        echo "Checking existing $filename..."
        if verify_sha256 "$dest" "$expected_hash"; then
            continue
        else
            echo "Re-downloading $filename..."
            rm -f "$dest"
        fi
    else
        echo "Downloading $filename..."
    fi

    curl -fL --progress-bar -o "$dest" "$BASE_URL/$filename"
    verify_sha256 "$dest" "$expected_hash"
done

echo "Done. Model files are in: $DEST_DIR"
