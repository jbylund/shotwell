#!/bin/bash
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Runs inside the shotwell-bench image (called by run.sh). One benchmark run:
#
#   run-in-container.sh BUILD CORPUS_SET MODE OUTPUT_PREFIX
#
# 1. lower bound T_read: evict the corpus from the page cache, then cat it
# 2. the import: evict again, start a headless compositor and a D-Bus session, run
#    "shotwell --benchmark-import" with a fresh data directory and library
# 3. lower bound T_decode: dcraw_emu on each distinct sample, scaled to the corpus
# 4. merge everything into OUTPUT_PREFIX.json
set -euo pipefail

build="$1"
set_name="$2"
mode="$3"
out="$4"

shotwell="/builds/$build/build/src/shotwell"
set_dir="/corpus/sets/$set_name"
photos="$set_dir/photos"
[ -x "$shotwell" ] || { echo "no build at $shotwell (run build.sh $build ...)" >&2; exit 2; }
[ -d "$photos" ] || { echo "no corpus at $photos (run make-corpus.sh)" >&2; exit 2; }

now() { date +%s.%N; }
elapsed() { python3 -c "import sys; print('%.3f' % (float(sys.argv[2]) - float(sys.argv[1])))" "$1" "$2"; }
evict() { python3 -I /bench/evict.py "$@"; }
io_stat() { cat /sys/fs/cgroup/io.stat 2>/dev/null | tr '\n' ';'; }
cpu_usec() { awk '/^usage_usec/ {print $2}' /sys/fs/cgroup/cpu.stat 2>/dev/null || echo 0; }

run_dir="$(mktemp -d /work/run.XXXXXX)"
cleanup() {
    [ -n "${weston_pid:-}" ] && kill "$weston_pid" 2>/dev/null || true
    if [ "${KEEP_RUN_DIR:-0}" != 1 ]; then rm -rf "$run_dir"; else echo "kept $run_dir" >&2; fi
}
trap cleanup EXIT

export HOME="$run_dir/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_RUNTIME_DIR="$run_dir/runtime"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
data_dir="$run_dir/data"

# Settings live in memory, unless a default RAW developer is asked for (RAW_DEVELOPER: CAMERA,
# EMBEDDED or SHOTWELL); then they are in a key file in the run directory.
if [ -n "${RAW_DEVELOPER:-}" ]; then
    export GSETTINGS_BACKEND=keyfile
    mkdir -p "$XDG_CONFIG_HOME/glib-2.0/settings"
    printf "[org/gnome/shotwell/preferences/files]\nraw-developer-default='%s'\n" "$RAW_DEVELOPER" \
        > "$XDG_CONFIG_HOME/glib-2.0/settings/keyfile"
else
    export GSETTINGS_BACKEND=memory
fi
export GSK_RENDERER=cairo
export GTK_A11Y=none
export NO_AT_BRIDGE=1

echo "corpus: $(du -sh "$photos" | cut -f1) in $(find "$photos" -type f | wc -l) files; mode $mode; cpus $(nproc)" >&2
echo "io.max: $(cat /sys/fs/cgroup/io.max 2>/dev/null | tr '\n' ' ')" >&2

# --- 1. T_read --------------------------------------------------------------------------------
evict "$photos"
io_before="$(io_stat)"
t0="$(now)"
find "$photos" -type f -print0 | sort -z | xargs -0 cat > /dev/null
t1="$(now)"
t_read="$(elapsed "$t0" "$t1")"
io_after_read="$(io_stat)"
echo "T_read = $t_read s" >&2

# --- 2. the import ----------------------------------------------------------------------------
display_backend="${DISPLAY_BACKEND:-weston}"
if [ "$display_backend" = weston ]; then
    weston --backend=headless --renderer=pixman --socket=wayland-bench --idle-time=0 \
        --width=1920 --height=1080 > "$run_dir/weston.log" 2>&1 &
    weston_pid=$!
    for _ in $(seq 100); do
        [ -S "$XDG_RUNTIME_DIR/wayland-bench" ] && break
        sleep 0.1
    done
    [ -S "$XDG_RUNTIME_DIR/wayland-bench" ] || { cat "$run_dir/weston.log" >&2; echo "weston did not start" >&2; exit 3; }
    export WAYLAND_DISPLAY=wayland-bench
    export GDK_BACKEND=wayland
    launcher=()
else
    export GDK_BACKEND=x11
    launcher=(xvfb-run -a -s "-screen 0 1920x1080x24")
fi

evict "$photos"
io_before_import="$(io_stat)"
cpu_before="$(cpu_usec)"
t0="$(now)"
set +e
"${launcher[@]}" dbus-run-session -- "$shotwell" --datadir="$data_dir" --no-runtime-monitoring \
    --no-startup-progress --benchmark-import="$photos" > "$out.shotwell.json" 2> "$out.stderr.log"
status=$?
set -e
t1="$(now)"
cpu_after="$(cpu_usec)"
io_after_import="$(io_stat)"
t_process="$(elapsed "$t0" "$t1")"
cp "$XDG_CACHE_HOME/shotwell/shotwell.log" "$out.shotwell.log" 2>/dev/null || true
echo "shotwell exit status $status, process time $t_process s" >&2

# --- 3. T_decode ------------------------------------------------------------------------------
# Every corpus file is a copy of a sample, so decode each sample once and scale by the number
# of copies (index.tsv: copy path, sample name). The dcraw_emu options match
# GRaw.Processor.configure_for_rgb_display (PPG, camera+auto WB, sRGB, 8 bit, clip, no auto bright).
decode_json="$run_dir/decode.json"
if [ "${LOWER_BOUND_DECODE:-1}" = 1 ]; then
    python3 -I /bench/decode-bound.py "$set_dir" > "$decode_json"
else
    echo '{}' > "$decode_json"
fi

# --- 4. merge ---------------------------------------------------------------------------------
python3 -I /bench/merge-result.py \
    --shotwell "$out.shotwell.json" --decode "$decode_json" --status "$status" \
    --mode "$mode" --build "$build" --set "$set_name" --set-dir "$set_dir" \
    --t-read "$t_read" --t-process "$t_process" \
    --cpu-usec "$cpu_before" "$cpu_after" \
    --io-stat-read "$io_before" "$io_after_read" \
    --io-stat-import "$io_before_import" "$io_after_import" \
    --io-max "$(cat /sys/fs/cgroup/io.max 2>/dev/null | tr '\n' ';')" \
    --memory-max "$(cat /sys/fs/cgroup/memory.max 2>/dev/null)" \
    > "$out.json"
cat "$out.json"
exit "$status"
