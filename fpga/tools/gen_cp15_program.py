#!/usr/bin/env python3
"""Program for tb/tb_arm9_cp15.sv, assembled by a real assembler.

The caches' first step is the CP15 state software can see, so the bench that
owns it runs a program through the core's own MCR/MRC path rather than
poking registers from the testbench. As with the other ARM9 programs the words
come from keystone and are read back by capstone, and only the resulting hex
is pasted into the bench:

    pip install keystone-engine capstone
    python tools/gen_cp15_program.py

The program runs at 0x02000000, writes one word per check to 0x02000400 and
then issues every c7 command the ARM946E-S defines before a WFI:

  * c2's two cachability maps (data and instruction) are separate registers,
    and their reserved bits read as zero
  * c3's write-bufferability map, c5's four permission halves, and c6's
    eight regions are independent; the DS mirrors c6 opcode_2 1 onto the
    same region, so a write through the instruction half is read back
    through the data half
  * c9 keys lockdown (CRm 0) apart from the TCM region (CRm 1): the lockdown
    registers are written and read back while both TCM registers are
    programmed and read back, and neither pair disturbs the other
  * c7 reads: the write-only register reads zero, while test-and-clean and
    test-clean-invalidate report the cache already clean
  * c7 writes: the nine encoded commands, then two encodings the ARM946E-S
    does not have (an invalidate by index and a write-buffer drain), which
    must not decode
  * WFI stops the core; the bench wakes it with an interrupt and checks the
    instruction after it runs

The bench checks the results block, the order and argument of the c7 strobes,
and that the core really halted at WFI.
"""
import sys

from keystone import Ks, KS_ARCH_ARM, KS_MODE_ARM
import capstone

RAM_BASE = 0x02000000
SCRATCH = 0x02000400

KS = Ks(KS_ARCH_ARM, KS_MODE_ARM)
MD = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)

# ARMv6 and later mnemonics: keystone reaches for these when an ARMv5
# immediate cannot encode a constant, and the ARM946E-S would take the
# undefined vector for the result.
LATER_THAN_V5 = set("""
    movw movt bfi bfc sbfx ubfx sxtb sxth uxtb uxth rev rev16 revsh rbit
    ldrex strex clrex pkhbt pkhtb ssat usat sel
    """.split())


