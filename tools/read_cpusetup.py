import ctypes
import ctypes.wintypes
import os

output_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "read_cpusetup_output.txt")
log = open(output_file, "w", encoding="utf-8")

def L(s=""):
    log.write(s + "\n")
    log.flush()

L(f"Running as: {os.environ.get('USERNAME', 'unknown')}")
L("MODE: READ-ONLY — no modifications will be made")
L()

kernel32 = ctypes.windll.kernel32
advapi32 = ctypes.windll.advapi32

kernel32.GetCurrentProcess.argtypes = []
kernel32.GetCurrentProcess.restype = ctypes.c_void_p
advapi32.OpenProcessToken.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_void_p)]
advapi32.OpenProcessToken.restype = ctypes.c_bool

class LUID(ctypes.Structure):
    _fields_ = [("LowPart", ctypes.c_ulong), ("HighPart", ctypes.c_long)]

advapi32.LookupPrivilegeValueW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.POINTER(LUID)]
advapi32.LookupPrivilegeValueW.restype = ctypes.c_bool

class LUID_ATTR(ctypes.Structure):
    _fields_ = [("Luid", LUID), ("Attributes", ctypes.c_ulong)]

class TOKEN_PRIVILEGES(ctypes.Structure):
    _fields_ = [("Count", ctypes.c_ulong), ("Priv", LUID_ATTR * 1)]

advapi32.AdjustTokenPrivileges.argtypes = [
    ctypes.c_void_p, ctypes.c_bool, ctypes.POINTER(TOKEN_PRIVILEGES),
    ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p]
advapi32.AdjustTokenPrivileges.restype = ctypes.c_bool

kernel32.GetFirmwareEnvironmentVariableExW.argtypes = [
    ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_void_p,
    ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong)]
kernel32.GetFirmwareEnvironmentVariableExW.restype = ctypes.c_ulong

kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
kernel32.CloseHandle.restype = ctypes.c_bool

def enable_privs():
    h_proc = kernel32.GetCurrentProcess()
    h_token = ctypes.c_void_p()
    if not advapi32.OpenProcessToken(h_proc, 0x0028, ctypes.byref(h_token)):
        L(f"OpenProcessToken failed: {kernel32.GetLastError()}")
        return False
    luid = LUID()
    advapi32.LookupPrivilegeValueW(None, "SeSystemEnvironmentPrivilege", ctypes.byref(luid))
    tp = TOKEN_PRIVILEGES()
    tp.Count = 1
    tp.Priv[0].Luid.LowPart = luid.LowPart
    tp.Priv[0].Luid.HighPart = luid.HighPart
    tp.Priv[0].Attributes = 0x2
    advapi32.AdjustTokenPrivileges(h_token.value, False, ctypes.byref(tp), 0, None, None)
    kernel32.CloseHandle(h_token.value)
    return True

def read_var(name, guid):
    buf = (ctypes.c_ubyte * 8192)()
    attrs = ctypes.c_ulong(0)
    size = kernel32.GetFirmwareEnvironmentVariableExW(name, guid, buf, 8192, ctypes.byref(attrs))
    if size > 0:
        return bytearray(buf[:size]), attrs.value
    return None, kernel32.GetLastError()

def hexdump(data, start_offset, length=64, highlight_offsets=None):
    highlight_offsets = highlight_offsets or set()
    end = min(start_offset + length, len(data))
    for row in range(start_offset, end, 16):
        row_end = min(row + 16, end)
        hex_parts = []
        for i in range(row, row_end):
            marker = "*" if i in highlight_offsets else " "
            hex_parts.append(f"{marker}{data[i]:02X}")
        hex_str = " ".join(hex_parts)
        ascii_str = "".join(chr(b) if 0x20 <= b <= 0x7E else "." for b in data[row:row_end])
        L(f"  0x{row:04X}: {hex_str:<64}  {ascii_str}")

enable_privs()

# =====================================================
# Read CpuSetup
# =====================================================
CPU_GUID = "{B08F97FF-E6E8-4193-A997-5E9E9B0ADB32}"
CPU_NAME = "CpuSetup"

L("=" * 60)
L(f"Variable: {CPU_NAME}")
L(f"GUID:     {CPU_GUID}")
L("=" * 60)

