create_clock -name {clk} -period 18.750 [get_ports {clk}]
derive_clock_uncertainty
set_false_path -from [get_ports {clk}]
set_false_path -to   [get_ports {led}]
