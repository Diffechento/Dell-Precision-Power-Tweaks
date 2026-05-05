# Dell Precision 5570 — Battery Controller Protocol

Hardware: SMP (Samsung SDI) Li-Polymer, 7394 mAh / 11.4V design  
Chip family: TI BQ40-series gas gauge (SMBus, accessed via Dell EC)  
Interface stack: Windows → ACPI WMDV method → EC (ECWB/ECRW/ECRB) → SMBus → gas gauge

---

## Access layers

```
userspace (PowerShell / Python)
  └─ WMI  root\wmi : DDVWmiMethodFunction          ← primary read interface
  └─ WMI  root\dcim\sysman\biosattributes           ← charge threshold control
  └─ WMI  root\dcim\sysman\ecinterface : OpaqueAccess  ← raw EC channel (undocumented)
       └─ ACPI method WMDV  (ADDV device, PNP0C14)
            └─ EC registers  via ECWB / ECRW / ECRB AML opcodes
                 └─ SMBus → TI BQ40 gas gauge
```

Windows owns the SMBus ACPI driver. No direct userspace read/write to SMBus registers is possible — all access must go through WMI → EC.

---

## DDVWmiMethodFunction (read interface)

**WMI namespace:** `root\wmi`  
**Class:** `DDVWmiMethodFunction`  
**Device instance:** `ACPI\PNP0C14\ADDV_0`  
**DDV interface version:** 3 (returned by `ReturnVersion`)

### How to query

```powershell
# Must run as Administrator
$inst = Get-WmiObject -Namespace root\wmi -Class DDVWmiMethodFunction
$cls  = [wmiclass]"root\wmi:DDVWmiMethodFunction"

$inP = $cls.GetMethodParameters("BatteryVoltage")
$inP["arg2"] = [UInt32]1          # battery index: 1 = primary, 0 = returns all zeros
$r = $inst.InvokeMethod("BatteryVoltage", $inP, $null)
$r["argr"]                         # return value
```

**arg2 values:** `0` = no battery / returns zeros, `1` = primary battery, `2` = secondary (absent on 5570 → zeros)

### Method table

| Method | Return type | Units | Notes |
|--------|-------------|-------|-------|
| `BatteryDesignCapacity` | UInt32 | mAh | Design capacity |
| `BatteryFullChargeCapacity` | UInt32 | mAh | Current FCC (health indicator) |
| `BatteryDesignVoltage` | UInt32 | mV | Nominal voltage |
| `BatteryVoltage` | UInt32 | mV | Live terminal voltage |
| `BatteryCurrent` | UInt32 | mA | Positive = charging, negative = discharging |
| `BatteryTemperature` | UInt32 | 0.1 K | Divide by 10, subtract 273.15 for °C |
| `BatteryRelativeStateOfCharge` | UInt32 | % | % of FCC (not design capacity) |
| `BatteryCycleCount` | UInt32 | cycles | Full charge cycles |
| `BatteryManufactureName` | String | — | e.g. "SMP" |
| `BatteryManufactureDate` | UInt32 | SBS date | See decode below |
| `BatterySerialNumber` | UInt32 | — | Hex = SBS serial |
| `BatteryChemistryValue` | String | — | e.g. "LiP" |
| `BatteryManufactureAceess` | UInt32 | — | ManufacturerAccess() word (see below) |
| `BatteryePPID` | String | — | Dell PPID string |
| `BatteryeRawAnalyticsStart` | UInt32 | — | Returns 0 on success; initiates analytics read sequence |
| `BatteryeRawAnalytics` | ? | — | Read after Start; returns raw analytics block |
| `BatteryeRawAnalyticsABlock` | ? | — | Block-addressed analytics read |
| `ReturnVersion` | UInt32 | — | DDV interface version |
| `FanSensorInformation` | ? | — | Fan data (not populated on 5570) |
| `ThermalSensorInformation` | ? | — | Thermal data (not populated via this class) |

### ManufactureDate decode (SBS format)

```
bits [15:9]  Year  = value >> 9  + 1980
bits  [8:5]  Month = (value >> 5) & 0xF
bits  [4:0]  Day   = value & 0x1F

Example: 21675 = 0x54EB
  Year  = 42 + 1980 = 2022
  Month = 5   (May)
  Day   = 11
  → 2022-05-11
```

### ManufacturerAccess word

`BatteryManufactureAceess` returns the SBS ManufacturerAccess() register (0x00).  
For TI BQ40-series: this register is a general-purpose command gateway — the returned value depends on the last sub-command sent. Without sending a specific sub-command first (requires unsealed access), the returned value is chip-defined. On this machine: `0x01A8`.

To read gas gauge operating mode (Sealed/Unsealed/Full Access), the OperationStatus word is needed. This requires ManufacturerBlockAccess command 0x0054, which is not exposed via DDV WMI.

---

## ACPI WMDV command table (decoded from DSDT)

**DSDT offset:** 0x6C437  
**Device:** ADDV (`ACPI\PNP0C14\ADDV_0`)  
**WMI GUID:** `{8A42EA14-4F2A-FD45-6422-0087F7A7E608}` (matches Linux `dell-wmi-ddv` driver)

The WMDV AML method dispatches on Arg1 (command index 1–17). Each read command:
1. Writes the battery register address to EC register 0x03 via `ECWB`
2. Reads the result from the target EC register via `ECRW` (word) or `ECRB` (byte)

