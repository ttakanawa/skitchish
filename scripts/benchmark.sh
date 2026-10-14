#!/bin/bash
# Optimized, renderer-only measurements. This never launches Skitchish or creates a window.
set -euo pipefail

benchmark_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
benchmark_repo_dir="$(cd "$benchmark_script_dir/.." && pwd)"
benchmark_output_dir="$benchmark_repo_dir/.build/performance"
mkdir -p "$benchmark_output_dir" "$benchmark_repo_dir/.build/module-cache"

export SKITCHISH_BENCHMARK_COMPILER="$(xcrun swiftc --version) | -O -whole-module-optimization"
export SKITCHISH_BENCHMARK_HARDWARE="$(sysctl -n machdep.cpu.brand_string) | memory bytes: $(sysctl -n hw.memsize)"
xcrun swiftc -O -whole-module-optimization \
    "$benchmark_repo_dir/Skitchish/EditorModel.swift" \
    "$benchmark_repo_dir/Skitchish/MarkupGeometry.swift" \
    "$benchmark_repo_dir/Skitchish/EditorRenderer.swift" \
    "$benchmark_repo_dir/Skitchish/StampLabelStyle.swift" \
    "$benchmark_repo_dir/Skitchish/EditorServiceError.swift" \
    "$benchmark_repo_dir/Skitchish/ExportFormat.swift" \
    "$benchmark_repo_dir/Skitchish/ImageService.swift" \
    "$benchmark_script_dir/RendererBenchmark.swift" \
    -module-cache-path "$benchmark_repo_dir/.build/module-cache" \
    -o "$benchmark_output_dir/renderer-benchmark"

cd "$benchmark_repo_dir"
"$benchmark_output_dir/renderer-benchmark" 2>&1 | tee "$benchmark_output_dir/results.log"
echo "JSON measurements and final-frame PNGs: $benchmark_output_dir"
