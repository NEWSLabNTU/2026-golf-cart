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

# play_launch cannot record any of this: it reads NVML, and NVML does not exist
# on Jetson, so every gpu_* column it has ever written is empty. Run this beside
# a capture and join on the timestamp column.
#
# Jetson GPU load, clock, power rails and temperatures to CSV
gpu interval="2" out="-":
    ./scripts/profiling/jetson_gpu_sampler.py -i {{interval}} -o {{out}}

# Live per-thread CPU, sorted -- the quick look before reaching for perf
threads:
    top -H -b -n2 -d 2 | awk '/PID/{f++} f==2' | head -30
