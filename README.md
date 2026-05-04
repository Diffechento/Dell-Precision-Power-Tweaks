# Dell Precision 5570 — CPU Throttle Fix + ThrottleStop Setup

**Hardware:** Dell Precision 5570, Intel i7-12700H, NVIDIA RTX A2000 8GB  
**Problem:** CPU throttled to ~400 MHz when using non-Dell USB-C charger  
**Root cause:** Dell EC detects non-original charger via USB-C CC authentication (CCG6 chip),
asserts BD PROCHOT hardware pin → CPU throttles. PROCHOT Lock in UEFI NVRAM prevents
ThrottleStop from disabling this at runtime.  
**Solution:** Unlock PROCHOT Lock in UEFI NVRAM via GRUB shell, then configure ThrottleStop
to disable BD PROCHOT input permanently.

---

## Quick Start (after fresh install)

```
# 1. Do Part 1 (UEFI unlock) — one time only, survives reboots
# 2. Copy ThrottleStop to any folder
# 3. Run as Administrator:
powershell -ExecutionPolicy Bypass -File install.ps1
# 4. Open ThrottleStop → Profile 1 (AC Max) → tick "BD PROCHOT" → TURN ON
```

---

## Part 1 — Unlock PROCHOT Lock in UEFI NVRAM

### What gets unlocked

NVRAM variable `CpuSetup` (GUID `B08F97FF-E6E8-4193-A997-5E9E9B0ADB32`):

| Offset | Name         | Locked | Unlocked |
|--------|--------------|--------|----------|
| `0x0E` | OC Lock      | `0x01` | `0x00`   |
| `0x43` | CFG Lock     | `0x01` | `0x00`   |
| `0x7D` | PROCHOT Lock | `0x01` | `0x00`   |

This is a **one-time operation**. Settings survive reboots but are reset by BIOS updates.

### Requirements

[modGRUBShell.efi](https://github.com/datasone/grub-mod-setup_var/releases) v1.4+

### Option A — Boot from USB drive

1. Format USB as FAT32
2. Place `modGRUBShell.efi` at `\EFI\BOOT\BOOTX64.EFI`
3. Boot from USB via F12 at POST

### Option B — Boot from EFI System Partition (already set up on this machine)

```
# Run as Administrator in Windows:
bcdedit /set "{fwbootmgr}" bootsequence "{968ae6f8-f0fd-11ef-b49d-b3dae714c264}"
shutdown /r /fw /t 0
```

> The GUID above is specific to this machine's EFI entry for modGRUBShell.
> On a different machine, register the entry first via `bcdedit /copy` or EasyUEFI.

### GRUB shell commands

At the `grub>` prompt:

```
setup_var_cv CpuSetup 0x0E 0x01 0x00
setup_var_cv CpuSetup 0x43 0x01 0x00
setup_var_cv CpuSetup 0x7D 0x01 0x00
reboot
```

Each command prints `old: 0x01  new: 0x00` on success.

### Verify (Windows, run as Administrator)

```
python tools\read_cpusetup.py
```

Results are written to `tools\read_cpusetup_output.txt`.  
All three offsets should show `0x00 (UNLOCKED)`.

---

## Part 2 — ThrottleStop + Auto-Switching Setup

### Install (run as Administrator)

```
powershell -ExecutionPolicy Bypass -File install.ps1
```

`install.ps1` does everything automatically:
- Copies `on_power_change.ps1` and `start_ts_minimized.ps1` into the ThrottleStop folder
- Auto-detects the NVIDIA discrete GPU device ID and patches it into the script
- Fixes profile names in `ThrottleStop.ini`
- Creates two scheduled tasks: `PowerSourceChange` and `ThrottleStop` (logon)

If ThrottleStop.exe is not found automatically:

```
powershell -ExecutionPolicy Bypass -File install.ps1 -ThrottleStopDir "C:\path\to\ThrottleStop"
```

### ThrottleStop profiles

| Profile | INI index | Name        | Trigger             |
|---------|-----------|-------------|---------------------|
| 1       | `0`       | AC Max      | Charger connected   |
| 4       | `3`       | Battery ECO | Running on battery  |

After install, open ThrottleStop and **in Profile 1 (AC Max) tick the "BD PROCHOT" checkbox**.  
This is the core of the fix — it disables the throttle input from the EC.  
If the checkbox is greyed out, PROCHOT Lock is still set (Part 1 not done).

### How auto-switching works

- Windows fires **Kernel-Power Event ID 105** on every AC plug/unplug
- Scheduled task `PowerSourceChange` runs `on_power_change.ps1` with admin rights
- Script reads actual AC state at runtime:
  - **AC plugged:** enable NVIDIA GPU → switch to Profile 1 (AC Max)
  - **Battery:** switch to Profile 4 (Battery ECO) → disable NVIDIA GPU

Log: `power_monitor.log` in the ThrottleStop folder.

---

## File Reference

```
precision-5570-setup\
├── README.md                    — this file
├── install.ps1                  — run as Admin to set everything up
├── scripts\
│   ├── on_power_change.ps1      — AC/battery switch (event-triggered, uses $PSScriptRoot)
│   └── start_ts_minimized.ps1   — starts ThrottleStop and minimizes it (logon task)
├── configs\
│   └── ThrottleStop.ini         — profile config backup (profiles 1 & 4)
└── tools\
    └── read_cpusetup.py         — reads CpuSetup NVRAM, prints lock status
```

---

## Troubleshooting

**BD PROCHOT checkbox is greyed out**  
→ PROCHOT Lock is still set. Redo Part 1, verify with `read_cpusetup.py`.

**Switching doesn't fire on charger plug/unplug**  
→ Check task status: `schtasks /query /tn "PowerSourceChange" /fo LIST`  
→ Re-run `install.ps1` as Administrator.  
→ Check `power_monitor.log` in the ThrottleStop folder.

**ThrottleStop opens as a window instead of minimized**  
→ Re-run `install.ps1` as Administrator (updates logon task).

**After BIOS update, throttling returns**  
→ BIOS updates reset NVRAM. Redo Part 1 (GRUB unlock).  
→ Re-enable BD PROCHOT checkbox in Profile 1 after reboot.

**Need to check lock status without rebooting**  
→ `python tools\read_cpusetup.py` as Administrator → see `read_cpusetup_output.txt`.
