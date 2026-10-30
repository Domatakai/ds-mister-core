#!/usr/bin/env python3
"""Programs for tb/tb_arm9.sv, assembled by a real assembler.

The ARM9 bench runs hand-written programs, so their encodings have to be
right. The core's decoder and the bench's instruction words would otherwise
come from the same head, and a shared mistake would pass. This script removes
that risk: every word is produced by keystone (an LLVM-MC based assembler) and
then read back by capstone (an independent disassembler). Only the resulting
hex is pasted into the bench, so building the bench needs neither package;
re-running this script does:

    pip install keystone-engine capstone
    python tools/gen_arm9_programs.py          # prints the Verilog fragments

Programs, all loaded over main RAM at 0x02000000 and run after a reset (the
bench resets between them, so each starts with a clean register file and the
CP15 reset values):

  A  integer ARM: ADD/CMP/MOVEQ, LDR/STR round trip, barrel shifter, SUBS
     flags, MUL, MLA, UMULL, SMULL with a negative operand, BX into a Thumb
     block and back, SWI through the high vector (0xFFFF0008 — the DS's
     post-BIOS CP15 setting selects it), the IRQ vector, and a BL subroutine
  B  the ARMv5TE additions: SMULxy/SMLAxy/SMULWy/SMLAWy/SMLALxy, CLZ, the
     QADD/QSUB/QDADD/QDSUB family with the sticky Q flag (MSR CPSR_f clears
     it), LDRD/STRD (immediate, pre-index writeback, register offset),
     LDRH/LDRSB/LDRSH, the DS's alignment rules (a misaligned LDR rotates;
     misaligned stores and LDRH force-align), LDM/STM with the user-mode bank
     from IRQ mode, and SWP
  C  CP15 (main ID, cache type, the post-BIOS control value, register round
     trips, c7 maintenance, the V bit moving the vectors to 0x00000000), SWI
     through the low vector, BKPT taking the prefetch abort -- leaving c6 alone
     and linking past the breakpoint, as the architecture has it -- MSR with an
     immediate, and Thumb BLX, BKPT and PUSH/POP

The bench seats the exception vectors this script prints at the end: the
"return from exception" instruction (CPSR <- SPSR) at 0x08/0x0C in the low
page and 0x08/0x18 in the high one.
"""

import struct
import sys

try:
    import capstone
    import keystone
except ImportError:  # pragma: no cover
    sys.exit("needs: pip install keystone-engine capstone")

RAM_BASE = 0x02000000
THUMB_BASE = RAM_BASE + 0x100
HIGH_BASE = 0xFFFF0000

KS_ARM = keystone.Ks(keystone.KS_ARCH_ARM, keystone.KS_MODE_ARM)
KS_THUMB = keystone.Ks(keystone.KS_ARCH_ARM, keystone.KS_MODE_THUMB)
MD_ARM = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)
MD_THUMB = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_THUMB)


# mnemonics that only exist from ARMv6 on: assembling one of these would put a
# word in the bench that the ARM946E-S would take the undefined vector for,
# and keystone reaches for some of them (movw) when an ARMv5 immediate cannot
# encode a constant, so they are rejected rather than trusted.
LATER_THAN_V5 = set("""
    movw movt bfi bfc sbfx ubfx sxtb sxth uxtb uxth rev rev16 revsh rbit
    ldrex strex clrex pkhbt pkhtb ssat usat sel sxtab sxtah uxtab uxtah
    cps it cbz cbnz tbb tbh b.w bl.w add.w sub.w mov.w ldr.w str.w
    mrs_msr_priv
    """.split())


def assemble(text, addr, thumb):
    """One instruction at `addr`, with capstone asked for a second opinion."""
    ks = KS_THUMB if thumb else KS_ARM
    md = MD_THUMB if thumb else MD_ARM
    code, _ = ks.asm(text.encode(), addr)
    if not code:
        raise SystemExit("cannot assemble at %08x: %s" % (addr, text))
    raw = bytes(code)
    insns = list(md.disasm(raw, addr))
    dis = "; ".join("%s %s" % (i.mnemonic, i.op_str) for i in insns)
    for i in insns:
        if i.mnemonic in LATER_THAN_V5:
            raise SystemExit("%08x: %s assembled to %s, which is not ARMv5TE"
                             % (addr, text.strip(), i.mnemonic))
    want = text.strip()
    if dis and dis.split()[0] != want.split()[0]:
        print("note: %08x  %-28s capstone: %s" % (addr, want, dis), file=sys.stderr)
    return raw


