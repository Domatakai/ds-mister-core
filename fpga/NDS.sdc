# NDS MiSTer Test — core-specific timing constraints.
# All top-level clocks (FPGA_CLK*_50, HPS SPI) and the framework false
# paths are constrained by sys/sys_top.sdc. The core's own 67.0274 MHz clock
# comes out of the `pll` megafunction, so derive_pll_clocks below is what
# constrains it; the DDR3 side stays on CLK_50M, which the framework already
# constrains.
derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
