#!/usr/bin/env python3
"""
Pipeline timing simulation for the Deniser FPGA.
Models the denise.vhdl pipeline with collapsed E+F+G+H stages.

Key design points modeled:
  - Sprite HPOS match uses r.c.h (pre-increment / registered HPOS)
  - HBLANK/DIW comparisons use v.c.h (post-increment)
  - Stages E, F, G, H are combinational (feed-forward via v.*)
  - Only stages A->B->C->D are registered (pipelined)
  - Output is registered at H (r.h), so total depth = D + H_reg = 2 CLK7
    from stage D internal values to output.
  - Playfield pixels extract from bpld at bit position 'scroll' (pf1h),
    with scroll=0 reading bit 0 (fastest: 1 shift cycle after bpl load).
"""

class Sim:
    def __init__(self, scroll=0, sprite_hpos_delay=3):
        """scroll: pf1h scroll value 0-15, selects bit from bpld.
        sprite_hpos_delay: SPRITE_HPOS_DELAY constant from VHDL.
        """
        self.cycle = 0
        self.scroll = scroll  # pf1h: bit position to extract from bpld
        self.sprite_hpos_delay = sprite_hpos_delay
        # Registered state (r.*)
        self.r = {
            'a_sel': None, 'a_data': 0,
            'b_sel': None, 'b_data': 0,
            'c_h': 2,              # HPOS starts at 2
            'c_hblank': False,
            'c_diw': False,        # display window active
            'c_bpldat': 0,
            'c_bpltrig': False,
            'c_spr_sh': 0,         # sprite HPOS target
            'c_spr_en': False,
            'c_spr_data': 0,
            'd_bpl': 0,            # 16-bit shift register
            'd_bpld': 0,           # 16-bit scroll delay buffer
            'd_spr': 0,            # sprite shift register
            'h_rgb': 0,            # output pixel
            'h_tag': '',           # what produced the output
            'h_blanked': False,
        }
        self.log = []

    def tick(self, bus_sel=None, bus_data=0):
        """One CLK7 cycle. bus_sel: 'bpldat','sprpos','sprdata' or None.
        Returns (out_tag, out_blanked) from the REGISTERED output (r.h).
        """
        r = self.r
        v = dict(r)  # v starts as copy of r (next state)

        # ============================================================
        # Stage A: latch bus input
        # ============================================================
        v['a_sel'] = bus_sel
        v['a_data'] = bus_data

        # ============================================================
        # Stage B: decode (from r.a)
        # ============================================================
        v['b_sel'] = r['a_sel']
        v['b_data'] = r['a_data']

        # ============================================================
        # Stage C: register writes, HPOS counter
        # ============================================================
        v['c_h'] = r['c_h'] + 1       # post-increment (v.c.h)
        v_c_h = v['c_h']              # used for HBLANK/DIW comparisons

        # BPL1DAT write
        v['c_bpltrig'] = False
        if r['b_sel'] == 'bpldat':
            v['c_bpldat'] = r['b_data']
            v['c_bpltrig'] = True
            self.log.append((self.cycle, f"C: BPL1DAT=0x{r['b_data']:04x}, bpltrig=1"))

        # Sprite position/data writes
        if r['b_sel'] == 'sprpos':
            v['c_spr_sh'] = r['b_data'] & 0x1FF
            v['c_spr_en'] = True
            self.log.append((self.cycle, f"C: SPR0POS HPOS target={v['c_spr_sh']}"))

        if r['b_sel'] == 'sprdata':
            v['c_spr_data'] = r['b_data']
            self.log.append((self.cycle, f"C: SPR0DATA=0x{r['b_data']:04x}"))

        # HBLANK comparisons (use v.c.h = post-increment)
        v['c_hblank'] = r['c_hblank']
        if v_c_h == 0x013:
            v['c_hblank'] = True
            self.log.append((self.cycle, f"C: HBLANK START v.c.h=0x{v_c_h:03x}"))
        if v_c_h == 0x061:
            v['c_hblank'] = False
            self.log.append((self.cycle, f"C: HBLANK END v.c.h=0x{v_c_h:03x}"))

        # ============================================================
        # Stage D: shift registers
        # ============================================================

        # bpld: shift left, MSB of REGISTERED bpl feeds into LSB
        old_bpl_msb = (r['d_bpl'] >> 15) & 1
        v['d_bpld'] = ((r['d_bpld'] << 1) | old_bpl_msb) & 0xFFFF

        # bpl: load (if bpltrig) or shift left
        if r['c_bpltrig']:
            v['d_bpl'] = r['c_bpldat']
            self.log.append((self.cycle,
                f"D: bpl LOADED=0x{r['c_bpldat']:04x}"))
        else:
            v['d_bpl'] = (r['d_bpl'] << 1) & 0xFFFF

        # Sprite: shift left (default), or load on HPOS match
        v['d_spr'] = (r['d_spr'] << 1) & 0xFFFF

        # Sprite HPOS match: (r.c.h - SPRITE_HPOS_DELAY) == spr.sh
        # This delays the sprite load, shifting sprites rightward.
        spr_cmp = (r['c_h'] - self.sprite_hpos_delay) & 0x1FF
        if r['c_spr_en'] and spr_cmp == r['c_spr_sh']:
            v['d_spr'] = r['c_spr_data']
            self.log.append((self.cycle,
                f"D: SPRITE MATCH (r.c.h-{self.sprite_hpos_delay})="
                f"{spr_cmp}, r.c.h={r['c_h']}, loaded data"))

        # ============================================================
        # Stages E+F+G+H: COMBINATIONAL from r.d (registered D output)
        # ============================================================

        # Pixel extraction: read bpld at scroll position (not MSB!)
        pf_pixel = (r['d_bpld'] >> self.scroll) & 1
        spr_pixel = (r['d_spr'] >> 15) & 1

        # Blanking: combinational from r.c.hblank (chain v.e->v.f->v.g)
        hblank = r['c_hblank']

        # Priority + color lookup (combinational)
        tag = ''
        rgb = 0
        if spr_pixel:
            tag = 'SPRITE'
            rgb = 0xF00
        elif pf_pixel:
            tag = 'PLAYFLD'
            rgb = 0x00F

        blanked = hblank
        if blanked:
            rgb = 0

        # Register at stage H output
        v['h_rgb'] = rgb
        v['h_tag'] = tag
        v['h_blanked'] = blanked

        # ============================================================
        # OUTPUT: r.h (previous cycle's v.h registration)
        # ============================================================
        out_tag = r['h_tag']
        out_blanked = r['h_blanked']
        out_rgb = r['h_rgb']

        # Advance state
        self.r = v
        self.cycle += 1

        return out_tag, out_blanked, out_rgb