def encodable_imm(value):
    """Can `mov r0, #value` be one ARM instruction, and stay ARMv5?"""
    try:
        raw = assemble("mov r0, #0x%x" % value, RAM_BASE, False)
    except SystemExit:
        return False
    return len(raw) == 4


def const(prog, reg, value):
    """Load a 16-bit constant, in one instruction when ARMv5 can encode it."""
    if value < 0x100 or encodable_imm(value):
        prog.ins("mov %s, #0x%x" % (reg, value))
        return
    prog.ins("mov %s, #0x%x" % (reg, value & 0xFF00))
    if value & 0xFF:
        prog.ins("orr %s, %s, #0x%x" % (reg, reg, value & 0xFF))


class Prog(object):
    def __init__(self, thumb_base=THUMB_BASE):
        self.items = []
        self.thumb_base = thumb_base

    def arm(self):
        self.items.append(("mode", False))

    def thumb(self):
        self.items.append(("mode", True))

    def ins(self, text):
        self.items.append(("ins", text))

    def ins4(self, text):
        """A Thumb instruction that is a two-halfword pair (BL, BLX)."""
        self.items.append(("ins4", text))

    def label(self, name):
        self.items.append(("label", name))

    def word(self, value):
        self.items.append(("word", value))

    def label_word(self, name):
        self.items.append(("labelword", name))

    def encode(self, base):
        """Address everything, then assemble. Labels may be forward-referenced."""
        arm_next, thumb_next = base, self.thumb_base
        thumb = False
        placed = []
        labels = {}
        for kind, val in self.items:
            if kind == "mode":
                thumb = val
                continue
            addr = thumb_next if thumb else arm_next
            placed.append((addr, thumb, kind, val))
            if kind == "label":
                labels[val] = addr
            # a label does not occupy anything; a Thumb instruction is a
            # halfword unless it is a BL/BLX pair or a literal
            if kind == "label":
                step = 0
            elif thumb:
                step = 4 if kind in ("ins4", "word", "labelword") else 2
            else:
                step = 4
            if thumb:
                thumb_next = addr + step
            else:
                arm_next = addr + step

        mem = {}
        for addr, thumb, kind, val in placed:
            if kind in ("ins", "ins4"):
                text = val
                for name, target in labels.items():
                    text = text.replace("{%s}" % name, "0x%08x" % target)
                raw = assemble(text, addr, thumb)
                want = 2 if (thumb and kind == "ins") else 4
                if len(raw) != want:
                    raise SystemExit("%08x: %s is %d bytes, expected %d"
                                     % (addr, val, len(raw), want))
                if len(raw) == 2:
                    mem[addr] = (struct.unpack("<H", raw)[0], val, 2)
                elif thumb and len(raw) == 4:
                    # a Thumb BL/BLX pair: two halfwords, which may straddle a
                    # word boundary, so they are kept separately
                    lo, hi = struct.unpack("<HH", raw)
                    mem[addr] = (lo, val, 2)
                    mem[addr + 2] = (hi, "", 2)
                else:
                    mem[addr] = (struct.unpack("<I", raw)[0], val, 4)
            elif kind == "word":
                mem[addr] = (val, ".word 0x%08X" % val, 4)
            elif kind == "labelword":
                v = labels[val]
                mem[addr] = (v, ".word %s (0x%08X)" % (val, v), 4)
        return mem, labels


