# NDS MiSTer Test — timing constraints
create_clock -name CLOCK_50M -period 20 [get_ports {CLK_50M}]
create_clock -name CLOCK_24M -period 40.690 [get_ports {CLK_AUDIO}]

derive_pll_clocks
derive_clock_uncertainty

# HPS_BUS is an async interface handled inside the framework.
set_false_path -from [get_ports {HPS_BUS*}]
set_false_path -to   [get_ports {HPS_BUS*}]
