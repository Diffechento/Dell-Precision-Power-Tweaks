"""Patch the Dell Precision 5570 DSDT so the EC's GPU D-notify (0xD2..0xD5) always arrives as 0xD1
(full performance), and neutralise the secondary EVD2 path Notify(PEGP, Arg1) with Noops.
Same length, checksum fixed. Patterns are searched, not hardcoded, so it survives small BIOS changes
as long as each pattern is still unique.

Usage: python patch_dsdt.py DSDT.aml DSDT_patched.aml"""
import sys

src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src, 'rb').read())
assert sum(d) & 0xFF == 0, 'input checksum bad'

PATH = b'\x5C\x2F\x04_SB_PC00PEG1PEGP'  # \_SB.PC00.PEG1.PEGP
changes = []
for lvl in (0xD2, 0xD3, 0xD4, 0xD5):
    pat = b'\x86' + PATH + bytes([0x0A, lvl])  # Notify (\_SB.PC00.PEG1.PEGP, lvl)
    i = d.find(pat)
    assert i >= 0 and d.find(pat, i + 1) < 0, f'pattern for 0x{lvl:X} not unique'
    d[i + len(pat) - 1] = 0xD1
    changes.append(f'0x{i + len(pat) - 1:X}: Notify(PEGP, 0x{lvl:X}) -> 0xD1')

pat = b'\x86PEGP\x69'  # Notify (PEGP, Arg1) inside EVD2
i = d.find(pat)
assert i >= 0 and d.find(pat, i + 1) < 0, 'EVD2 notify not unique'
d[i:i + len(pat)] = b'\xA3' * len(pat)  # Noop x6
changes.append(f'0x{i:X}: EVD2 Notify(PEGP, Arg1) -> Noop x{len(pat)}')

d[9] = 0
d[9] = (-sum(d)) & 0xFF
assert sum(d) & 0xFF == 0
open(dst, 'wb').write(d)
print('\n'.join(changes))
print(f'checksum byte -> 0x{d[9]:02X}, size {len(d)}')