# (mnemonic text, comment) in execution order; addresses are assigned here
PROGRAM = [
    ("mov r8, #0x02000000",        ""),
    ("orr r8, r8, #0x400",         "results at 0x02000400"),

    # ---- c2: data and instruction cachability maps ----
    ("mrc p15, 0, r1, c2, c0, 0",  "data map, at reset"),
    ("str r1, [r8], #4",           "0: 0"),
    ("mov r0, #0xA5",              ""),
    ("mcr p15, 0, r0, c2, c0, 0",  "data map"),
    ("mrc p15, 0, r1, c2, c0, 0",  ""),
    ("str r1, [r8], #4",           "1: 0xA5"),
    ("mrc p15, 0, r1, c2, c0, 1",  "instruction map is its own register"),
    ("str r1, [r8], #4",           "2: 0"),
    ("mov r0, #0x5A",              ""),
    ("mcr p15, 0, r0, c2, c0, 1",  ""),
    ("mrc p15, 0, r1, c2, c0, 1",  ""),
    ("str r1, [r8], #4",           "3: 0x5A"),
    ("mvn r0, #0",                 "all ones"),
    ("mcr p15, 0, r0, c2, c0, 0",  "the reserved bits are not kept"),
    ("mrc p15, 0, r1, c2, c0, 0",  ""),
    ("str r1, [r8], #4",           "4: 0"),

    # ---- c3: the write-bufferability map ----
    ("mov r0, #0x0F000000",        ""),
    ("orr r0, r0, #0x0F0000",      ""),
    ("orr r0, r0, #0x0F00",        ""),
    ("orr r0, r0, #0x0F",          "0x0F0F0F0F"),
    ("mcr p15, 0, r0, c3, c0, 0",  ""),
    ("mrc p15, 0, r1, c3, c0, 0",  ""),
    ("str r1, [r8], #4",           "5: 0x0F"),

    # ---- c5: four permission halves ----
    ("mov r0, #0x12000000",        ""),
    ("orr r0, r0, #0x00340000",    ""),
    ("orr r0, r0, #0x00005600",    ""),
    ("orr r0, r0, #0x78",          "0x12345678"),
    ("mcr p15, 0, r0, c5, c0, 0",  "normal, data: 16 bits"),
    ("mrc p15, 0, r1, c5, c0, 0",  ""),
    ("str r1, [r8], #4",           "6: 0x5678"),
    ("mov r0, #0x11000000",        ""),
    ("orr r0, r0, #0x00110000",    ""),
    ("orr r0, r0, #0x00002200",    ""),
    ("orr r0, r0, #0x22",          "0x11112222"),
    ("mcr p15, 0, r0, c5, c0, 1",  "normal, instruction"),
    ("mrc p15, 0, r1, c5, c0, 1",  ""),
    ("str r1, [r8], #4",           "7: 0x2222"),
    ("mov r0, #0x33000000",        ""),
    ("orr r0, r0, #0x00330000",    ""),
    ("orr r0, r0, #0x00004400",    ""),
    ("orr r0, r0, #0x44",          "0x33334444"),
    ("mcr p15, 0, r0, c5, c0, 2",  "extended, data: all 32 bits"),
    ("mrc p15, 0, r1, c5, c0, 2",  ""),
    ("str r1, [r8], #4",           "8: 0x33334444"),
    ("mov r0, #0x55000000",        ""),
    ("orr r0, r0, #0x00550000",    ""),
    ("orr r0, r0, #0x00006600",    ""),
    ("orr r0, r0, #0x66",          "0x55556666"),
    ("mcr p15, 0, r0, c5, c0, 3",  "extended, instruction"),
    ("mrc p15, 0, r1, c5, c0, 3",  ""),
    ("str r1, [r8], #4",           "9: 0x55556666"),

    # ---- c6: the eight protection regions, CRm selecting one ----
    ("mov r0, #0x02000000",        ""),
    ("orr r0, r0, #0x17",          "base 0x02000000, 4 KB, enabled"),
    ("mcr p15, 0, r0, c6, c0, 0",  "region 0"),
    ("mrc p15, 0, r1, c6, c0, 0",  ""),
    ("str r1, [r8], #4",           "10: 0x02000017"),
    ("mov r0, #0x08000000",        ""),
    ("orr r0, r0, #0x17",          ""),
    ("mcr p15, 0, r0, c6, c7, 0",  "region 7"),
    ("mrc p15, 0, r1, c6, c7, 0",  ""),
    ("str r1, [r8], #4",           "11: 0x08000017"),
    ("mov r0, #0x03000000",        ""),
    ("orr r0, r0, #0x17",          ""),
    ("mcr p15, 0, r0, c6, c3, 0",  "region 3"),
    ("mrc p15, 0, r1, c6, c3, 0",  ""),
    ("str r1, [r8], #4",           "12: 0x03000017"),
    ("mrc p15, 0, r1, c6, c1, 0",  "region 1 was never written"),
    ("str r1, [r8], #4",           "13: 0"),
    ("mov r0, #0x02000000",        ""),
    ("orr r0, r0, #0x1B",          "16 KB this time"),
    ("mcr p15, 0, r0, c6, c0, 1",  "the instruction half of region 0"),
    ("mrc p15, 0, r1, c6, c0, 0",  "reads through the data half"),
    ("str r1, [r8], #4",           "14: 0x0200001B"),

    # ---- c9: lockdown (CRm 0) must not touch the TCM region (CRm 1) ----
    ("mrc p15, 0, r1, c9, c0, 0",  "data lockdown, at reset"),
    ("str r1, [r8], #4",           "15: 0"),
    ("mov r0, #0x80000000",        "L set"),
    ("orr r0, r0, #1",             "way 1"),
    ("mcr p15, 0, r0, c9, c0, 0",  "data lockdown"),
    ("mrc p15, 0, r1, c9, c0, 0",  ""),
    ("str r1, [r8], #4",           "16: 0x80000001"),
    ("mov r0, #0x80000000",        ""),
    ("orr r0, r0, #2",             "way 2"),
    ("mcr p15, 0, r0, c9, c0, 1",  "instruction lockdown"),
    ("mrc p15, 0, r1, c9, c0, 1",  ""),
    ("str r1, [r8], #4",           "17: 0x80000002"),
    ("mov r0, #0x027C0000",        "the data TCM region"),
    ("orr r0, r0, #0xA",           "16 KB"),
    ("mcr p15, 0, r0, c9, c1, 0",  "CRm 1, not CRm 0"),
    ("mov r0, #0x20",              "the instruction TCM's 32 MB area"),
    ("mcr p15, 0, r0, c9, c1, 1",  ""),
    ("mrc p15, 0, r1, c9, c1, 0",  ""),
    ("str r1, [r8], #4",           "18: 0x027C000A"),
    ("mrc p15, 0, r1, c9, c1, 1",  ""),
    ("str r1, [r8], #4",           "19: 0x20"),
    ("mrc p15, 0, r1, c9, c0, 0",  "lockdown survived the TCM writes"),
    ("str r1, [r8], #4",           "20: 0x80000001"),

    # ---- c7 reads ----
    ("mrc p15, 0, r1, c7, c5, 0",  "the maintenance register is write-only"),
    ("str r1, [r8], #4",           "21: 0"),
    ("mrc p15, 0, r1, c7, c10, 3", "test and clean: nothing dirty"),
    ("str r1, [r8], #4",           "22: 1"),
    ("mrc p15, 0, r1, c7, c14, 3", "test, clean and invalidate"),
    ("str r1, [r8], #4",           "23: 1"),

    # ---- c7 writes the ARM946E-S defines ----
    ("mov r0, #0x02000000",        ""),
    ("orr r0, r0, #0x120",         ""),
    ("orr r0, r0, #3",             "the line address the strobe carries"),
    ("mcr p15, 0, r0, c7, c5, 0",  "invalidate the whole I-cache"),
    ("mcr p15, 0, r0, c7, c5, 1",  "invalidate an I-cache line by address"),
    ("mcr p15, 0, r0, c7, c6, 0",  "invalidate the whole D-cache"),
    ("mcr p15, 0, r0, c7, c6, 1",  "invalidate a D-cache line by address"),
    ("mcr p15, 0, r0, c7, c10, 1", "clean a D-cache line by address"),
    ("mcr p15, 0, r0, c7, c10, 2", "clean a D-cache line by index"),
    ("mcr p15, 0, r0, c7, c14, 1", "clean and invalidate by address"),
    ("mcr p15, 0, r0, c7, c14, 2", "clean and invalidate by index"),
    ("mcr p15, 0, r0, c7, c13, 1", "prefetch an I-cache line"),
    ("mcr p15, 0, r0, c7, c5, 2",  "not on this part: invalidate by index"),
    ("mcr p15, 0, r0, c7, c10, 4", "not on this part: drain write buffer"),
    ("mcr p15, 0, r0, c7, c0, 4",  "wait for interrupt"),
    ("mov r0, #0x5A",              "only runs if the interrupt woke it"),
    ("str r0, [r8]",               "one word past the results block"),
    ("b .",                        "the end marker, reached after the wake"),
]


def one(text, addr):
    try:
        code, _ = KS.asm(text.encode(), addr)
    except Exception as exc:
        raise SystemExit("%08x: cannot assemble %r (%s)" % (addr, text, exc))
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

    print("// ---- tb/tb_arm9_cp15.sv, generated by tools/gen_cp15_program.py ----")
    print("task load_cp15_prog;")
    print("\tbegin")
    for a, raw, text, dis, comment in words:
        note = text if text == dis else "%s   (%s)" % (text, dis)
        tail = "".join(["; ", comment]) if comment else ""
        print("\t\tram[18'd%d] = 32'h%s;  // %08x  %s%s"
              % ((a - RAM_BASE) >> 2, raw[::-1].hex().upper(), a, note, tail))
    print("\tend")
    print("endtask")
    print("// the program ends at 0x%08x: the WFI at 0x%08x, the marker at"
          % (end, end - 12))
    print("// 0x%08x; the results block starts at 0x%08x" % (end - 4, SCRATCH))


if __name__ == "__main__":
    sys.exit(main())