def measure_latency(label, stim_cycle, out_cycle):
    lat = out_cycle - stim_cycle
    print(f"  {label}: {lat} CLK7 ({lat*2} hires pixels)")
    return lat


# ====================================================================
# TEST 1: HBLANK latency
# ====================================================================
def test_hblank():
    print("\n=== TEST 1: HBLANK Latency ===")
    print("  HPOS resets to 2.  HBLANK comparison at v.c.h == 0x013.")
    sim = Sim()
    hblank_compare_cycle = None
    hblank_output_cycle = None

    for i in range(30):
        _, out_blanked, _ = sim.tick()
        if hblank_output_cycle is None and out_blanked:
            hblank_output_cycle = sim.cycle - 1

    for cyc, msg in sim.log:
        if 'HBLANK START' in msg:
            hblank_compare_cycle = cyc
            print(f"    {msg} at cycle {cyc}")

    if hblank_compare_cycle is not None and hblank_output_cycle is not None:
        print(f"    First blanked output at cycle {hblank_output_cycle}")
        measure_latency("HBLANK compare -> blanked output",
                        hblank_compare_cycle, hblank_output_cycle)
    else:
        print("  ERROR: HBLANK never appeared!")


# ====================================================================
# TEST 2: Playfield latency with scroll offset
# ====================================================================
def test_playfield():
    print("\n=== TEST 2: Playfield Latency (BPL1DAT -> pixel output) ===")

    for scroll in [0, 7, 15]:
        print(f"\n  --- scroll (pf1h) = {scroll} ---")
        sim = Sim(scroll=scroll)
        write_cycle = 5

        pf_output_cycle = None
        for i in range(40):
            if i == write_cycle:
                tag, _, _ = sim.tick(bus_sel='bpldat', bus_data=0xFFFF)
            else:
                tag, _, _ = sim.tick()

            if pf_output_cycle is None and tag == 'PLAYFLD':
                pf_output_cycle = sim.cycle - 1

        for cyc, msg in sim.log:
            print(f"    Cycle {cyc}: {msg}")

        if pf_output_cycle is not None:
            print(f"    First playfield pixel output at cycle {pf_output_cycle}")
            measure_latency("BPL1DAT bus write -> playfield output",
                            write_cycle, pf_output_cycle)
        else:
            print("    WARNING: No playfield pixel appeared in 40 cycles!")