def emit(name, prog, base):
    mem, labels = prog.encode(base)
    words = {}
    for addr in sorted(mem):
        v, text, size = mem[addr]
        wa = addr & ~3
        if wa not in words:
            words[wa] = [0, ""]
        if size == 2:
            words[wa][0] |= (v & 0xFFFF) << (16 * ((addr - wa) // 2))
            words[wa][1] += ("" if not words[wa][1] else " ; ") + text
        else:
            words[wa][0] = v
            words[wa][1] = text
    print("")
    print("\t// ---- program %s ----" % name)
    for wa in sorted(words):
        w, c = words[wa]
        print("\tram[18'h%04X] = 32'h%08X;  // %08X  %s"
              % ((wa - RAM_BASE) >> 2, w & 0xFFFFFFFF, wa, c))
    return words, labels


#------------------------------------------------------------------
# program A: integer ARM, Thumb excursion, SWI through the high vector
#------------------------------------------------------------------
A = Prog()
A.arm()
A.ins("mov r0, #5")
A.ins("mov r1, #7")
A.ins("add r2, r0, r1")            # 12
A.ins("cmp r2, #12")
A.ins("moveq r3, #1")
A.ins("mov r5, #0x2000")
A.ins("str r2, [r5]")
A.ins("ldr r4, [r5]")              # 12
A.ins("add r6, r2, r2, lsl #2")    # 60
A.ins("subs r7, r6, #60")          # 0, Z set
A.ins("mul r8, r0, r1")            # 35
A.ins("mla r9, r0, r1, r2")        # 47
A.ins("umull r10, r11, r0, r1")    # 35, 0
A.ins("str r9, [r5, #4]")          # the MLA result
A.ins("str r11, [r5, #8]")         # UMULL high
A.ins("str r3, [r5, #12]")         # the MOVEQ result
A.ins("mvn r0, #1")                # -2
A.ins("mov r1, #3")
A.ins("smull r12, r2, r0, r1")     # FFFFFFFA, FFFFFFFF
A.ins("str r12, [r5, #16]")        # SMULL low
A.ins("mov r10, #0x02000000")
A.ins("add r10, r10, #0x100")
A.ins("add r10, r10, #1")
A.ins("bx r10")                    # into the Thumb block
A.thumb()
A.ins("movs r0, #3")
A.ins("adds r0, #4")               # 7
A.ins("bne {tskip}")
A.ins("movs r0, #0x55")
A.ins("nop")
A.label("tskip")
A.ins("ldr r3, [pc, #4]")          # the literal below
A.ins("bx r3")
A.ins("nop")
A.label_word("back")
A.arm()
A.label("back")                    # resumed in ARM after the Thumb block
A.ins("mov r11, #1")
A.ins("mov r12, #2")
A.ins("swi #0")                    # high vector 0xFFFF0008
A.ins("mrs r9, cpsr")
A.ins("bic r9, r9, #0x80")         # clear I for the IRQ test
A.ins("msr cpsr_c, r9")
A.ins("bl {sub}")
A.label("end_a")
A.ins("b {end_a}")                 # end marker
A.ins("nop")
A.ins("nop")
A.label("sub")
A.ins("mov pc, lr")


#------------------------------------------------------------------
# program B: the ARMv5TE media and memory additions
#------------------------------------------------------------------
B = Prog()
B.arm()
B.ins("mov r5, #0x2000")           # scratch pointer
B.ins("mov r0, #3")
B.ins("mov r1, #5")
B.ins("mov r2, r1, lsl #16")
B.ins("orr r2, r2, r0")            # Rm = 0x00050003
B.ins("mov r3, #7")
B.ins("mov r4, #2")
B.ins("mov r3, r3, lsl #16")
B.ins("orr r3, r3, r4")            # Rs = 0x00070002
B.ins("smulbb r6, r2, r3")         # 3*2 = 6
B.ins("str r6, [r5, #0x00]")
B.ins("smulbt r6, r2, r3")         # 3*7 = 21
B.ins("str r6, [r5, #0x04]")
B.ins("smultb r6, r2, r3")         # 5*2 = 10
B.ins("str r6, [r5, #0x08]")
B.ins("smultt r6, r2, r3")         # 5*7 = 35
B.ins("str r6, [r5, #0x0C]")
B.ins("mov r4, #1000")
B.ins("smlabb r6, r2, r3, r4")     # 1000 + 6
B.ins("str r6, [r5, #0x10]")
B.ins("mov r4, #0x10000")
B.ins("smulwb r6, r4, r3")         # (65536*2)>>16 = 2
B.ins("str r6, [r5, #0x14]")
B.ins("mov r7, #1000")
B.ins("smlawt r6, r4, r3, r7")     # (65536*7)>>16 + 1000
B.ins("str r6, [r5, #0x18]")
B.ins("mvn r7, #2")                # low half 0xFFFD = -3
B.ins("mov r0, #6")
B.ins("mov r1, #0")
B.ins("smlalbb r0, r1, r7, r3")    # 6 + (-3*2) = 0, Z set
B.ins("str r0, [r5, #0x1C]")
B.ins("str r1, [r5, #0x20]")
B.ins("mov r2, #0x40000000")
B.ins("clz r6, r2")                # 1
B.ins("str r6, [r5, #0x24]")
B.ins("mov r2, #0")
B.ins("clz r6, r2")                # 32
B.ins("str r6, [r5, #0x28]")
B.ins("mvn r2, #0x80000000")       # 0x7FFFFFFF
B.ins("mov r3, #1")
B.ins("qadd r6, r3, r2")           # saturates, Q set
B.ins("str r6, [r5, #0x2C]")       # checkpoint: Q is 1 here
B.ins("mov r2, #0x80000000")
B.ins("qsub r7, r2, r3")           # saturates the other way
B.ins("str r7, [r5, #0x30]")
B.ins("mov r2, #0x40000000")
B.ins("qdadd r6, r3, r2")          # 1 + sat(2*0x40000000)
B.ins("str r6, [r5, #0x34]")
B.ins("mov r2, #1")
B.ins("qdsub r7, r3, r2")          # 1 - 2
B.ins("str r7, [r5, #0x38]")
B.ins("mrs r6, cpsr")              # Q is sticky: still set after QSUB/QDADD
B.ins("and r6, r6, #0x08000000")
B.ins("str r6, [r5, #0xA0]")
B.ins("mrs r2, cpsr")
B.ins("bic r2, r2, #0x08000000")   # clear Q
B.ins("msr cpsr_f, r2")
B.ins("mov r2, #10")
B.ins("qadd r6, r2, r2")           # 20, no saturation
B.ins("str r6, [r5, #0x3C]")       # checkpoint: Q is 0 here
B.ins("mrs r6, cpsr")
B.ins("and r6, r6, #0x08000000")
B.ins("str r6, [r5, #0xA4]")
B.ins("mov r2, #0x2100")
B.ins("mov r3, #0x11")
B.ins("str r3, [r2]")
B.ins("mov r3, #0x22")
B.ins("str r3, [r2, #4]")
B.ins("ldrd r6, [r2]")             # 0x11, 0x22
B.ins("str r6, [r5, #0x40]")
B.ins("str r7, [r5, #0x44]")
B.ins("mov r8, #0x33")
B.ins("mov r9, #0x44")
B.ins("strd r8, [r2, #8]")
B.ins("ldrd r10, [r2, #8]")        # 0x33, 0x44
B.ins("str r10, [r5, #0x48]")
B.ins("str r11, [r5, #0x4C]")
B.ins("strd r8, [r2, #16]!")       # pre-index writeback
B.ins("str r2, [r5, #0x50]")       # the base moved by 16
B.ins("mov r12, #8")
B.ins("strd r8, [r2, r12]")        # register offset
B.ins("ldrd r10, [r2, r12]")
B.ins("str r10, [r5, #0x54]")
B.ins("str r11, [r5, #0x58]")
B.ins("mov r2, #0x2200")
B.ins("ldrh r6, [r2]")             # 0xCDEF of the seeded word
B.ins("str r6, [r5, #0x5C]")
B.ins("ldrh r6, [r2, #2]")         # 0x89AB
B.ins("str r6, [r5, #0x60]")
B.ins("ldrsb r6, [r2, #3]")        # 0xFFFFFF89
B.ins("str r6, [r5, #0x64]")
B.ins("ldrsh r6, [r2, #2]")        # 0xFFFF89AB
B.ins("str r6, [r5, #0x68]")
B.ins("strh r6, [r2, #4]")
B.ins("ldr r7, [r2, #4]")          # 0x000089AB
B.ins("str r7, [r5, #0x6C]")
const(B, "r3", 0x2301)
B.ins("ldr r6, [r3]")              # misaligned LDR: rotates right by 8
B.ins("str r6, [r5, #0x70]")
B.ins("ldrh r6, [r3]")             # misaligned LDRH: force-aligns
B.ins("str r6, [r5, #0x74]")
B.ins("ldr r6, [r2]")              # the seeded word again
const(B, "r4", 0x2310)
B.ins("str r6, [r4, #1]")          # misaligned STR: force-aligns, no rotate
B.ins("ldr r7, [r4]")
B.ins("str r7, [r5, #0x78]")
const(B, "r4", 0x2320)
B.ins("strh r6, [r4, #1]")         # misaligned STRH: force-aligns
B.ins("ldr r7, [r4]")
B.ins("str r7, [r5, #0x7C]")
B.ins("msr cpsr_c, #0x1f")         # SYS: set the user bank's sp and lr
B.ins("mov r13, #0x77")
B.ins("mov r14, #0x88")
B.ins("msr cpsr_c, #0xd2")         # IRQ mode, I and F set
B.ins("mov r13, #0x99")            # this mode's own sp
B.ins("mov r14, #0")
B.ins("mov r2, #0x2400")
B.ins("stmia r2, {r13, r14}^")     # stores the USER sp and lr
B.ins("ldr r6, [r2]")
B.ins("str r6, [r5, #0x80]")       # 0x77
B.ins("ldr r6, [r2, #4]")
B.ins("str r6, [r5, #0x84]")       # 0x88
B.ins("mov r6, #0xaa")
B.ins("str r6, [r2]")
B.ins("mov r6, #0xbb")
B.ins("str r6, [r2, #4]")
B.ins("ldmia r2, {r13, r14}^")     # loads them into the user bank
B.ins("mov r6, r13")
B.ins("str r6, [r5, #0x88]")       # the IRQ sp is untouched
B.ins("mov r6, r14")
B.ins("str r6, [r5, #0x8C]")
B.ins("msr cpsr_c, #0x1f")         # SYS: read the user bank back
B.ins("mov r6, r13")
B.ins("str r6, [r5, #0x90]")       # 0xAA
B.ins("mov r6, r14")
B.ins("str r6, [r5, #0x94]")       # 0xBB
B.ins("msr cpsr_c, #0x13")         # back to SVC
B.ins("mov r2, #0x2500")
B.ins("mov r3, #0xaa")
B.ins("str r3, [r2]")
B.ins("mov r4, #0xbb")
B.ins("swp r6, r4, [r2]")          # r6 = 0xaa, memory = 0xbb
B.ins("str r6, [r5, #0x98]")
B.ins("ldr r7, [r2]")
B.ins("str r7, [r5, #0x9C]")
B.label("end_b")
B.ins("b {end_b}")


#------------------------------------------------------------------
# program C: CP15, the low vector, the prefetch abort, Thumb v5T
#------------------------------------------------------------------
C = Prog(thumb_base=RAM_BASE + 0x200)
C.arm()
C.ins("mov r5, #0x2000")
C.ins("mrc p15, 0, r6, c0, c0, 0")   # main ID
C.ins("str r6, [r5, #0x00]")
C.ins("mrc p15, 0, r6, c0, c0, 1")   # cache type
C.ins("str r6, [r5, #0x04]")
C.ins("mrc p15, 0, r6, c1, c0, 0")   # control: the post-BIOS value
C.ins("str r6, [r5, #0x08]")
const(C, "r6", 0x1234)
C.ins("mcr p15, 0, r6, c2, c0, 0")   # translation table base
C.ins("mrc p15, 0, r7, c2, c0, 0")
C.ins("str r7, [r5, #0x0C]")
const(C, "r6", 0x5678)
C.ins("mcr p15, 0, r6, c9, c1, 0")   # data TCM configuration
C.ins("mrc p15, 0, r7, c9, c1, 0")
C.ins("str r7, [r5, #0x10]")
const(C, "r6", 0x9abc)
C.ins("mcr p15, 0, r6, c5, c0, 0")   # access permission
C.ins("mrc p15, 0, r7, c5, c0, 0")
C.ins("str r7, [r5, #0x14]")
const(C, "r6", 0x0def)
C.ins("mcr p15, 0, r6, c1, c0, 1")   # auxiliary control
C.ins("mrc p15, 0, r7, c1, c0, 1")
C.ins("str r7, [r5, #0x18]")
C.ins("mrc p15, 0, r7, c7, c5, 0")   # maintenance is write-only
C.ins("str r7, [r5, #0x1C]")
C.ins("mrc p15, 0, r6, c1, c0, 0")
C.ins("bic r6, r6, #0x2000")         # clear V: vectors to 0x00000000
C.ins("mcr p15, 0, r6, c1, c0, 0")
C.ins("mrc p15, 0, r7, c1, c0, 0")
C.ins("str r7, [r5, #0x20]")
C.ins("mov r6, #0")
C.ins("mcr p15, 0, r6, c6, c0, 0")   # start with a clear fault address
C.ins("mov r6, #1")
C.ins("swi #0x123")                  # low vector 0x00000008
C.ins("mov r7, #2")
C.ins("str r7, [r5, #0x24]")         # back from the SWI
const(C, "r6", 0x1111)
C.label("bkpt_site")
C.ins("bkpt #0x123")                 # -> low vector 0x0000000C
C.ins("mov r7, #3")
C.ins("str r7, [r5, #0x28]")         # resumed past the breakpoint
C.ins("mrc p15, 0, r6, c6, c0, 0")
C.ins("str r6, [r5, #0x2C]")         # c6 is still 0: only a data abort
                                     # writes the fault address
C.ins("mcr p1, 0, r0, c0, c0, 0")    # coprocessor 1: undefined on the DS
C.ins("mov r7, #4")
C.ins("str r7, [r5, #0x48]")         # resumed past the undefined opcode
C.ins("msr cpsr_f, #0xf0000000")     # N, Z, C, V set and Q cleared
C.ins("mrs r6, cpsr")
C.ins("str r6, [r5, #0x30]")
C.ins("msr cpsr_f, #0x00000000")     # and cleared again
C.ins("mrs r6, cpsr")
C.ins("str r6, [r5, #0x34]")
C.ins("mov r7, #0x02000000")
C.ins("add r7, r7, #0x300")          # a stack inside main RAM
C.ins("mov r13, r7")
C.ins("mov r10, #0x02000000")
C.ins("add r10, r10, #0x200")
C.ins("add r10, r10, #1")
C.ins("bx r10")                      # into the Thumb block
C.thumb()
C.ins("movs r0, #1")
C.ins("push {r0, r1}")               # Thumb PUSH on the RAM stack
C.ins("movs r0, #0")
C.ins("movs r1, #0")
C.ins("pop {r0, r1}")                # r0 = 1, r1 = 0
C.ins("bkpt #7")                     # Thumb breakpoint: prefetch abort, and
                                     # LR_abt = A+4 in Thumb too
C.ins("nop")                         # the return lands past this halfword
C.ins("movs r7, #5")                 # resumed past the breakpoint, in Thumb
C.ins4("blx {c_arm}")                # Thumb BLX into ARM, with a link
C.arm()
C.label("c_arm")
C.ins("mov r11, #1")                 # reached in ARM state through BLX
C.ins("mov r12, #2")
C.ins("str r0, [r5, #0x38]")
C.ins("str r7, [r5, #0x3C]")
C.ins("str r11, [r5, #0x40]")
C.ins("str r14, [r5, #0x44]")        # the BLX return address
C.label("end_c")
C.ins("b {end_c}")


#------------------------------------------------------------------
# exception vectors: return from the exception (CPSR <- SPSR)
#------------------------------------------------------------------
VEC = Prog()
VEC.arm()
VEC.ins("movs pc, lr")


# the vectors the bench seats: return-from-exception (CPSR <- SPSR) at the
# undefined, SWI, prefetch-abort and IRQ entries of both pages
VECTOR_OFFSETS = (("lo", 0x04), ("lo", 0x08), ("lo", 0x0C),
                  ("hi", 0x04), ("hi", 0x08), ("hi", 0x0C), ("hi", 0x18))


def fragments():
    """The bench's program data, as the text of an include file."""
    out = ["// Generated by tools/gen_arm9_programs.py — do not edit by hand.",
           "//",
           "// The benches' programs, assembled by keystone and checked with",
           "// capstone, loaded over main RAM. Each program starts from a clean",
           "// register file and the CP15 reset values.",
           ""]
    for name, prog in (("a", A), ("b", B), ("c", C)):
        mem, _ = prog.encode(RAM_BASE)
        words = {}
        for addr in sorted(mem):
            v, text, size = mem[addr]
            wa = addr & ~3
            if wa not in words:
                words[wa] = [0, ""]
            if size == 2:
                words[wa][0] |= (v & 0xFFFF) << (16 * ((addr - wa) // 2))
                words[wa][1] += ("" if not words[wa][1] else " ; ") + text
            else:
                words[wa][0] = v
                words[wa][1] = text
        out.append("task load_%s;" % name)
        out.append("\tbegin")
        out.append("\t\tfor (li = 0; li < 65536; li = li + 1) ram[li] = 32'h0000_0000;")
        for wa in sorted(words):
            w, comment = words[wa]
            out.append("\t\tram[18'h%04X] = 32'h%08X;  // %08X  %s"
                       % ((wa - RAM_BASE) >> 2, w & 0xFFFFFFFF, wa, comment))
        out.append("\tend")
        out.append("endtask")
        out.append("")
    word = VEC.encode(0)[0][0][0]
    out.append("// the exception vectors: return from the exception (CPSR <- SPSR)")
    out.append("task load_vectors;")
    out.append("\tbegin")
    for arr, off in VECTOR_OFFSETS:
        out.append("\t\t%s[14'h%04X] = 32'h%08X;   // %08X"
                   % (arr, off >> 2, word, off))
    out.append("\tend")
    out.append("endtask")
    return "\n".join(out) + "\n"


def main():
    text = fragments()
    if len(sys.argv) > 1 and sys.argv[1] == "--write":
        with open("tb/tb_arm9_prog.svh", "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print("wrote tb/tb_arm9_prog.svh (%d lines)" % text.count("\n"))
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
