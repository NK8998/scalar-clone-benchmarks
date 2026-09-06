# Environment

Results are **only** comparable within a single machine. Fill this in before
you run, and publish it alongside your numbers.

## Why this file exists

Hardware variance between boxes is larger than most of the effects we are
measuring. A second devbox indexed the **same** 6.83 GB history pack **3.18x
slower** than the first — 724 s vs 228 s — with identical software and identical
input. A local microbenchmark on the same two machines showed 50.5 s vs 113.3 s
for the same operation.

So a number from another machine is not a baseline for yours. **Always run the
control cell on your own box, in the same session as the treatment cell.** That
is what cells A and B are for.

---

## Reference box (where the prior results in `results/historical/` were produced)

| | |
|---|---|
| OS | Ubuntu 26.04 LTS |
| Kernel | 6.18.33.2-microsoft-standard-WSL2 |
| Platform | **WSL2** on Windows |
| CPU | AMD EPYC 7763 64-Core Processor |
| Cores | 16 vCPU (8 cores × 2 threads, 1 socket) |
| Arch | x86_64 |
| RAM | 31 GiB |
| Disk | 1007 GB volume, 673 GB free at time of runs |
| Git | `2.55.0.vfs.0.8-midx.2` unpacked to `~/.1js/git/<version>` |
| Endpoint | `https://gitcache.microsoft.engineering/<repositoryId>` |
| `gvfs.postThreads` | 8 |
| `http.sslBackend` | gnutls (release `.deb`) |

Being on WSL2 is worth noting: filesystem and network both traverse an extra
layer, and `drop_caches` behaves differently from bare metal.

---

## Record yours

```bash
{
  echo "date: $(date -Is)"
  echo "host: $(hostname)"
  . /etc/os-release && echo "os: $PRETTY_NAME"
  echo "kernel: $(uname -sr)"
  grep -qi microsoft /proc/version && echo "platform: WSL2" || echo "platform: native"
  echo "cpu: $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')"
  echo "cores: $(nproc)"
  echo "ram: $(free -h | awk '/^Mem:/{print $2}')"
  echo "disk_free: $(df -h . | awk 'NR==2{print $4}')"
  echo "git: $(git --version)"
  echo "exec_path: $(git --exec-path)"
} | tee environment-$(hostname).txt
```

## Network

Throughput to the cache server varies enough by time of day to swamp a single
comparison — clone time has been measured anywhere from **243 s to 804 s**
across otherwise identical configurations. Note roughly when you ran, and
prefer running the A/B pair back to back so both cells see similar conditions.

```bash
# rough sanity check before starting
curl -s -o /dev/null -w 'connect=%{time_connect}s ttfb=%{time_starttransfer}s\n' \
  https://gitcache.microsoft.engineering/
```