# ====================================================================
# TEST 3: Sprite latency
# ====================================================================
def test_sprite():
    print("\n=== TEST 3: Sprite Latency (HPOS match -> pixel output) ===")

    for delay in [0, 3, 4]:
        print(f"\n  --- SPRITE_HPOS_DELAY = {delay} ---")
        sim = Sim(sprite_hpos_delay=delay)
        target_hpos = 20

        # Pre-load sprite config directly into stage C registers
        sim.r['c_spr_sh'] = target_hpos
        sim.r['c_spr_en'] = True
        sim.r['c_spr_data'] = 0xFFFF

        match_cycle = None
        spr_output_cycle = None

        for i in range(35):
            tag, _, _ = sim.tick()
            if spr_output_cycle is None and tag == 'SPRITE':
                spr_output_cycle = sim.cycle - 1

        for cyc, msg in sim.log:
            if 'MATCH' in msg:
                match_cycle = cyc
                print(f"    {msg} at cycle {cyc}")

        if match_cycle is not None and spr_output_cycle is not None:
            print(f"    First sprite output at cycle {spr_output_cycle}")
            out_hpos = spr_output_cycle + 2  # HPOS at output time
            print(f"    Output HPOS: {out_hpos} (target was {target_hpos})")
            print(f"    Sprite appears {(out_hpos - target_hpos)*2} hires pixels "
                  f"AFTER target HPOS")
            measure_latency("Sprite HPOS match -> sprite output",
                            match_cycle, spr_output_cycle)
        else:
            print("  ERROR: Sprite pixel never appeared!")


# ====================================================================
# TEST 4: Sprite vs Playfield relative alignment
# ====================================================================
def test_alignment():
    print("\n=== TEST 4: Sprite vs Playfield Alignment ===")
    print("  Both aimed at same HPOS region, scroll=0, DELAY=3.")
    print("  Question: do they appear at the same output cycle?")
    sim = Sim(scroll=0, sprite_hpos_delay=3)

    sprite_hpos = 40

    # Pre-load sprite
    sim.r['c_spr_sh'] = sprite_hpos
    sim.r['c_spr_en'] = True
    sim.r['c_spr_data'] = 0x8000  # MSB set = 1 pixel

    # BPL1DAT must be written early enough to propagate through A->B->C->D.
    # Sprite HPOS 40 is reached at cycle ~ (40 - 2) = 38.
    # With scroll=0, playfield latency from bus to output = 6 CLK7.
    # So write BPL1DAT at cycle 38 - 6 = 32 for alignment.
    # But let's use ~30 to keep it simple and see what happens.
    bpldat_write_cycle = 30

    spr_out = None
    pf_out = None
    outputs = []

    for i in range(55):
        if i == bpldat_write_cycle:
            tag, _, _ = sim.tick(bus_sel='bpldat', bus_data=0xFFFF)
        else:
            tag, _, _ = sim.tick()

        if tag:
            outputs.append((sim.cycle - 1, tag))
            if tag == 'SPRITE' and spr_out is None:
                spr_out = sim.cycle - 1
            if tag == 'PLAYFLD' and pf_out is None:
                pf_out = sim.cycle - 1

    print(f"\n  Sprite HPOS target: {sprite_hpos}")
    print(f"  BPL1DAT written at cycle: {bpldat_write_cycle}")
    print()
    for cyc, msg in sim.log:
        print(f"    Cycle {cyc}: {msg}")
    print()
    print("  Output timeline (first 12):")
    for cyc, tag in outputs[:12]:
        print(f"    Cycle {cyc}: {tag}")

    if spr_out is not None and pf_out is not None:
        diff = spr_out - pf_out
        print(f"\n  First sprite output: cycle {spr_out}")
        print(f"  First playfield output: cycle {pf_out}")
        print(f"  Difference: {diff} CLK7 ({diff*2} hires pixels)")
        if diff < 0:
            print(f"  -> Sprite {-diff} CLK7 BEFORE playfield (sprite LEFT of PF)")
        elif diff > 0:
            print(f"  -> Sprite {diff} CLK7 AFTER playfield (sprite RIGHT of PF)")
        else:
            print(f"  -> PERFECTLY ALIGNED!")
    elif spr_out is not None:
        print(f"\n  Sprite appeared at cycle {spr_out}, but no playfield pixel.")
    elif pf_out is not None:
        print(f"\n  Playfield appeared at cycle {pf_out}, but no sprite pixel.")
    else:
        print("\n  Neither sprite nor playfield appeared!")


