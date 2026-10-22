# NDS MiSTer Test — core-specific timing constraints.
# All top-level clocks (FPGA_CLK*_50, HPS SPI) and the framework false
# paths are constrained by sys/sys_top.sdc; nothing in the core creates
# its own clock, so this file only mirrors the Template additions.
derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
