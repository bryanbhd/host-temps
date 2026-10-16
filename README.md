# host-temps

A btop-style live panel for a Linux homelab server, written in plain bash. It shows what you
check when a box feels hot or slow, on one screen:

- **Temperatures:** CPU (AMD per-die or Intel package/cores), VRMs on ASUS boards, GPUs (NVIDIA
  and AMD, any number), NVMe SSDs and SATA hard drives, each with a colour-graded gauge
- **Load:** CPU load against thread count, memory in use, and per-GPU busy % and VRAM
- **ZFS pools:** health, how full they are, scrub/resilver progress with time left, and errors.
  Non-ZFS Incus pools (btrfs/dir/lvm) show how full they are.
- **Disks:** one row per disk with temperature and read/write MB/s, labelled with its ZFS pool
  and mirror pair (e.g. `sdc · tank pair 1 · IronWolf ·1A2B`, using the drive's real model name)
- **Top 5 processes** by memory and by disk I/O, labelled with their **Incus/LXC container or
  VM**. Disk I/O also shows which storage pool the instance lives on.
- **With sudo:** SMART bad-sector counts, power-on years and health under each hard drive

```
 nas01  2026-10-16 08:00:00  ·  refresh 10s  ·  q quit
╭─ cpu · board  (CPU model) ───────────────────────────────────────────────────╮
│ CPU                                    ■■■■■■■■■■···············       55 °C │
│   core groups 50 · 43                  ■■■■■■■■■················       50 °C │
│ CPU power (VRM) E 41 · W 38            ■■■■■····················       41 °C │
│ CPU busy (of 32 threads)               ■■■······················        6.44 │
│ Memory in use                          ■■■■■■■■■■■··············     38/128G │
╰──────────────────────────────────────────────────────────────────────────────╯
╭─ graphics cards ─────────────────────────────────────────────────────────────╮
│ GPU 1 · GPU model · 0% · 0.8/24G       ■■■■·····················       32 °C │
╰──────────────────────────────────────────────────────────────────────────────╯
╭─ storage pools ──────────────────────────────────────────────────────────────╮
│ tank · 15% full                        ■■■······················    DEGRADED │
│   resilver · 02:14:09 left             ■■■■■■■■■················       38.2% │
│ fast · 3% full                         ·························      ONLINE │
╰──────────────────────────────────────────────────────────────────────────────╯
╭─ disks  (temp · read/write MB/s) ────────────────────────────────────────────╮
│ nvme0 · fast · NVMe SSD                ■■■■········       40 °C      0.0/1.2 │
│ nvme1 · system · NVMe SSD              ■■■■········       42 °C      0.0/0.4 │
│ sda · tank pair 1 · HDD ·1A2B          ■■··········       29 °C      118/0.0 │
│ sde · tank pair 1 · HDD ·9F3C          ■■■·········       31 °C      0.0/121 │
│   unreadable 0 · uncorrectable 0 · remapped 0 · 0.0 yrs on · PASSED          │
╰──────────────────────────────────────────────────────────────────────────────╯
╭─ top 5 · memory  (bar = vs biggest) ─────────────────────────────────────────╮
│ VM · win11                             ■■■■■■■■■■■■■■■■■■■■■■■■■        8.1G │
│ java · elasticsearch                   ■■■■■■■■·················        2.7G │
╰──────────────────────────────────────────────────────────────────────────────╯
```

The real thing is in colour, redraws in place on the terminal's alternate screen, and resizes
with the window. That sample is trimmed and uses made-up host, pool, instance and hardware names; the
real output shows your CPU, GPU and drive models.

## Run it

```bash
curl -fsSLO https://raw.githubusercontent.com/bryanbhd/host-temps/main/host-temps.sh
bash host-temps.sh            # live, refresh every 10 s - q or Ctrl-C to quit
bash host-temps.sh 60         # refresh every 60 s
bash host-temps.sh once       # print once and exit
sudo bash host-temps.sh       # adds SMART counts and per-process disk I/O
```

Read a script before you run it with sudo. This one only reads: it never writes to disks,
pools or containers.

## Requirements

- bash 4+, coreutils, `awk`, `lsblk`, `ps` (any normal distro)
- **Hard-drive temperatures:** the `drivetemp` kernel module. Load it now and at every boot:
  ```bash
  sudo modprobe drivetemp && echo drivetemp | sudo tee /etc/modules-load.d/drivetemp.conf
  ```
- Optional, each panel appears only if the tool is present:
  - `zpool` (ZFS pools, mirror pairs, resilver progress)
  - `nvidia-smi` (NVIDIA GPUs). AMD GPUs are read from the `amdgpu` driver directly.
  - `smartctl` from smartmontools (bad-sector counts, sudo)
  - `incus` + `jq` (container/VM names and pools in the process lists)

## How it works

Nothing is configured: every panel detects what the machine has, and a panel with nothing to
show (no GPU, no ZFS) is left out.


Everything comes from the kernel or the tools above, re-read on each refresh:

| What | Source |
|---|---|
| CPU / VRM / GPU / NVMe / HDD temperatures | `/sys/class/hwmon` (`k10temp`, `coretemp`, `asus-ec-sensors`, `amdgpu`, `nvme`, `drivetemp`), `nvidia-smi` |
| Disk read/write | `/proc/diskstats`, two samples 1 s apart |
| Per-process disk I/O | `/proc/<pid>/io` (needs root to see other users' processes) |
| Container / VM of a process | `/proc/<pid>/cgroup` (`lxc.payload.<project>_<name>`) and QEMU's `-name` argument |
| Pool of a container | `incus list --all-projects -f json` → root disk pool, mapped to its ZFS pool via `incus storage list` |
| Pool health / resilver | `zpool status`, `zpool list` |

One refresh costs about 0.6 s of CPU and ~20 MB of short-lived memory, so the default
10-second refresh adds very little load.

## Limits

- RAM temperature isn't shown. DDR5 SPD sensors (`spd5118`) often don't bind on desktop boards.
- VRM temperatures need the `asus-ec-sensors` driver, so ASUS boards only.
- Intel GPUs aren't shown.
- Intel CPU (`coretemp`) and AMD GPU support were written from the kernel's sysfs layout but
  haven't been tested on real hardware yet. Reports welcome.
- A process that starts during the 1-second disk sample shows up on the next refresh.
- Per-process disk I/O counts what a process asked for. ZFS writes data later from its own
  threads, so the per-disk panel is the truer picture of what the drives are doing.

## License

MIT. See [LICENSE](LICENSE).