# ====================================================================
# TEST 5: Detailed cycle-by-cycle trace
# ====================================================================
def test_trace():
    print("\n=== TEST 5: Cycle-by-Cycle Pipeline Trace ===")
    print("  BPL1DAT=0xFF00 written at cycle 5, scroll=0, DELAY=3.")
    print("  Sprite at HPOS=15, data=0xC000 (2 pixels).")
    print()

    sim = Sim(scroll=0, sprite_hpos_delay=3)
    sim.r['c_spr_sh'] = 15
    sim.r['c_spr_en'] = True
    sim.r['c_spr_data'] = 0xC000

    hdr = (f"  {'Cyc':>3} | {'HPOS':>4} | {'bus':>8} | "
           f"{'r.c.bpltrig':>11} | {'r.d.bpl':>10} | {'r.d.bpld':>10} | "
           f"{'r.d.spr':>10} | {'pf_px':>5} | {'spr_px':>6} | {'output':>8}")
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))

    for i in range(22):
        bus = ''
        if i == 5:
            tag, blanked, rgb = sim.tick(bus_sel='bpldat', bus_data=0xFF00)
            bus = 'bpldat'
        else:
            tag, blanked, rgb = sim.tick()

        r = sim.r  # this is now the NEW state (after tick)
        # For display, we want the state USED during this tick.
        # The output (tag) comes from the old r.h, and
        # E+F+G+H were computed from the old r.d and r.c.
        # After tick, sim.r is the new v that was computed.
        # Let's show the registered state that will be used NEXT cycle:
        pf_px = (sim.r['d_bpld'] >> sim.scroll) & 1  # what stage E will see next
        spr_px = (sim.r['d_spr'] >> 15) & 1

        out_str = tag if tag else '-'
        if blanked and tag:
            out_str += '(BLK)'
        elif blanked:
            out_str = 'BLANK'

        print(f"  {i:3d} | {sim.r['c_h']-1:4d} | {bus:>8s} | "
              f"{'Yes' if sim.r['c_bpltrig'] else '':>11s} | "
              f"0x{sim.r['d_bpl']:04x}    | 0x{sim.r['d_bpld']:04x}    | "
              f"0x{sim.r['d_spr']:04x}    | "
              f"{pf_px:>5d} | {spr_px:>6d} | {out_str:>8s}")