### Read commands

| Cmd | EC write reg | EC read reg | Width | DDV method (probable mapping) |
|-----|-------------|-------------|-------|-------------------------------|
| 1   | 0x03 | 0x20 | word | — |
| 2   | 0x03 | 0x1E | word | — |
| 3   | 0x03 | 0x28 | byte | — |
| 4   | 0x03 | 0x24 | word | BatteryDesignCapacity |
| 5   | 0x03 | 0x26 | word | BatteryFullChargeCapacity |
| 6   | 0x03 | 0x29 | byte | — |
| 7   | 0x03 | 0x18 | word | BatteryTemperature |
| 8   | 0x03 | 0x12 | word | BatteryVoltage |
| 9   | 0x03 | 0x14 | word | BatteryCurrent |
| 10  | 0x03 | 0x1A | word | — |
| 11  | 0x03 | 0x11 | byte | BatteryRelativeStateOfCharge |
| 12  | 0x03 | 0x3E | word | BatteryCycleCount |
| 13  | 0x03 | 0x6C | byte | — |
| 14  | 0x03 | 0x6C | byte | — (same as 13) |
| 16  | 0x03 | 0x22 | word | — |

### Write commands (charge thresholds)

| Cmd | Operation | Notes |
|-----|-----------|-------|
| 15  | `ECWB(0x28, SBH1)` + `ECWB(0x29, SBL1)` | Write two bytes from input buffer to EC regs 0x28/0x29 |
| 17  | `ECWB(0x29, ...)` | Write single byte to EC reg 0x29 |

EC registers 0x28 and 0x29 correspond to SBS ChargingVoltage or charge threshold control bytes. These are the underlying EC registers that `CustomChargeStart` / `CustomChargeStop` BIOS attributes write through.

---

## Charge threshold control (BIOS attributes)

**WMI namespace:** `root\dcim\sysman\biosattributes`  
**Classes:** `EnumerationAttribute`, `IntegerAttribute`

### Current state (as observed)

| Attribute | Value | Range |
|-----------|-------|-------|
| `PrimaryBattChargeCfg` | Express | — |
| `AdvBatteryChargeCfg` | Disabled | — |
| `CustomChargeStart` | 50 | 50–95 |
| `CustomChargeStop` | 90 | 55–100 |

### Charging modes (PrimaryBattChargeCfg)

| Mode | Description |
|------|-------------|
| Express | Charges to 100% at maximum rate — worst for longevity |
| Standard | Full charge, slower rate |
| Adaptive | Dell algorithm adapts to usage pattern |
| Custom | Uses CustomChargeStart / CustomChargeStop values |
| PrimAcUse | Optimized for always-on AC: keeps battery lower |

### Read attributes via PowerShell

```powershell
# Run as Administrator
Get-WmiObject -Namespace "root\dcim\sysman\biosattributes" -Class EnumerationAttribute |
    Where-Object { $_.AttributeName -match "Battery|Charge|Primary" } |
    Select-Object AttributeName, CurrentValue, PossibleValues

Get-WmiObject -Namespace "root\dcim\sysman\biosattributes" -Class IntegerAttribute |
    Where-Object { $_.AttributeName -match "Charge|Battery" } |
    Select-Object AttributeName, CurrentValue, LowerBound, UpperBound
```

### Set charge threshold (via BIOSAttributeInterface)

```powershell
# Run as Administrator
$bios = Get-WmiObject -Namespace "root\dcim\sysman\biosattributes" -Class BIOSAttributeInterface
# Switch to Custom mode with 70/80 thresholds:
$bios.SetBIOSAttributes($null, $null, "PrimaryBattChargeCfg", "Custom")
$bios.SetBIOSAttributes($null, $null, "CustomChargeStart", "70")
$bios.SetBIOSAttributes($null, $null, "CustomChargeStop", "80")
```

Takes effect immediately via EC — no reboot required.

---

## Battery state snapshot (2026-05-04)

| Parameter | Value |
|-----------|-------|
| Manufacturer | SMP |
| Manufacture date | 2022-05-11 |
| Serial | 0x0D89 (3465) |
| PPID | CN070N2FSLW0025B42O9A08 |
| Chemistry | Li-Polymer |
| Design capacity | 7394 mAh (84,292 mWh) |
| Full charge capacity | 4230 mAh (48,222 mWh) |
| Health | 57.2% |
| Cycle count | 315 |
| Design voltage | 11,400 mV |

**Note on Windows WMI cycle count:** `root\wmi : BatteryStaticData.CycleCount` returned `0` — this is a Windows ACPI driver bug. The real value (315) is only available via `DDVWmiMethodFunction`.

---

## What cannot be done from userspace

- **Gas gauge recalibration / RESET**: requires issuing ManufacturerAccess sub-commands to the TI BQ chip (e.g., 0x0041 = RESET). The chip must be Unsealed first using a 2-word key specific to the chip variant. The Unseal Key is not published by Dell or TI for OEM batteries.
- **Direct SMBus access**: Windows ACPI driver owns the SMBus; `\\.\PhysicalMemory` is blocked since Vista; kernel driver required.
- **OpaqueAccess raw EC commands**: `root\dcim\sysman\ecinterface : OpaqueAccess` exposes `FixedCmd` and `VarCmd` methods but accepted command bytes are undocumented and likely validated by the EC firmware.
