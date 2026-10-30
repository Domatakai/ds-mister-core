#!/usr/bin/env python3
"""Golden vectors for tb/tb_spu.sv.

The SPU bench compares the RTL against these numbers, so they are produced
here by an independent implementation of the documented decode and of the
core's published scaling chain (see the header of rtl/audio/spu.sv):

  ADPCM nibble (GBATEK staged-shift form)
    step = table[index]; diff = step>>3
           + (step>>2 if bit0) + (step>>1 if bit1) + step if bit2
    predictor +/- diff (bit3 is the sign), clamped to +/-7FFF
    index += {-1,-1,-1,-1,+2,+4,+6,+8}[nibble&7], clamped to 0..88

  chain, signed (Python's >> floors, like Verilog's >>>):
    sample x volume/128 -> >> divider -> pan
      left  = v * (128-pan) / 128,  right = v * pan / 128
    master volume /128, then the OSD volume (gain = volume*25) /256, clamp

Host memory map the bench uses, all inside main RAM at 0x02000000:

  0x00  PCM8 one-shot, 16 bytes          (LEN=4 words)
  0x10  PCM16 one-shot, 16 bytes         (LEN=4 words)
  0x20  ADPCM A one-shot, header + 16B   (PNT=0  LEN=5)
  0x40  ADPCM C loop, 4 words            (PNT=2  LEN=2)
  0x50  ADPCM B index clamp, 4 words     (PNT=0  LEN=4)
  0x60  PCM8 loop buffer, 4 words        (PNT=2  LEN=2)
  0x70  constant 0x40 buffer, 16 bytes   (LEN=4 words)

Run:  python tools/gen_spu_vectors.py     (prints the Verilog fragments)
"""

ROM_STEP = [
    0x0007, 0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E,
    0x0010, 0x0011, 0x0013, 0x0015, 0x0017, 0x0019, 0x001C, 0x001F,
    0x0022, 0x0025, 0x0029, 0x002D, 0x0032, 0x0037, 0x003C, 0x0042,
    0x0049, 0x0050, 0x0058, 0x0061, 0x006B, 0x0076, 0x0082, 0x008F,
    0x009D, 0x00AD, 0x00BE, 0x00D1, 0x00E6, 0x00FD, 0x0117, 0x0133,
    0x0151, 0x0173, 0x0198, 0x01C1, 0x01EE, 0x0220, 0x0256, 0x0292,
    0x02D4, 0x031C, 0x036C, 0x03C3, 0x0424, 0x048E, 0x0502, 0x0583,
    0x0610, 0x06AB, 0x0756, 0x0812, 0x08E0, 0x09C3, 0x0ABD, 0x0BD0,
    0x0CFF, 0x0E4C, 0x0FBA, 0x114C, 0x1307, 0x14EE, 0x1706, 0x1954,
    0x1BDC, 0x1EA5, 0x21B6, 0x2515, 0x28CA, 0x2CDF, 0x315B, 0x364B,
    0x3BB9, 0x41B2, 0x4844, 0x4F7E, 0x5771, 0x602F, 0x69CE, 0x7462,
    0x7FFF,
]
IDX_DELTA = [-1, -1, -1, -1, 2, 4, 6, 8]


def adpcm_nibble(pred, index, nib):
    """One documented decode step; returns (predictor, index)."""
    step = ROM_STEP[index]
    diff = step >> 3
    if nib & 1:
        diff += step >> 2
    if nib & 2:
        diff += step >> 1
    if nib & 4:
        diff += step
    pred = pred - diff if (nib & 8) else pred + diff
    pred = max(-0x7FFF, min(0x7FFF, pred))
    index = max(0, min(88, index + IDX_DELTA[nib & 7]))
    return pred, index


def adpcm_segment(header_pred, header_idx, data_bytes):
    """Decode one ADPCM segment: a 4-byte header, then low nibble first."""
    pred = header_pred
    index = min(header_idx, 88)          # the header index is clamped on load
    out = []
    for b in data_bytes:
        for nib in (b & 0x0F, b >> 4):
            pred, index = adpcm_nibble(pred, index, nib)
            out.append(pred)
    return out


