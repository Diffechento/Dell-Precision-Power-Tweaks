# Dell Precision 5570: making it actually use its hardware

My Precision 5570 (i7-12700H, RTX A2000 8GB) kept slowing itself down for reasons that had
nothing to do with how hot or busy it actually was. This repo is the set of fixes I ended up
with, plus notes on how each problem was tracked down. It's written for this exact laptop;
on anything else, treat it as a map, not a recipe.

What was wrong, roughly in the order I ran into it:

1. **CPU stuck at ~400 MHz on a non-Dell USB-C charger.** The EC doesn't trust third-party
   chargers and holds the CPU's BD PROCHOT pin. Fix: unlock PROCHOT in NVRAM, then turn
   BD PROCHOT off in ThrottleStop. ([Part 1](#part-1--unlock-prochot-in-nvram), [Part 2](#part-2--throttlestop-and-auto-switching))
2. **GPU stuck at 20 W after sleep or after re-plugging the charger.** The power limit
   sometimes comes back at 20 W instead of 35–45 W and stays there until the GPU is restarted.
   Fix: the power-switch script now checks the limit and restarts the GPU if it's low.
   ([Part 2](#part-2--throttlestop-and-auto-switching))
3. **GPU dropping to 20 W mid-game, with everything still cool.** This is the fun one: a case
   temperature sensor hits 41 °C and the EC tells the GPU to back off. Fix: a patched DSDT that
   swallows that message. ([Part 3](#part-3--the-41-c-case-sensor))
4. **Old thermal paste.** Not software, but it made everything else worse. See [Cooling](#cooling).

---

## Part 1 — Unlock PROCHOT in NVRAM

Only needed for problem 1 (third-party chargers). With the Dell 130 W charger you can skip it.

The locks live in the `CpuSetup` NVRAM variable (GUID `B08F97FF-E6E8-4193-A997-5E9E9B0ADB32`).
Offsets below were checked against the Setup IFR of BIOS 1.39 and 1.42:

| Offset  | What it is                | Default | Set to |
|---------|---------------------------|---------|--------|
| `0x43`  | CFG Lock                  | `0x01`  | `0x00` |
| `0x7D`  | PROCHOT Lock              | `0x01`  | `0x00` |
| `0x10E` | OC Lock                   | `0x01`  | optional, only for undervolt experiments |
| `0x381` | UnderVolt Protection      | `0x01`  | optional, same |

> **If you followed an older version of this README:** it said `0x0E` was OC Lock. It isn't —
> `0x0E` is "Per Core P State OS control mode", and writing `0x00` there turns it off.
> Put it back with `setup_var_cv CpuSetup 0x0E 0x01 0x01`.

For the record, unlocking OC Lock and UVP didn't get me a working CPU undervolt; ThrottleStop
still greys out the voltage controls. The H-series microcode may just refuse.

### Getting to a GRUB shell with `setup_var`

You need [modGRUBShell.efi](https://github.com/datasone/grub-mod-setup_var/releases) v1.4+
and Secure Boot off.

- **From a USB stick:** FAT32, put the file at `\EFI\BOOT\BOOTX64.EFI`, boot it with F12.
- **From the EFI partition** (how my machine is set up): register an entry once, then boot it
  one time with
  ```
  bcdedit /set "{fwbootmgr}" bootsequence "{968ae6f8-f0fd-11ef-b49d-b3dae714c264}"
  shutdown /r /fw /t 0
  ```
  That GUID is my machine's entry; yours will differ.

At the `grub>` prompt (`setup_var_cv <variable> <offset> <size> <value>`):

```
setup_var_cv CpuSetup 0x43 0x01 0x00
setup_var_cv CpuSetup 0x7D 0x01 0x00
reboot
```

Check from Windows (as admin): `python tools\read_cpusetup.py`, output goes to
`tools\read_cpusetup_output.txt`. BIOS updates reset all of this.

---

## Part 2 — ThrottleStop and auto-switching

Run as admin:

```
powershell -ExecutionPolicy Bypass -File install.ps1
```

(or `-ThrottleStopDir "C:\path\to\ThrottleStop"` if it can't find ThrottleStop on its own)

It copies the scripts into the ThrottleStop folder, drops in `configs\ThrottleStop.ini`, and
creates three scheduled tasks:

| Task                | When                              | What it does |
|---------------------|-----------------------------------|--------------|
| `PowerSourceChange` | charger plugged / unplugged (Kernel-Power 105) | AC: enable dGPU, profile *AC Max*, check GPU power limit. Battery: profile *Battery ECO*, disable dGPU. |
| `GpuResumeCheck`    | waking from sleep (Kernel-Power 507) | On AC only: check GPU power limit, nothing else. |
| `ThrottleStop`      | logon                             | Starts ThrottleStop minimised. |

The GPU check reads `Current Power Limit` from `nvidia-smi`. If it's under 35 W, the GPU is
restarted with `pnputil /restart-device`, which brings it back to 45 W. If a game is running at
that moment it will crash, but at 20 W it wasn't really playable anyway.

Everything is logged to `power_monitor.log` next to ThrottleStop.

After installing, open ThrottleStop, go to profile 1 (*AC Max*), untick **BD PROCHOT** and hit
**Turn On**. Once unticked, ThrottleStop 9.7 locks the MSR and the box goes grey *and unticked*
— that's the good state. Grey *and ticked* means PROCHOT Lock is still set (Part 1).

### Power limits in the config

|                 | AC Max (profile 1) | Battery ECO (profile 4) |
|-----------------|--------------------|-------------------------|
| PL1             | 65 W               | 28 W                    |
| PL2             | 115 W              | 45 W                    |
| Time window     | 28 s               | 28 s                    |
| Lock            | yes                | yes                     |

These are ceilings, not targets: this chassis can't actually cool 65 W of CPU, and in games the
CPU sits around 20–25 W anyway. The lock bit stops Intel DTT from rewriting them.

---

## Part 3 — The 41 °C case sensor

### What happens

After about 10–15 minutes of gaming the GPU suddenly drops from P0 (~45 W, VRAM at 5501 MHz)
to P5 (20 W, VRAM at 810 MHz) and frame rate roughly halves. At that moment the CPU and GPU are
both around 70 °C, the fans are already at max, nothing is actually hot.

What *is* at 41 °C is one slow sensor on the board. Dell's DDV WMI interface calls it an
"ambient" sensor (type `0x44`; it's `temp04` in my logger), and Windows lists it as the Intel
DTT participant `ACPI\INTC1046\SKIN`. In every session the drop happened the second it read
41 °C, and the GPU only came back once it cooled to 38 °C, which in practice means 10+
minutes of 20 W.

So it's a skin-temperature limit: keep the aluminium case comfortable to touch. Fair enough on
your lap, completely pointless on a desk.

### How the message gets to the GPU

The throttle is purely software. In two days of logging, `nvidia-smi` never reported HW Slowdown,
HW Thermal or HW Power Brake, only SW Power Cap / SW Thermal. The path, from the DSDT:

```
EC sees 41 °C, writes a level into EC register 0x2E, raises query _Q66
  _Q66() -> NEVT()
    if event bit 0x8000:
      Local3 = ECRB(0x2E)
      Notify(\_SB.PC00.PEG1.PEGP, 0xD1 .. 0xD5)   <- GPU performance level, D1 = full
      EV11(0x8000, Local3) -> PEGP.EVD2 -> Notify(PEGP, Arg1)   (second path)
```

The NVIDIA driver answers anything below D1 by capping power and dropping to P5.

Things that **don't** help, so you don't waste an evening on them:

- Stopping Intel DTT (`ipfsvc`): the drop still happens. The decision is in the EC, not Windows.
- Disabling the SKIN device: Windows refuses ("critical system device"), and it wouldn't
  matter anyway because the EC reads the sensor directly.
- Hidden BIOS options: there are "Sensor Device 1–5 / Skin Hotspot" entries in the Setup IFR,
  but they're Intel reference-board leftovers, already disabled, and not what Dell uses.
- `nvidia-smi -pl`, `--gpu-target-temp`, NVML clock offsets, Afterburner: all locked on this
  pro-driver GPU. `-lmc` memory locks are accepted but get overridden by the cap.

### The fix

Patch the DSDT so every `Notify(PEGP, 0xD2..0xD5)` becomes `0xD1`, and replace the `EVD2`
notify with `Noop`s. It's a same-length byte patch, nothing gets recompiled. Windows can load a
replacement DSDT from the registry by itself (`asl.exe /loadtable`), no custom bootloader needed,
**but only while test signing is on.**

Before you start:

- Secure Boot has to be off (test signing won't turn on otherwise).
- If BitLocker is on, suspend it first, or have the recovery key at hand.
- Know how to get into WinRE (Shift + Restart, or kill power at the boot logo three times):
  that's your way back if something goes wrong.

Steps (PowerShell, admin where it matters):

```powershell
cd tools\dsdt
.\dump_dsdt.ps1                      # saves the live DSDT as DSDT.aml
python patch_dsdt.py DSDT.aml DSDT_patched.aml
.\get_asl.ps1                        # pulls asl.exe from the WDK NuGet package
bcdedit /set testsigning on          # skip if already on
.\load_dsdt.ps1                      # writes the override into the registry
# reboot
.\dump_dsdt.ps1                      # should now say "skin-temp patch active: True"
```

`patch_dsdt.py` finds the patterns instead of using fixed offsets and refuses to run if any of
them isn't unique.

Result on my machine: 38 minutes of ETS2, the case sensor sat at 41–42 °C for four of them,
and the GPU stayed in P0 at ~45 W the whole time.

### Things to keep in mind

- **The DSDT is captured from a running system**, so it contains addresses the BIOS fills in at
  boot (NVS regions, the MAC address). Mine were identical across reboots, but check yours:
  dump it twice with a reboot in between and compare before loading the patch.
- **Redo it after every BIOS update.** Remove the override first (`.\load_dsdt.ps1 -Remove`),
  reboot, dump the new table, patch it again.
- **The case will get warmer than Dell intended.** The GPU still protects itself (75 °C target,
  hardware limits untouched), but the bottom can go past 41 °C. Not great on your knees.
- The `.aml` files contain your MAC address, so they're in `.gitignore`.

### Undoing it

- Normally: `.\load_dsdt.ps1 -Remove` and reboot.
- From WinRE if Windows won't boot: `bcdedit /set {default} testsigning off`. Without test
  signing the override is ignored and the original table loads. Or delete the key offline:
  ```
  reg load HKLM\OFFSYS C:\Windows\System32\config\SYSTEM
  reg delete HKLM\OFFSYS\ControlSet001\Services\ACPI\Parameters\DSDT /f
  reg unload HKLM\OFFSYS
  ```
  (in WinRE the Windows drive isn't always `C:`, check with `dir`)

---

## Cooling

The original paste was done. Before repasting, CPU hit 91–96 °C at only ~23 W with both fans
at max, and the GPU dropped to 20 W within a minute. After switching to PTM7950 (pads were fine,
left them):

|                       | Before   | After PTM7950 |
|-----------------------|----------|---------------|
| CPU in game           | 91–96 °C | 70–77 °C      |
| GPU in P0 before cap  | ~1 min   | 14 min (and indefinitely with Part 3) |
| GPU power held        | ~30 W, falling | 45 W     |

Fans max out at about 6300 / 6000 rpm (CPU / GPU) and there's no way to push them further:
the BIOS only exposes `ThermalManagement` (keep it on `UltraPerformance`).

Unrelated but worth knowing: Office's `SDXHelper.exe` once got stuck burning two cores in the
background, about 20 W of heat for nothing. Check Task Manager if the laptop is hot at idle.

---

## Files

```
install.ps1                  set up ThrottleStop config, scripts and scheduled tasks (admin)
scripts\
  on_power_change.ps1        AC/battery switching + GPU power limit check (-Resume for wake)
  start_ts_minimized.ps1     starts ThrottleStop minimised at logon
configs\
  ThrottleStop.ini           my ThrottleStop config, all four profiles
tools\
  read_cpusetup.py           reads CpuSetup locks from NVRAM (admin)
  dsdt\
    dump_dsdt.ps1            save the live DSDT, report whether the patch is active
    patch_dsdt.py            the 41 °C case-sensor patch
    get_asl.ps1              get asl.exe from the WDK NuGet package
    load_dsdt.ps1            load / remove the registry DSDT override (admin)
docs\
  battery-controller-protocol.md   Dell DDV WMI, ACPI WMDV commands, charge thresholds
```

## Troubleshooting

**Switching doesn't happen when I plug the charger in.** Check the task
(`schtasks /query /tn PowerSourceChange /fo LIST`), look at `power_monitor.log`, re-run
`install.ps1`.

**GPU is at 20 W at the desktop.** `nvidia-smi -q -d POWER` will show `Current Power Limit: 20 W`.
Unplug and replug the charger, or restart the GPU in Device Manager. If it happens mid-game
only, that's Part 3.

**Throttling came back after a BIOS update.** NVRAM and the DSDT override both need redoing:
Part 1 again, then Part 3 from the dump step.

**BD PROCHOT is grey and ticked.** PROCHOT Lock is still set. Redo Part 1 and check with
`read_cpusetup.py`.
