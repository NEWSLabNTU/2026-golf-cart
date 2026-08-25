# CPU / kernel profiling of the running stack
#
# Recipes here run from the REPO ROOT, not from just/ -- same reason as tool.just.
set working-directory := '..'

# List this module's recipes
default:
    @just --list profile

# Rate-differenced snapshot: CPU split, softirq classes, UDP datagram rate, DDS participant census
report seconds="10":
    ./scripts/profiling/kernel_cpu_report.sh {{seconds}}

# System-wide perf profile with resolved kernel symbols (needs sudo)
perf seconds="20":
    ./scripts/profiling/perf_kernel.sh {{seconds}}

# Live per-thread CPU, sorted -- the quick look before reaching for perf
threads:
    top -H -b -n2 -d 2 | awk '/PID/{f++} f==2' | head -30