def pcm8(v):
    """Signed 8-bit sample as the SPU uses it (sample << 8)."""
    return ((v ^ 0x80) - 0x80) << 8


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


def chain(sample, vol=127, div=0, pan=64, master=127, osd_gain=250):
    """The core's scaling chain; returns [left, right]."""
    vm = 128 if vol == 127 else vol
    pm = 128 if pan == 127 else pan
    dsh = [0, 1, 2, 4][div]
    v = ((sample * vm) >> 7) >> dsh
    left = (v * (128 - pm)) >> 7
    right = (v * pm) >> 7
    mm = 128 if master == 127 else master
    out = []
    for side in (left, right):
        out.append(((side * mm) >> 7 * osd_gain) >> 8 if False else
                   (((side * mm) >> 7) * osd_gain) >> 8)
    return out


def adpcm_play(header, data, pnt, ln, loops):
    """Sample-by-sample model of the SPU's ADPCM playback.

    header: (predictor, step index) from the 32-bit header word at SAD
    data:   the bytes that follow the header
    pnt/ln: SOUNDxPNT and SOUNDxLEN, in words
    loops:  how many loop bodies to play after the first pass

    The header is read at SAD — and again on every loop when the loop point
    is 0, since that is where it lives.  Otherwise GBATEK's rule applies:
    the loop start is in the data, and "the index and pcm16 values are
    reloaded to the values that have originally appeared at that location",
    so the decoder state as the position passes byte 4*PNT is snapshotted
    and restored on each loop (melonDS's ADPCMValLoop/ADPCMIndexLoop,
    DeSmuME's loop_pcm16b/loop_index).  Returns the decoded samples.
    """
    loop_n = 8 * pnt          # nibble index of the loop point
    end_n  = 8 * (pnt + ln)   # nibble index one past the segment
    pred, index = header
    index = min(index, 88)
    snap = (pred, index)
    out = []
    nxt = 8                   # the first nibble after the header
    for _ in range(loops + 1):
        n = nxt
        while n < end_n:
            if n == loop_n:
                snap = (pred, index)
            byte = data[(n >> 1) - 4]   # nibble n is in data byte (n-8)/2
            nib = (byte >> 4) if (n & 1) else (byte & 0xF)
            pred, index = adpcm_nibble(pred, index, nib)
            out.append(pred)
            n += 1
        if loop_n == 0:
            pred, index = header                    # the header is re-read
            index = min(index, 88)
            nxt = 8
        else:
            pred, index = snap
            nxt = loop_n
    return out


def collapse(vals):
    """Consecutive equal values are one entry: the bench watches the output
    on every 48 kHz tick but records a new entry only when it changes."""
    out = []
    for v in vals:
        if not out or out[-1] != v:
            out.append(v)
    return out


def show(name, vals):
    print("// %s: %s" % (name, ", ".join(str(v) for v in vals)))
    coll = collapse(vals)
    if len(coll) != len(vals):
        print("// %s (collapsed): %s" % (name, ", ".join(str(v) for v in coll)))


def words(data):
    out = []
    for i in range(0, len(data), 2):
        hi = data[i + 1] if i + 1 < len(data) else 0
        out.append(data[i] | (hi << 8))
    return out


def emit(comment, data, first):
    print("  // %s (byte 0x%02X, RAM word %d)" % (comment, first * 2, first))
    for i, w in enumerate(words(data)):
        print("\tmem[%d] = 16'h%04X;" % (first + i, w))
    print()


