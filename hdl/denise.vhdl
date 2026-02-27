--  Copyright (C) 2020-2021 Martin Åberg
--
--  This program is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; either version 2 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License along
--  with this program; if not, write to the Free Software Foundation, Inc.,
--  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ocs.all;
use work.priv.all;

entity denise is
  generic (
    CFG_STRDEBUG            : boolean := false;
    CFG_BLANK_DURING_VBLANK : boolean := true;
    CFG_ECS                 : boolean := false
  );
  port (
    deni  : in    denise_in_t;
    deno  : out   denise_out_t
  );
end;

architecture rtl of denise is
  -- In the NTSC television standard, horizontal blanking occupies
  -- 10.9 μs (17.2%) out of every 63.6 μs scan line. In PAL, it
  -- occupies 12 μs (18.8%) out of every 64 μs scan line.
  -- NTSC: main clock 28.63636 MHz
  -- PAL:  main clock 28.37516 MHz
  -- For PAL we align hblank with the Minimig/Denise reference:
  -- HPOS $13 (start) to $61 (end).
  constant HBLANK_START_PAL : natural range 0 to 511 := 16#013#;
  constant HBLANK_NCLK_PAL  : natural range 0 to 511 := 16#061#;
  constant NBURST_START_PAL : natural range 0 to 511 := 41;
  constant NBURST_NCLK_PAL  : natural range 0 to 511 := 18;

  subtype color_index_t is std_ulogic_vector(4 downto 0);
  type color_index_array_t is array (integer range <>) of color_index_t;

  type sprite_shift_t is record
    a : word_t;
    b : word_t;
  end record;

  type sprite_shift_array_t is array (integer range <>) of sprite_shift_t;
  type shreg_t is record
    bpl   : word_array_t(0 to 5);
    bpld  : word_array_t(0 to 5);
    spr   : sprite_shift_array_t(0 to 7);
  end record;

  type state_a is record
    sel       : sel_t;
    cck       : std_ulogic;
    rga       : rga_t;
  end record;

  type state_b is record
    sel       : sel_t;
    drdx      : word_t;
    colori    : color_index_t;
  end record;

  type bplcon_t is record
    hires     : std_ulogic;
    bpu       : std_ulogic_vector(2 downto 0);
    homod     : std_ulogic;
    dblpf     : std_ulogic;
    color     : std_ulogic;
    gaud      : std_ulogic;
    shres     : std_ulogic;     -- BPLCON0 bit 6 (ECS: super-hires)
    brdrblnk  : std_ulogic;     -- BPLCON0 bit 5 (ECS: blank borders)
    pf1h      : std_ulogic_vector(3 downto 0);
    pf2h      : std_ulogic_vector(3 downto 0);
    pf1p      : std_ulogic_vector(2 downto 0);
    pf2p      : std_ulogic_vector(2 downto 0);
    pf2pri    : std_ulogic;
    killehb   : std_ulogic;     -- BPLCON2 bit 9 (ECS: disable EHB)
  end record;

  type state_c is record
    -- horizontal video beam position, lores (HPOS in 7 MHz clocks)
    h         : unsigned(8 downto 0);
    -- long-line enable flag (one extra 7 MHz cycle after STRLONG)
    lol_ena   : std_ulogic;
    hblank    : std_ulogic;
    vblank    : std_ulogic;
    -- raw horizontal display window (DIWSTRT/DIWSTOP)
    hwin0     : std_ulogic;
    -- hwin0 AND per-line vertical window
    hwin1     : std_ulogic;
    -- delayed window used for pixel pipeline alignment
    hwin2     : std_ulogic;
    -- per-line vertical window (set by BPL1DAT writes)
    vwin      : std_ulogic;
    -- combined display window flag used for masking/gating
    diw       : std_ulogic;
    diwstrth  : std_ulogic_vector(8 downto 0);
    diwstoph  : std_ulogic_vector(8 downto 0);
    bplcon    : bplcon_t;
    clxcon    : std_ulogic_vector(15 downto 0);
    clxdat    : std_ulogic_vector(14 downto 0);
    bpldat    : word_array_t(0 to 5);
    spr       : sprite_reg_array_t(0 to 7);
    color     : rgb4_array_t(0 to 31);
    bpltrig   : std_ulogic;
  end record;

  type state_d is record
    bplen     : std_ulogic_vector(5 downto 0);
    shreg     : shreg_t;
  end record;

  type bplbus_array_t is array (integer range <>)
   of std_ulogic_vector(5 downto 0);

  type state_e is record
    -- 4 pixel slots: lores uses 0..1 (same), hires 0..1, SHRES 0..3
    bplbus    : bplbus_array_t(0 to 3);
    -- 8 sprites * 2 lines
    sprbus    : std_ulogic_vector(15 downto 0);
    -- pipelined blanking signals
    hblank    : std_ulogic;
    vblank    : std_ulogic;
    diw       : std_ulogic;
  end record;

  type pfp_array_t is array (integer range <>) of std_ulogic_vector(2 downto 0);

  type state_f is record
    bplcolor  : color_index_array_t(0 to 3);
    hamop     : std_ulogic_vector(1 downto 0);
    sprcolor  : std_ulogic_vector(3 downto 0);
    -- playfield X priority code (with respect to sprites)
    pfp       : pfp_array_t(0 to 3);
    -- sprite group number
    spp       : std_ulogic_vector(2 downto 0);
    -- pipelined blanking signals
    hblank    : std_ulogic;
    vblank    : std_ulogic;
    diw       : std_ulogic;
  end record;

  type state_g is record
    color     : color_index_array_t(0 to 3);
    issprite  : std_ulogic;
    hamop     : std_ulogic_vector(1 downto 0);
    -- pipelined blanking signals
    hblank    : std_ulogic;
    vblank    : std_ulogic;
    diw       : std_ulogic;
  end record;

  type state_h is record
    rgb       : rgb4_array_t(0 to 3);
    nzd       : std_ulogic_vector(0 to 3);
  end record;

  type state_t is record
    a         : state_a;
    b         : state_b;
    c         : state_c;
    d         : state_d;
    e         : state_e;
    f         : state_f;
    g         : state_g;
    h         : state_h;
    nburst    : std_ulogic;
    drd       : word_t;
    drd_oe    : std_ulogic;
    drd_ext_noe       : std_ulogic;
    drd_ext_to_denice : std_ulogic;
  end record;

  function STATE_SIMINIT return state_t is
    variable v : state_t;
  begin
    v.c.h                    := (others => '0');
    v.c.lol_ena              := '0';
    v.c.hblank               := '0';
    v.c.vblank               := '0';
    v.c.hwin0                := '0';
    v.c.hwin1                := '0';
    v.c.hwin2                := '0';
    v.c.vwin                 := '0';
    v.c.diw                  := '0';
    v.c.bplcon.shres         := '0';
    v.c.bplcon.brdrblnk      := '0';
    v.c.bplcon.pf1h          := (others => '0');
    v.c.bplcon.pf2h          := (others => '0');
    v.c.bplcon.pf1p          := (others => '0');
    v.c.bplcon.pf2p          := (others => '0');
    v.c.bplcon.killehb       := '0';
    v.f.pfp                  := (others => (others => '0'));
    v.f.spp                  := (others => '0');
    return v;
  end;

  -- joystick inputs are asynchronous to clk7
  signal m0v_sync : std_ulogic;
  signal m0h_sync : std_ulogic;
  signal m1v_sync : std_ulogic;
  signal m1h_sync : std_ulogic;
  signal joy0daty : std_ulogic_vector(7 downto 0);
  signal joy0datx : std_ulogic_vector(7 downto 0);
  signal joy1daty : std_ulogic_vector(7 downto 0);
  signal joy1datx : std_ulogic_vector(7 downto 0);

  -- Current pipeline state is in "r". Next state is in "rin".
  signal r    : state_t