# ====================================================================
# TEST 6: Real Amiga DMA timing simulation
# ====================================================================
def test_amiga_dma():
    print("\n=== TEST 6: Amiga DMA Timing (Realistic) ===")
    print("  Simulates actual Agnus DMA bus cycles for BPL1DAT.")
    print("  On real Amiga (lores), BPL1DAT DMA writes occur every")
    print("  8 CLK7 during the active display line.")
    print("  DDFSTRT=0x38 (typical), scroll=0.")
    print()

    sim = Sim(scroll=0, sprite_hpos_delay=3)

    # Standard Amiga horizontal timing:
    # Line = 227.5 CCK = 455 hires = 227 lores CLK7
    # HPOS 0..226  (wraps, but we just run enough cycles)
    #
    # Display Data Fetch Start (DDFSTRT) = $38 = 56 decimal
    # BPL1DAT DMA happens at DDFSTRT, DDFSTRT+8, DDFSTRT+16, etc.
    # These are the HPOS values when Agnus places data on the bus.
    # (In reality Agnus drives the bus 1 CCK = 2 CLK7 before Denise
    #  latches it, but we model the Denise-side latch timing.)
    #
    # For this test we'll do first few DMA fetches.

    ddfstrt = 0x38  # = 56
    dma_interval = 8  # lores: 1 word per 8 CLK7

    # Pre-setup: sprite at HPOS 100
    sim.r['c_spr_sh'] = 100
    sim.r['c_spr_en'] = True
    sim.r['c_spr_data'] = 0xF000  # 4 sprite pixels

    outputs = []
    dma_writes = []

    for i in range(180):
        bus_sel = None
        bus_data = 0
        hpos = sim.r['c_h']  # current HPOS before increment

        # Simulate DMA: Agnus writes BPL1DAT at HPOS multiples
        if hpos >= ddfstrt and (hpos - ddfstrt) % dma_interval == 0 and hpos < ddfstrt + 160:
            bus_sel = 'bpldat'
            bus_data = 0xAAAA  # alternating pixel pattern
            dma_writes.append((i, hpos))

        tag, blanked, rgb = sim.tick(bus_sel=bus_sel, bus_data=bus_data)

        if tag and not blanked:
            outputs.append((i, sim.r['c_h']-1, tag))

    print(f"  DDFSTRT=0x{ddfstrt:02x} ({ddfstrt}), DMA interval={dma_interval}")
    print(f"  Number of DMA writes: {len(dma_writes)}")
    if dma_writes:
        print(f"  First DMA at cycle {dma_writes[0][0]} (HPOS {dma_writes[0][1]})")
        print(f"  Last DMA at cycle {dma_writes[-1][0]} (HPOS {dma_writes[-1][1]})")
    print()

    if outputs:
        print(f"  First visible pixel: cycle {outputs[0][0]} "
              f"(HPOS {outputs[0][1]}, type={outputs[0][2]})")
        # Find first PF and first sprite
        first_pf = next((o for o in outputs if o[2] == 'PLAYFLD'), None)
        first_spr = next((o for o in outputs if o[2] == 'SPRITE'), None)

        if first_pf:
            print(f"  First PLAYFLD: cycle {first_pf[0]} (HPOS {first_pf[1]})")
            pf_dma_offset = first_pf[0] - dma_writes[0][0]
            print(f"    Latency from first DMA write: {pf_dma_offset} CLK7")
        if first_spr:
            print(f"  First SPRITE:  cycle {first_spr[0]} (HPOS {first_spr[1]})")
        if first_pf and first_spr:
            diff = first_spr[0] - first_pf[0]
            if diff >= 0:
                print(f"  Sprite arrives {diff} CLK7 AFTER first playfield pixel")
            else:
                print(f"  Sprite arrives {-diff} CLK7 BEFORE first playfield pixel")
    else:
        print("  No visible pixels produced!")

    # Show output pattern around sprite
    print("\n  Pixel output around HPOS 95-110:")
    for o in outputs:
        if 95 <= o[1] <= 110:
            print(f"    Cycle {o[0]}, HPOS {o[1]}: {o[2]}")


# ====================================================================
def main():
    print("=" * 70)
    print("DENISER PIPELINE TIMING VERIFICATION")
    print("=" * 70)
    print("Models denise.vhdl collapsed pipeline (E+F+G+H combinational).")
    print("Sprite HPOS match uses (r.c.h - SPRITE_HPOS_DELAY).")
    print("HBLANK/DIW comparisons use v.c.h (post-increment).")
    print("Playfield pixel extracted from bpld at bit position 'scroll'.")
    print("Default SPRITE_HPOS_DELAY = 3 (6 hires pixel shift + 2 from r.c.h = 8 total).")

    test_hblank()
    test_playfield()
    test_sprite()
    test_alignment()
    test_trace()
    test_amiga_dma()

    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print("""
  Pipeline structure (collapsed):
    Registered stages: A -> B -> C -> D  (4 CLK7)
    Combinational:     E + F + G + H     (0 CLK7, feed-forward)
    Output register:   r.h               (+1 CLK7)

  Effective latencies (with SPRITE_HPOS_DELAY=3):
    Bus write to output:     varies (A+B+C+D+bpl/bpld shift+H_reg)
    Sprite HPOS match:       2 CLK7  (D match -> EFGH comb -> H reg -> out)
      + DELAY fires 3+1 CLK7 later (r.c.h + DELAY vs v.c.h)
      = sprite output at target_HPOS + 6 (vs real Denise ~5-6)
    HBLANK compare to output: 2 CLK7  (C compare -> EFGH comb -> H reg -> out)

  SPRITE_HPOS_DELAY shifts sprites rightward to compensate for the
  collapsed pipeline having less latency than the original Denise chip.
  Each unit = 1 CLK7 = 2 hires pixels.  Adjust if needed:
    Too far LEFT  -> increase SPRITE_HPOS_DELAY
    Too far RIGHT -> decrease SPRITE_HPOS_DELAY
""")
    print("=" * 70)
    print("DONE")
    print("=" * 70)


if __name__ == '__main__':
    main()
