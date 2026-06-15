#!/usr/bin/env bash
# Run a task script inside the Termux pacman Docker image.
set -Eeuo pipefail

image="${TERMUX_IMAGE:-termux/termux-docker-pacman}"
workspace="${GITHUB_WORKSPACE:-$PWD}"
packages=(termux-exec "$@")
package_file="$(mktemp)"
sync_file="$(mktemp)"
task_script="$(mktemp)"
output_dir="$(mktemp -d)"

cleanup() {
    rm -f "${package_file:-}"
    rm -f "${sync_file:-}"
    rm -f "${task_script:-}"
    rm -rf "${output_dir:-}" 2>/dev/null || true
}
trap cleanup EXIT

: > "$package_file"
if (( ${#packages[@]} > 0 )); then
    printf '%s\n' "${packages[@]}" > "$package_file"
fi
chmod 0644 "$package_file"

: > "$sync_file"
if [[ -n "${TERMUX_SYNC_BACK:-}" ]]; then
    read -ra sync_paths <<< "$TERMUX_SYNC_BACK"
    printf '%s\n' "${sync_paths[@]}" > "$sync_file"
fi
chmod 0644 "$sync_file"

cat > "$task_script"
chmod 0644 "$task_script"
chmod 0777 "$output_dir"

docker run --rm -i \
    -v "$workspace:/workspace-src:ro" \
    -v "$output_dir:/workspace-output" \
    -v "$package_file:/tmp/termux-packages:ro" \
    -v "$sync_file:/tmp/termux-sync-back:ro" \
    -v "$task_script:/tmp/termux-task.sh:ro" \
    "$image" \
    bash -lc '
        set -Eeuo pipefail
        export TERMUX_VERSION="${TERMUX_VERSION:-docker}"

        pacman -Syu --noconfirm
        if [ -s /tmp/termux-packages ]; then
            TERMUX_PACKAGES="$(tr "\n" " " < /tmp/termux-packages)"
            # shellcheck disable=SC2086
            pacman -S --noconfirm --needed $TERMUX_PACKAGES
        fi

        termux_exec_preload="${PREFIX:-/data/data/com.termux/files/usr}/lib/libtermux-exec-ld-preload.so"
        if [ -r "$termux_exec_preload" ]; then
            export LD_PRELOAD="$termux_exec_preload"
        fi

        workdir="${PREFIX:-/data/data/com.termux/files/usr}/tmp/ci-workspace"
        rm -rf "$workdir"
        mkdir -p "$workdir"
        (cd /workspace-src && tar --exclude="./.git" --exclude="./bin" --exclude="./staging" -cf - .) |
            (cd "$workdir" && tar -xf -)
        chmod -R u+rwX "$workdir"
        cd "$workdir"

        bash /tmp/termux-task.sh

        if [ -s /tmp/termux-sync-back ]; then
            while IFS= read -r path; do
                [ -n "$path" ] || continue
                if [ ! -e "$path" ]; then
                    echo "Expected sync-back path was not created: $path" >&2
                    exit 1
                fi

                mkdir -p "/workspace-output/$(dirname "$path")"
                cp -a "$path" "/workspace-output/$path"
            done < /tmp/termux-sync-back
        fi
    '

if [[ -s "$sync_file" ]]; then
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if [[ ! -e "$output_dir/$path" ]]; then
            echo "Expected sync-back path was not created: $path" >&2
            exit 1
        fi

        mkdir -p "$workspace/$(dirname "$path")"
        cp -a "$output_dir/$path" "$workspace/$path"
    done < "$sync_file"
fi