-- pragma translate_off
    := STATE_SIMINIT
-- pragma translate_on
  ;
  signal rin  : state_t;

begin

  -- Main pipeline with flow from stage "a" "h".
  --  * Stage "a" and "b" is for RGA bus and register decoding.
  --  * Stage "c" does register writes.
  --  * Stage "d" and forward is where sprite and bitplane data is shifted out,
  --    including bitplane/sprite priority logic, collision detection, color
  --    lookup, HAM, and more.
  --
  -- Note that the "hires pixel clock" is double the frequency of clk7. Some
  -- logic from stage "e" and forward is "replicated" to handle the "double
  -- bandwidth" while staying in the clk7 domain. The effective hires pixel
  -- clock is achieved at the output stage with DDR registers. Thus, we trade
  -- logic resources to avoid introducing another clock. This may change in the
  -- future. (Super-hires clock is 4x clk7.)

  process (r, deni, joy0daty, joy0datx, joy1daty, joy1datx)
    variable v : state_t;
    variable readreg : boolean;
  begin
    v := r;

    v.a.cck := deni.cck;
    v.a.rga := deni.rga;
    v.a.sel := SEL_NONE;
    readreg := false;
    if deni.cck = '1' then
      v.a.sel := gen_sel(deni.rga);
      if
        v.a.sel.joy0dat = '1' or
        v.a.sel.joy1dat = '1' or
        v.a.sel.clxdat  = '1'
      then
        readreg := true;
      end if;
    end if;

    v.drd_ext_noe := '1';
    v.drd_ext_to_denice := '1';
    if deni.cck = '1' then
      v.drd_ext_noe := '0';
    end if;

    if readreg then
      v.drd_ext_noe := '1';
      v.drd_ext_to_denice := '0';
    end if;

    -- read
    v.drd_oe := '0';
    if
      r.a.sel.joy0dat = '1' or
      r.a.sel.joy1dat = '1' or
      r.a.sel.clxdat  = '1' or
      (r.a.sel.deniseid = '1' and CFG_ECS)
    then
      v.drd_oe := '1';
      v.drd_ext_noe := '0';
      v.drd_ext_to_denice := '0';
    end if;
    v.drd := (others => '-');
    if r.a.sel.joy0dat = '1' then
      v.drd := joy0daty & joy0datx;
    end if;
    if r.a.sel.joy1dat = '1' then
      v.drd := joy1daty & joy1datx;
    end if;
    if r.a.sel.clxdat = '1' then
      v.drd(r.c.clxdat'range) := r.c.clxdat;
    end if;
    -- ECS Denise identification register ($07C).
    -- Real ECS Denise returns $00FC. OCS does not respond.
    if r.a.sel.deniseid = '1' and CFG_ECS then
      v.drd := x"00FC";
    end if;

    -- register address decoder
    v.b.sel := SEL_NONE;
    if r.a.cck = '1' then
      v.b.sel := gen_sel(r.a.rga);
    end if;
    v.b.drdx := deni.drd;
    v.b.colori := r.a.rga(5 downto 1);


    --------------------------------------------------------------------
    -- Horizontal beam counter (HPOS) with STRLONG long-line support. --
    --------------------------------------------------------------------
    -- Default: keep previous values.
    v.c.h       := r.c.h;
    v.c.lol_ena := r.c.lol_ena;

    -- Reset HPOS at line start when Agnus writes STRHOR, STRVBL, or
    -- STREQU (ECS only — OCS Denise ignores STREQU for HPOS reset).
    if r.b.sel.strhor = '1' or
       r.b.sel.strvbl = '1' or
       (r.b.sel.strequ = '1' and CFG_ECS)
    then
      -- Real Denise starts lines at HPOS=2.
      v.c.h       := to_unsigned(2, v.c.h'length);
      v.c.lol_ena := '0';
      -- reset horizontal window pipeline at line start
      v.c.hwin0   := '0';
      v.c.hwin1   := '0';
      v.c.hwin2   := '0';
    else
      -- Long line: one extra 7 MHz cycle without increment.
      if r.b.sel.strlong = '1' then
        v.c.lol_ena := '1';
      elsif r.c.lol_ena = '1' then
        -- Consume the long-line cycle: hold HPOS, clear flag.
        v.c.lol_ena := '0';
      else
        -- Normal increment.
        v.c.h := r.c.h + 1;
      end if;
    end if;

    --------------------------------------------------------------------
    -- Per-line vertical "window" (used with DIW to emulate Denise).  --
    --------------------------------------------------------------------
    -- Clear vertical window early in the line (HPOS ≈ $13).
    -- Use v.c.h (post-increment) to match amiga_replacement timing
    -- where comparisons happen on cdac_f AFTER cdac_r increments HPOS.
    if v.c.h = to_unsigned(16#013#, v.c.h'length) then
      v.c.vwin := '0';
    end if;
    -- Set vertical window when BPL1DAT is written.
    if r.b.sel.bpldat(0) = '1' then
      v.c.vwin := '1';
    end if;

    --------------------------------------------------
    -- Display window start/stop and DIW generation --
    --------------------------------------------------
    -- Raw horizontal window based on DIWSTRT/DIWSTOP.
    -- Use v.c.h (post-increment) to match amiga_replacement timing.
    if std_ulogic_vector(v.c.h) = r.c.diwstrth then
      v.c.hwin0 := '1';
    end if;
    if std_ulogic_vector(v.c.h) = r.c.diwstoph then
      v.c.hwin0 := '0';
    end if;

    -- Horizontal window AND vertical window, then one-cycle pipeline.
    v.c.hwin1 := r.c.hwin0 and r.c.vwin;
    v.c.hwin2 := r.c.hwin1;
    v.c.diw   := v.c.hwin2;

    -------------------------
    -- Blanking generation --
    -------------------------
    -- Use v.c.h (post-increment) to match amiga_replacement timing.
    if v.c.h = to_unsigned(HBLANK_START_PAL, v.c.h'length) then
      v.c.hblank := '1';
    end if;
    if v.c.h = to_unsigned(HBLANK_NCLK_PAL, v.c.h'length) then
      v.c.hblank := '0';
    end if;
    if r.b.sel.strvbl = '1' or r.b.sel.strequ = '1' then
      v.c.vblank := '1';
    elsif r.b.sel.strhor = '1' then
      v.c.vblank := '0';
    end if;

    -- ref: http://eab.abime.net/showthread.php?p=1304764
    -- ref: Motorola MC1377
    -- NOTE: The width of these comparators can likely be reduced.
    if
      r.c.bplcon.color = '1' and
      v.c.h = to_unsigned(HBLANK_START_PAL, v.c.h'length)
    then
      v.nburst := '0';
    elsif
      v.c.h = to_unsigned(NBURST_START_PAL+NBURST_NCLK_PAL, v.c.h'length)
    then
      v.nburst := '1';
    end if;


    -- user writes display window start or stop
    if r.b.sel.diwstrt = '1' then
      v.c.diwstrth := '0' & r.b.drdx(7 downto 0);
    end if;
    if r.b.sel.diwstop = '1' then
      v.c.diwstoph := '1' & r.b.drdx(7 downto 0);
    end if;
    -- ECS DIWHIGH register: override H8 bits of DIWSTRT/DIWSTOP.
    if r.b.sel.diwhigh = '1' and CFG_ECS then
      v.c.diwstrth(8) := r.b.drdx(5);
      v.c.diwstoph(8) := r.b.drdx(13);
    end if;

    -- write color table register
    if false then
      for i in r.c.color'range loop
        if r.b.sel.color(i) = '1' then
          v.c.color(i) := r.b.drdx(r.c.color(i)'range);
        end if;
      end loop;
    else
      if r.b.sel.colorx = '1' then
        v.c.color(to_integer(unsigned(r.b.colori))) :=
         r.b.drdx(r.c.color(0)'range);
      end if;
    end if;

    for i in r.c.bpldat'range loop
      if r.b.sel.bpldat(i) = '1' then
        v.c.bpldat(i) := r.b.drdx;
      end if;
    end loop;
    -- A Write to "bpl1dat" triggers load of all bitplane shift registers.
    v.c.bpltrig := r.b.sel.bpldat(0);

    -- write sprite registers
    for i in r.c.spr'range loop
      if r.b.sel.spr(i).pos = '1' then
        v.c.spr(i).sh(8 downto 1) := r.b.drdx(7 downto 0);
      end if;
      if r.b.sel.spr(i).ctl = '1' then
        v.c.spr(i).sh(0) := r.b.drdx(0);
        -- NOTE: Sprite attach control bit (odd sprites)
        v.c.spr(i).att := r.b.drdx(7);
        v.c.spr(i).en := '0';
      end if;
      if r.b.sel.spr(i).data = '1' then
        v.c.spr(i).data := r.b.drdx;
        v.c.spr(i).en := '1';
      end if;
      if r.b.sel.spr(i).datb = '1' then
        v.c.spr(i).datb := r.b.drdx;
      end if;
    end loop;

    -- Bitplane and collision control registers
    if r.b.sel.bplcon0 = '1' then
      v.c.bplcon.hires  := r.b.drdx(15);
      v.c.bplcon.bpu    := r.b.drdx(14 downto 12);
      v.c.bplcon.homod  := r.b.drdx(11);
      v.c.bplcon.dblpf  := r.b.drdx(10);
      v.c.bplcon.color  := r.b.drdx( 9);
      v.c.bplcon.gaud   := r.b.drdx( 8);
      if CFG_ECS then
        v.c.bplcon.shres    := r.b.drdx(6);
        v.c.bplcon.brdrblnk := r.b.drdx(5);
      end if;
    end if;
    if r.b.sel.bplcon1 = '1' then
      v.c.bplcon.pf2h   := r.b.drdx( 7 downto  4);
      v.c.bplcon.pf1h   := r.b.drdx( 3 downto  0);
    end if;
    if r.b.sel.bplcon2 = '1' then
      v.c.bplcon.pf2pri := r.b.drdx( 6);
      v.c.bplcon.pf2p   := r.b.drdx( 5 downto  3);
      v.c.bplcon.pf1p   := r.b.drdx( 2 downto  0);
      if CFG_ECS then
        v.c.bplcon.killehb := r.b.drdx(9);
      end if;
    end if;

    if r.b.sel.clxcon = '1' then
      v.c.clxcon := r.b.drdx;
    end if;

    v.c.clxdat := (
      collision_detection_logic(r.e.sprbus, r.e.bplbus(0), r.c.clxcon) or
      collision_detection_logic(r.e.sprbus, r.e.bplbus(1), r.c.clxcon)
    );
    -- The collision data register is automatically cleared after it is read.
    if r.a.sel.clxdat = '1' then
      v.c.clxdat := (others => '0');
    end if;


    -- Pipeline blanking/DIW signals alongside pixel data (stages E→F→G).
    -- Pixel data enters the pipeline at stage E (v.e.bplbus from r.d).
    -- HBLANK/VBLANK from stage C (r.c.hblank) also enter at stage E so
    -- they travel the same number of stages to the output (stage H).
    -- At cycle N+1: r.c.hblank reflects comparison from cycle N,
    --               v.e.bplbus uses r.d from cycle N (same source cycle).
    -- This matches amiga_replacement where cblank_p4 and pf_data_p4
    -- are at the same pipeline stage.
    v.e.hblank := r.c.hblank;
    v.e.vblank := r.c.vblank;
    v.e.diw    := r.c.diw;
    v.f.hblank := r.e.hblank;
    v.f.vblank := r.e.vblank;
    v.f.diw    := r.e.diw;
    v.g.hblank := r.f.hblank;
    v.g.vblank := r.f.vblank;
    v.g.diw    := r.f.diw;


    -- parallel to serial converters

    case r.c.bplcon.bpu is
      when  "000" => v.d.bplen := "000000";
      when  "001" => v.d.bplen := "000001";
      when  "010" => v.d.bplen := "000011";
      when  "011" => v.d.bplen := "000111";
      when  "100" => v.d.bplen := "001111";
      when  "101" => v.d.bplen := "011111";
      when  "110" => v.d.bplen := "111111";
      when others => null;
    end case;

    -- Shift or load the bitplane registers.
    -- The "bpld" is for the 16-bit horizontal scroll buffer.
    for i in r.c.bpldat'range loop
      v.d.shreg.bpld(i) := (
        r.d.shreg.bpld(i)(r.d.shreg.bpld(i)'high - 1 downto 0) &
        r.d.shreg.bpl (i)(r.d.shreg.bpl (i)'high)
      );
      if r.c.bpltrig = '1' then
        v.d.shreg.bpl (i) := r.c.bpldat(i);
      else
        v.d.shreg.bpl(i) :=
         r.d.shreg.bpl (i)(r.d.shreg.bpl (i)'high - 1 downto 0) & '0';
      end if;
    end loop;

    if r.c.bplcon.shres = '1' and CFG_ECS then
      -- SHRES: shift 4 bits per CLK7 cycle (4 pixels at 35 ns each).
      -- Only bitplanes 0-3 are used in super-hires mode.
      for i in 0 to 3 loop
        v.d.shreg.bpld(i) := (
          r.d.shreg.bpld(i)(15-4 downto 0) &
          r.d.shreg.bpl (i)(15 downto 12)
        );
        if r.c.bpltrig = '1' then
          v.d.shreg.bpl(i) := r.c.bpldat(i);
        else
          v.d.shreg.bpl(i) := r.d.shreg.bpl (i)(15-4 downto 0) & "0000";
        end if;
      end loop;
    elsif r.c.bplcon.hires = '1' then
      for i in 0 to 3 loop
        v.d.shreg.bpld(i) := (
          r.d.shreg.bpld(i)(15-2 downto 0) &
          r.d.shreg.bpl (i)(15 downto 14)
        );
        if r.c.bpltrig = '1' then
          v.d.shreg.bpl(i) := r.c.bpldat(i);
        else
          v.d.shreg.bpl(i) := r.d.shreg.bpl (i)(15-2 downto 0) & "00";
        end if;
      end loop;
    end if;

    -- Shift out sprite pixels.
    for i in r.c.spr'range loop
      v.d.shreg.spr(i).a :=
       r.d.shreg.spr(i).a(r.d.shreg.spr(i).a'high - 1 downto 0) & '0';
      v.d.shreg.spr(i).b :=
       r.d.shreg.spr(i).b(r.d.shreg.spr(i).b'high - 1 downto 0) & '0';
      -- Use v.c.h (post-increment) to match amiga_replacement timing
      -- where sprite HPOS match happens on cdac_f AFTER cdac_r increment.
      if
        (r.c.spr(i).en = '1') and
        (std_ulogic_vector(v.c.h) = r.c.spr(i).sh)
      then
        v.d.shreg.spr(i).a := r.c.spr(i).data;
        v.d.shreg.spr(i).b := r.c.spr(i).datb;
      end if;
    end loop;


    -- Generate pixel bus

    if r.c.bplcon.shres = '1' and CFG_ECS then
      -- SHRES: 4 independent pixels per CLK7 cycle.
      -- Only 4 bitplanes (0-3) are used; bits 4-5 always zero.
      -- Scroll offset aligned to groups of 4 (AND "1100").
      for i in 0 to 3 loop
        v.e.bplbus(3-i)(0) := (
          r.d.bplen(0) and
          r.d.shreg.bpld(0)(to_integer(unsigned(r.c.bplcon.pf1h and "1100"))+i)
        );
        v.e.bplbus(3-i)(2) := (
          r.d.bplen(2) and
          r.d.shreg.bpld(2)(to_integer(unsigned(r.c.bplcon.pf1h and "1100"))+i)
        );
        v.e.bplbus(3-i)(4) := '0';
        v.e.bplbus(3-i)(1) := (
          r.d.bplen(1) and
          r.d.shreg.bpld(1)(to_integer(unsigned(r.c.bplcon.pf2h and "1100"))+i)
        );
        v.e.bplbus(3-i)(3) := (
          r.d.bplen(3) and
          r.d.shreg.bpld(3)(to_integer(unsigned(r.c.bplcon.pf2h and "1100"))+i)
        );
        v.e.bplbus(3-i)(5) := '0';
        if r.c.diw = '0' then
          v.e.bplbus(3-i) := (others => '0');
        end if;
      end loop;
    else
      for i in 0 to 1 loop
        if r.c.bplcon.hires = '1' then
          v.e.bplbus(1-i)(0) := (
            r.d.bplen(0) and
            r.d.shreg.bpld(0)(to_integer(unsigned(r.c.bplcon.pf1h and "1110"))+i)
          );
          v.e.bplbus(1-i)(2) := (
            r.d.bplen(2) and
            r.d.shreg.bpld(2)(to_integer(unsigned(r.c.bplcon.pf1h and "1110"))+i)
          );
          v.e.bplbus(1-i)(4) := '0';
          v.e.bplbus(1-i)(1) := (
            r.d.bplen(1) and
            r.d.shreg.bpld(1)(to_integer(unsigned(r.c.bplcon.pf2h and "1110"))+i)
          );
          v.e.bplbus(1-i)(3) := (
            r.d.bplen(3) and
            r.d.shreg.bpld(3)(to_integer(unsigned(r.c.bplcon.pf2h and "1110"))+i)
          );
          v.e.bplbus(1-i)(5) := '0';
          if r.c.diw = '0' then
            v.e.bplbus(1-i) := (others => '0');
          end if;
        else
          v.e.bplbus(i)(0) := (
            r.d.bplen(0) and
            r.d.shreg.bpld(0)(to_integer(unsigned(r.c.bplcon.pf1h)))
          );
          v.e.bplbus(i)(2) := (
            r.d.bplen(2) and
            r.d.shreg.bpld(2)(to_integer(unsigned(r.c.bplcon.pf1h)))
          );
          v.e.bplbus(i)(4) := (
            r.d.bplen(4) and
            r.d.shreg.bpld(4)(to_integer(unsigned(r.c.bplcon.pf1h)))
          );
          v.e.bplbus(i)(1) := (
            r.d.bplen(1) and
            r.d.shreg.bpld(1)(to_integer(unsigned(r.c.bplcon.pf2h)))
          );
          v.e.bplbus(i)(3) := (
            r.d.bplen(3) and
            r.d.shreg.bpld(3)(to_integer(unsigned(r.c.bplcon.pf2h)))
          );
          v.e.bplbus(i)(5) := (
            r.d.bplen(5) and
            r.d.shreg.bpld(5)(to_integer(unsigned(r.c.bplcon.pf2h)))
          );
          if r.c.diw = '0' then
            v.e.bplbus(i) := (others => '0');
          end if;
        end if;
      end loop;
      -- Replicate slots 0-1 to slots 2-3 for uniform pipeline processing.
      -- In lores, all 4 slots are identical. In hires, pairs are duplicated.
      v.e.bplbus(2) := v.e.bplbus(0);
      v.e.bplbus(3) := v.e.bplbus(1);
    end if;

    -- Transform 8 individual 2-line sprites into 4 groups of 4-line sprites.
    -- Each group has the same color registers.
    for i in 0 to 3 loop
      v.e.sprbus(4*i+3) := r.d.shreg.spr(2*i+1).b(15);
      v.e.sprbus(4*i+2) := r.d.shreg.spr(2*i+1).a(15);
      v.e.sprbus(4*i+1) := r.d.shreg.spr(2*i+0).b(15);
      v.e.sprbus(4*i+0) := r.d.shreg.spr(2*i+0).a(15);
      -- In OCS, only odd sprite ATT bit controls attachment.
      -- In ECS, either sprite's ATT bit triggers attachment.
      if (r.c.spr(2*i+1).att = '0') and
         (r.c.spr(2*i).att = '0' or not CFG_ECS) then
        -- Offset into color register space of this sprite,
        -- but only if there is a pixel.
        v.e.sprbus(4*i+3 downto 4*i+2) := std_ulogic_vector(to_unsigned(i, 2));
        if
          (r.d.shreg.spr(2*i+1).b(15) = '0') and
          (r.d.shreg.spr(2*i+1).a(15) = '0') and
          (r.d.shreg.spr(2*i+0).b(15) = '0') and
          (r.d.shreg.spr(2*i+0).a(15) = '0')
        then
          v.e.sprbus(4*i+3 downto 4*i+2) := "00";
        end if;
        if
          (r.d.shreg.spr(2*i).b(15) = '0') and
          (r.d.shreg.spr(2*i).a(15) = '0')
        then
          -- High priority sprite is not visible so low priority sprite wins.
          v.e.sprbus(4*i+1) := r.d.shreg.spr(2*i+1).b(15);
          v.e.sprbus(4*i+0) := r.d.shreg.spr(2*i+1).a(15);
        end if;
      end if;
    end loop;

    -- NOTE: Do NOT kill sprites outside DIW. Real Amiga Denise displays
    -- sprites in the border region (e.g. mouse pointer, status bar sprites,
    -- demo effects). The amiga_replacement_project confirms sprites are
    -- independent of the display window. Bitplane pixels are already
    -- correctly masked to zero outside DIW in the bplbus generation above.


    -- Display priority control: select between playfields 1, 2.
    -- The "pfp" is the selected playfield placement with respect to sprites.
    -- This thing is a bit tricky. Please see the HRM

    for i in 0 to 3 loop
      -- select color and priority for bitplanes
      if r.c.bplcon.pf2pri = '1' then
        -- Playfield 2 shall have priority according to BPLCON.
        -- It means our odd numbered planes have priority over our even planes.
        v.f.bplcolor(i) :=
         "01" & r.e.bplbus(i)(5) & r.e.bplbus(i)(3) & r.e.bplbus(i)(1);
        v.f.pfp(i) := r.c.bplcon.pf2p;
        if v.f.bplcolor(i) = "01000" then
          -- Playfield 2 says color index 0 so playfield 1 wins.
          v.f.bplcolor(i) :=
           "00" & r.e.bplbus(i)(4) & r.e.bplbus(i)(2) & r.e.bplbus(i)(0);
          v.f.pfp(i) := r.c.bplcon.pf1p;
        end if;
      else
        -- Playfield 1 shall have priority according to BPLCON.
        v.f.bplcolor(i) :=
          "00" & r.e.bplbus(i)(4) & r.e.bplbus(i)(2) & r.e.bplbus(i)(0);
        v.f.pfp(i) := r.c.bplcon.pf1p;
        if
          (v.f.bplcolor(i) = "00000") and
          ((r.e.bplbus(i)(5) or r.e.bplbus(i)(3) or r.e.bplbus(i)(1)) /= '0')
        then
          -- Playfield 1 says color index 0 so playfield 2 wins.  However, if
          -- playfield 2 also selected its color index 0, then it is
          -- transparent in both playfields. In that case, either the
          -- background color or a sprite shall be visible.
          v.f.bplcolor(i) :=
           "01" & r.e.bplbus(i)(5) & r.e.bplbus(i)(3) & r.e.bplbus(i)(1);
          v.f.pfp(i) := r.c.bplcon.pf2p;
        end if;
      end if;

      if r.c.bplcon.dblpf = '0' then
        -- Dual-playfield not enabled so bypass the priority logic above.
        -- TODO: Remember bplbus(5 downto 0) and get rid of r.f.hamop?
        v.f.bplcolor(i) := r.e.bplbus(i)(4 downto 0);
        -- HRM says:
        --   "Be careful: PF2P2 - PF2P0, bits 5-3, are priority bits for
        --   normal (non-dual) playfields."
        v.f.pfp(i) := r.c.bplcon.pf2p;
      end if;
    end loop;

    v.f.hamop := r.e.bplbus(0)(5 downto 4);
    if r.c.bplcon.dblpf = '0' then
      if r.c.bplcon.homod = '1' then
        v.f.bplcolor(0)(4) := '0';
      end if;
    end if;

    -- Select color and priority for sprites.
    v.f.spp := "111";
    v.f.sprcolor := "0000";
    for i in 3 downto 0 loop
      if r.e.sprbus(4*i+3 downto 4*i) /= "0000" then
        v.f.sprcolor := r.e.sprbus(4*i+3 downto 4*i);
        v.f.spp := std_ulogic_vector(to_unsigned(i, 3));
      end if;
    end loop;


    -- Prio between any playfield and any sprite.
    v.g.issprite := '0';
    for i in 0 to 3 loop
      if unsigned(r.f.pfp(i)) <= unsigned(r.f.spp) then
        if r.f.bplcolor(i) = "00000" and r.f.sprcolor /= "0000" then
          v.g.color(i) := '1' & r.f.sprcolor;
          if i = 0 then
            v.g.issprite := '1';
          end if;
        else
          v.g.color(i) := r.f.bplcolor(i);
        end if;
      else
        if r.f.sprcolor = "0000" then
          v.g.color(i) := r.f.bplcolor(i);
        else
          v.g.color(i) := '1' & r.f.sprcolor;
          if i = 0 then
            v.g.issprite := '1';
          end if;
        end if;
      end if;

      -- Outside the display window: show border color (COLOR00) for
      -- playfield pixels, but keep sprite colors visible. In real Amiga
      -- Denise, sprites are drawn independently of the display window.
      -- Sprite color indices have bit 4 set (registers 16-31), while
      -- playfield color indices have bit 4 clear (registers 0-15).
      -- Reference: amiga_replacement_project/denise masks only the
      -- bitplane pixel bus with the display window, not sprites.
      -- Use pipelined DIW (r.f.diw) to stay aligned with pixel data.
      if r.f.diw = '0' then
        if v.g.color(i)(4) = '0' then
          v.g.color(i) := (others => '0');
        end if;
      end if;
    end loop;
    v.g.hamop := r.f.hamop;


    -- Color lookup
    for i in 0 to 3 loop
      if isx(r.g.color(i)) then
        v.h.rgb(i) := (others => 'X');
      else
        v.h.rgb(i) := r.c.color(to_integer(unsigned(r.g.color(i))));
      end if;
    end loop;

    if r.g.issprite = '0' and (true or r.c.bplcon.hires = '0') then
      if r.c.bplcon.dblpf = '0' then
        if r.c.bplcon.homod = '1' then
          -- Feedback previous RGB output and use current HAM opcode.
          -- HAM is lores-only, so index 0 is the canonical pixel.
          v.h.rgb(0) := hold_and_modify(
            v.h.rgb(0),
            r.h.rgb(0),
            r.g.hamop,
            r.g.color(0)(3 downto 0)
          );
          v.h.rgb(1) := v.h.rgb(0);
          v.h.rgb(2) := v.h.rgb(0);
          v.h.rgb(3) := v.h.rgb(0);
        else
          -- EHB is a right-shift of looked-up color and no RGB feedback.
          -- EHB is lores-only, so propagate to all 4 slots.
          if r.g.hamop(1) = '1' and r.c.bplcon.killehb = '0' then
            v.h.rgb(0)(11 downto 8) := '0' & v.h.rgb(0)(11 downto 9);
            v.h.rgb(0)( 7 downto 4) := '0' & v.h.rgb(0)( 7 downto 5);
            v.h.rgb(0)( 3 downto 0) := '0' & v.h.rgb(0)( 3 downto 1);
            v.h.rgb(1) := v.h.rgb(0);
            v.h.rgb(2) := v.h.rgb(0);
            v.h.rgb(3) := v.h.rgb(0);
          end if;
        end if;
      end if;
    end if;

    -- ECS BRDRBLNK: blank border to black when outside display window.
    -- Use pipelined DIW (r.g.diw) to stay aligned with pixel data.
    if r.g.diw = '0' and r.c.bplcon.brdrblnk = '1' and CFG_ECS then
      for i in 0 to 3 loop
        v.h.rgb(i) := (others => '0');
      end loop;
    end if;

    -- Use pipelined HBLANK/VBLANK (r.g.*) so blanking arrives at the
    -- output at the same time as the pixel data it should gate.
    -- Without this, blanking was 3-4 CLK7 cycles ahead of pixel data,
    -- shifting the entire display to the right.
    for i in 0 to 3 loop
      if r.g.hblank = '1' then
        v.h.rgb(i) := (others => '0');
      end if;
      if r.g.vblank = '1' and CFG_BLANK_DURING_VBLANK then
        v.h.rgb(i) := (others => '0');
      end if;
    end loop;

    for i in 0 to 3 loop
      v.h.nzd(i) := '1';
      if r.g.color(i) = "00000" then
        v.h.nzd(i) := '0';
      end if;
      if r.g.vblank = '1' then
        v.h.nzd(i) := r.c.bplcon.gaud;
      end if;
    end loop;

    if CFG_STRDEBUG then
      -- debug output for various Agnus sync strobes
      if r.b.sel.strhor   = '1' then v.h.rgb(0) := x"0f0"; end if;
      if r.b.sel.strvbl   = '1' then v.h.rgb(0) := x"f00"; end if;
      if r.b.sel.strequ   = '1' then v.h.rgb(0) := x"00f"; end if;
      if r.b.sel.strlong  = '1' then v.h.rgb(0) := x"f0f"; end if;
    end if;

    rin <= v;
  end process;

  -- Update all clk7 registers for the pipeline.
  r <= rin when rising_edge(deni.clk7);

  -- Drive the outputs, registered.
  deno.drd                <= r.drd;
  deno.drd_oe             <= r.drd_oe;
  deno.rgb                <= r.h.rgb;
  deno.nburst             <= r.nburst;
  deno.nzd                <= r.h.nzd;
  deno.drd_ext_noe        <= r.drd_ext_noe;
  deno.drd_ext_to_denice  <= r.drd_ext_to_denice;


  -- The mouse counter logic is independent from the pixel pipeline.

  joy0 : block
  begin
    -- Synchronize to clk7 domain.
    m0vs : entity work.syncer
    generic map (width => 2)
    port map (clk => deni.clk7, d => deni.m0v, q => m0v_sync);

    m0hs : entity work.syncer
    generic map (width => 2)
    port map (clk => deni.clk7, d => deni.m0h, q => m0h_sync);

    -- Decode quadrature inputs.
    q0v : entity work.joyquad
    port map (
      clk7    => deni.clk7,
      cck     => deni.cck,
      mv      => m0v_sync,
      wen     => r.b.sel.joytest,
      wdata   => r.b.drdx(15 downto 10),
      rdata   => joy0daty
    );

    q0h : entity work.joyquad
    port map (
      clk7    => deni.clk7,
      cck     => deni.cck,
      mv      => m0h_sync,
      wen     => r.b.sel.joytest,
      wdata   => r.b.drdx( 7 downto  2),
      rdata   => joy0datx
    );
  end block;

  joy1 : block
  begin
    m1vs : entity work.syncer
    generic map (width => 2)
    port map (clk => deni.clk7, d => deni.m1v, q => m1v_sync);

    m1hs : entity work.syncer
    generic map (width => 2)
    port map (clk => deni.clk7, d => deni.m1h, q => m1h_sync);

    q1v : entity work.joyquad
    port map (
      clk7    => deni.clk7,
      cck     => deni.cck,
      mv      => m1v_sync,
      wen     => r.b.sel.joytest,
      wdata   => r.b.drdx(15 downto 10),
      rdata   => joy1daty
    );

    q1h : entity work.joyquad
    port map (
      clk7    => deni.clk7,
      cck     => deni.cck,
      mv      => m1h_sync,
      wen     => r.b.sel.joytest,
      wdata   => r.b.drdx( 7 downto  2),
      rdata   => joy1datx
    );
  end block;

end;