cpu_data, cpu_attrs = read_var(CPU_NAME, CPU_GUID)
if cpu_data is None:
    L(f"FAILED to read CpuSetup: GetLastError={cpu_attrs}")
    if cpu_attrs == 1314:
        L("  Error 1314 = ERROR_PRIVILEGE_NOT_HELD")
        L("  Script is not running as SYSTEM or missing SeSystemEnvironmentPrivilege")
    elif cpu_attrs == 2:
        L("  Error 2 = variable not found")
    elif cpu_attrs == 5:
        L("  Error 5 = access denied")
else:
    L(f"Size:  {len(cpu_data)} bytes (0x{len(cpu_data):X})")
    L(f"Attrs: 0x{cpu_attrs:08X}")
    L()

    # Save raw dump
    dump_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cpusetup_readonly_dump.bin")
    with open(dump_path, "wb") as f:
        f.write(cpu_data)
    L(f"Raw dump saved: {dump_path}")
    L()

    # Key offsets of interest
    KEY_OFFSETS = {
        0x0E: ("OC Lock",              {0x00: "UNLOCKED", 0x01: "LOCKED"}),
        0x43: ("CFG Lock",             {0x00: "UNLOCKED", 0x01: "LOCKED"}),
        0x45: ("(unknown 0x45)",       {}),
        0x7A: ("BD PROCHOT",           {0x00: "disabled", 0x01: "enabled"}),
        0x7B: ("Disable PROCHOT Out",  {0x00: "normal",   0x01: "disabled"}),
        0x7D: ("PROCHOT Lock",         {0x00: "UNLOCKED", 0x01: "LOCKED"}),
        0x7E: ("PROCHOT Response",     {0x00: "0",        0x01: "1"}),
    }

    L("Key offsets:")
    all_zero = True
    for off in sorted(KEY_OFFSETS):
        label, meanings = KEY_OFFSETS[off]
        val = cpu_data[off]
        meaning = meanings.get(val, f"unknown value 0x{val:02X}")
        flag = " <-- LOCKED" if (val == 0x01 and "Lock" in label) else ""
        L(f"  [0x{off:04X}] {label:<26} = 0x{val:02X}  ({meaning}){flag}")
        if val != 0x00:
            all_zero = False

    L()
    if all_zero:
        L(">>> All target bytes are already 0x00 — modify_both_vars.py would make no changes.")
    else:
        L(">>> Some bytes are non-zero — modify_both_vars.py would modify them.")

    L()
    L("Hex dump around 0x00..0x10 (OC Lock area):")
    hexdump(cpu_data, 0x00, 32, highlight_offsets={0x0E})

    L()
    L("Hex dump around 0x38..0x50 (CFG Lock area):")
    hexdump(cpu_data, 0x38, 32, highlight_offsets={0x43, 0x45})

    L()
    L("Hex dump around 0x70..0x88 (PROCHOT area):")
    hexdump(cpu_data, 0x70, 32, highlight_offsets={0x7A, 0x7B, 0x7D, 0x7E})

# =====================================================
# Also read Setup for comparison
# =====================================================
L()
L("=" * 60)
L("Variable: Setup (for reference)")
L(f"GUID:     {{EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9}}")
L("=" * 60)

SETUP_GUID = "{EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9}"
setup_data, setup_attrs = read_var("Setup", SETUP_GUID)
if setup_data is None:
    L(f"FAILED to read Setup: GetLastError={setup_attrs}")
else:
    L(f"Size:  {len(setup_data)} bytes (0x{len(setup_data):X})")
    L(f"Attrs: 0x{setup_attrs:08X}")
    ac_names = {0x00: "Disabled/None", 0x01: "90W", 0x02: "65W", 0x03: "75W"}
    L(f"  [0x00C8] AC Brick Capacity = 0x{setup_data[0x00C8]:02X} ({ac_names.get(setup_data[0x00C8], '?')})")
    L(f"  [0x0043] CFG Lock (Setup)  = 0x{setup_data[0x0043]:02X}")
    L(f"  [0x007D] PROCHOT Lock      = 0x{setup_data[0x007D]:02X}")

L()
L("=" * 60)
L("DONE — no modifications were made.")
L("=" * 60)
log.close()
