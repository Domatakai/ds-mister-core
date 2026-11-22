#!/usr/bin/env python3
"""Program for tb/tb_arm9_tcm.sv, assembled by a real assembler.

The ARM9 bench's words come from keystone and are read back by capstone
(tools/gen_arm9_programs.py); this one follows the same rule, because the
core-level TCM bench should not be the place where a hand-encoded CP15
opcode goes unnoticed. Only the resulting hex is pasted into the bench, so
building the bench needs neither package; re-running this script does:

    pip install keystone-engine capstone
    python tools/gen_tcm_program.py

The program runs at 0x02000000 on main RAM and does what a game's crt0 does
with the TCM, through the core's own CP15 path:

  * writes the data TCM's region register (c9, opcode_2 = 0: base
    0x027C0000, size field b00101 = 16 KB) and sets c1 bit 16, then stores
    and loads a word there and patches its byte lanes
  * writes the instruction TCM's region register (c9, opcode_2 = 1: base 0
    as the hard part fixes it, size field b10000 = the 32 MB area the DS
    firmware programs) and sets c1 bit 18
  * reads both registers back, which is the check that the core keeps them
    apart -- before the c9 split both opcodes wrote one register
  * copies two instructions from 0x02000500 into the ITCM at 0x01000000 and
    branches to them, so the fetch that runs is a TCM hit
  * stores what it found at 0x02000400 and spins on a `b .`

The bench checks the registers, that block, and that the fabric model saw
none of the two TCM windows.
"""
import sys

from keystone import Ks, KS_ARCH_ARM, KS_MODE_ARM
import capstone

RAM_BASE = 0x02000000
DATA_BASE = 0x02000500
SCRATCH = 0x02000400

KS = Ks(KS_ARCH_ARM, KS_MODE_ARM)
MD = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)

# ARMv6 and later mnemonics: keystone reaches for movw when an ARMv5
# immediate cannot encode a constant, and the ARM946E-S would take the
# undefined vector for the result.
LATER_THAN_V5 = set("""
    movw movt bfi bfc sbfx ubfx sxtb sxth uxtb uxth rev rev16 revsh rbit
    ldrex strex clrex pkhbt pkhtb ssat usat sel
    """.split())


# (mnemonic text, comment) in execution order; addresses are assigned here
PROGRAM = [
    ("mov r0, #0x027C0000",        "DTCM base 0x027C0000"),
    ("orr r0, r0, #0xA",           "size field b00101: 16 KB"),
    ("mcr p15, 0, r0, c9, c1, 0",  "c9 opcode_2 0: the data TCM region"),
    ("mrc p15, 0, r1, c1, c0, 0",  "c1"),
    ("orr r1, r1, #0x10000",       "bit 16: data TCM enable"),
    ("mcr p15, 0, r1, c1, c0, 0",  ""),
    ("mov r2, #0x027C0000",        "the data TCM itself"),
    ("mov r3, #0xBE00",            ""),
    ("orr r3, r3, #0xEF",          "0x0000BEEF"),
    ("str r3, [r2]",               "a store the fabric must not see"),
    ("ldr r4, [r2]",               "read it back"),
    ("mov r5, #0xAA",              ""),
    ("strb r5, [r2]",              "byte lane 0"),
    ("ldr r6, [r2]",               "0x0000BEAA"),
    ("mov r5, #0x11",              ""),
    ("strb r5, [r2, #1]",          "byte lane 1"),
    ("ldr r0, [r2]",               "0x000011AA"),
    ("mov r0, #0x20",              "ITCM region: base 0, b10000 = 32 MB"),
    ("mcr p15, 0, r0, c9, c1, 1",  "c9 opcode_2 1: the instruction TCM"),
    ("mrc p15, 0, r1, c1, c0, 0",  "c1"),
    ("orr r1, r1, #0x40000",       "bit 18: instruction TCM enable"),
    ("mcr p15, 0, r1, c1, c0, 0",  ""),
    ("mrc p15, 0, r10, c9, c1, 0", "the data TCM region, still there"),
    ("mrc p15, 0, r11, c9, c1, 1", "and the instruction TCM's"),
    ("mov r7, #0x01000000",        "where libnds and blocksds run from"),
    ("mov r8, #0x02000000",        ""),
    ("orr r8, r8, #0x500",         "the two instructions at 0x02000500"),
    ("ldr r9, [r8]",               ""),
    ("str r9, [r7]",               "mov r0, #0x5A into the ITCM"),
    ("ldr r9, [r8, #4]",           ""),
    ("str r9, [r7, #4]",           "bx lr into the ITCM"),
    ("mov r0, r0",                 "let the store settle"),
    ("mov r0, r0",                 ""),
    ("mov lr, pc",                 ""),
    ("bx r7",                      "execute from 0x01000000"),
    ("mov r12, r0",                "the return value: 0x5A"),
    ("mov r0, #0x02000000",        ""),
    ("orr r0, r0, #0x400",         "scratch at 0x02000400"),
    ("str r4, [r0]",               "the data TCM round trip"),
    ("str r6, [r0, #4]",           "after the byte write"),
    ("str r12, [r0, #8]",          "what ran from the instruction TCM"),
    ("str r10, [r0, #12]",         "c9 opcode_2 0 read back"),
    ("str r11, [r0, #16]",         "c9 opcode_2 1 read back"),
    ("b .",                        "the end marker"),
]

# the two words the program copies into the instruction TCM
ITCM_WORDS = [("mov r0, #0x5A", 0x01000000), ("bx lr", 0x01000004)]


def one(text, addr):
    code, _ = KS.asm(text.encode(), addr)
    if not code or len(code) != 4:
        raise SystemExit("cannot assemble at %08x: %s" % (addr, text))
    raw = bytes(code)
    (insn,) = list(MD.disasm(raw, addr))
    if insn.mnemonic in LATER_THAN_V5:
        raise SystemExit("%08x: %s assembled to %s, which is not ARMv5TE"
                         % (addr, text, insn.mnemonic))
    return raw, "%s %s" % (insn.mnemonic, insn.op_str)


def main():
    addr = RAM_BASE
    words = []
    for text, comment in PROGRAM:
        raw, dis = one(text, addr)
        words.append((addr, raw, text, dis, comment))
        addr += 4
    end = addr

    print("// ---- tb/tb_arm9_tcm.sv, generated by tools/gen_tcm_program.py ----")
    print("task load_tcm_prog;")
    print("\tbegin")
    for a, raw, text, dis, comment in words:
        note = text if text == dis else "%s   (%s)" % (text, dis)
        tail = "".join(["; ", comment]) if comment else ""
        print("\t\tram[18'd%d] = 32'h%s;  // %08x  %s%s"
              % ((a - RAM_BASE) >> 2, raw[::-1].hex().upper(), a, note, tail))
    print("\t\t// the two instructions the program copies into the ITCM")
    for text, a in ITCM_WORDS:
        raw, dis = one(text, a)
        print("\t\tram[18'd%d] = 32'h%s;  // %08x  %s"
              % ((DATA_BASE - RAM_BASE) // 4 + (a - 0x01000000) // 4,
                 raw[::-1].hex().upper(), DATA_BASE + (a - 0x01000000), dis))
    print("\tend")
    print("endtask")
    print("// the program ends at 0x%08x; the data block holding the two words"
          % end)
    print("// sits at 0x%08x, and the results at 0x%08x" % (DATA_BASE, SCRATCH))


if __name__ == "__main__":
    sys.exit(main())