def main():
    print("// generated by tools/gen_spu_vectors.py\n")

    # ---- PCM8 one-shot, 16 samples (no zero sample: the bench detects each
    #      new output value as a change from the idle 0)
    pcm8_data = [0x40, 0x41, 0xC0, 0x80, 0x7F, 0x81, 0x01, 0xFF,
                 0x20, 0xE0, 0x55, 0xAB, 0x10, 0xF0, 0x05, 0x33]
    print("// PCM8  : " + ", ".join(str(pcm8(v)) for v in pcm8_data))
    print("// out    : " + ", ".join(str(chain(pcm8(v))[0]) for v in pcm8_data))
    print()
    emit("PCM8 one-shot", pcm8_data, 0)

    # ---- PCM16 one-shot, 8 samples
    pcm16_data = [0x0100, 0xFF00, 0x7FFF, 0x8000,
                  0x0001, 0xFFFF, 0x1234, 0xEDCC]
    print("// PCM16  : " + ", ".join(str(s16(v)) for v in pcm16_data))
    print("// out    : " + ", ".join(str(chain(s16(v))[0]) for v in pcm16_data))
    print()
    emit("PCM16 one-shot", [b for w in pcm16_data for b in (w & 0xFF, w >> 8)], 8)

    # ---- ADPCM A: one-shot, header (predictor 0x0100, index 5) + 16 data
    data_a = [0x12, 0x34, 0x87, 0x65, 0x0F, 0xF0, 0x9C, 0x3A,
              0x77, 0x11, 0xEE, 0x55, 0xA5, 0x5A, 0xC3, 0x24]
    stream_a = [0x00, 0x01, 0x05, 0x00] + data_a
    dec_a = adpcm_segment(0x0100, 5, data_a)
    print("// ADPCM A: 32 samples")
    print("// decoded: " + ", ".join(str(v) for v in dec_a))
    print("// out    : " + ", ".join(str(chain(v)[0]) for v in dec_a))
    print()
    emit("ADPCM A", stream_a, 16)

    # ---- ADPCM C: ADPCM loop, PNT=2 LEN=2 (the loop point is in the data,
    #      not on a header), so the state at byte 8 is snapshotted and
    #      restored.  The first pass is 24 samples; the loop body is the last
    #      16 of them, and it repeats exactly.
    stream_c = [0x00, 0x00, 0x00, 0x00, 0x13, 0x57, 0x9B, 0xDF,
                0x00, 0x02, 0x00, 0x00, 0x18, 0x42, 0xA6, 0xE1]
    samples_c = adpcm_play((0x0000, 0), stream_c[4:], 2, 2, 1)
    print("// ADPCM C: %d samples (first pass 24, loop body 16)" % len(samples_c))
    print("// decoded: " + ", ".join(str(v) for v in samples_c))
    show("ADPCM C out", [chain(v)[0] for v in samples_c])
    print()
    emit("ADPCM C loop", stream_c, 32)

    # ---- ADPCM B: header index 100 must clamp to 88
    data_b = [0x00] * 12
    dec_b = adpcm_segment(0x0000, 100, data_b)
    stream_b = [0x00, 0x00, 0x64, 0x00] + data_b
    print("// ADPCM B (index 100 -> 88): " + ", ".join(str(v) for v in dec_b[:8]))
    print("// out                      : " +
          ", ".join(str(chain(v)[0]) for v in dec_b[:8]))
    print()
    emit("ADPCM B clamp", stream_b, 40)

    # ---- PCM8 loop buffer (PNT=2 words = 8 bytes, LEN=2 words = 8 bytes)
    loop_data = [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x78,
                 0x70, 0x60, 0x50, 0x40, 0x30, 0x20, 0x10, 0x08]
    show("PCM8 loop x2", ([chain(pcm8(v))[0] for v in loop_data[:8]] +
                          [chain(pcm8(v))[0] for v in loop_data[8:]] * 2))
    print()
    emit("PCM8 loop", loop_data, 48)

    # ---- constant 0x40 buffer for the volume/pan/master checks
    print("// constant PCM8 0x40 (sample 16384): out 8000 at unity")
    print("//   x volume 64/128  -> 4000,  divider /2 -> 4000, /16 -> 500")
    print("//   pan 0 -> L 16000 R 0,  pan 127 -> L 0 R 16000")
    print("//   master 64 -> 4000")
    print()
    emit("constant 0x40", [0x40] * 16, 56)


if __name__ == "__main__":
    main()
