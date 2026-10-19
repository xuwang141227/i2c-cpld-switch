transcript on
if {[file exists work]} {vdel -lib work -all}
vlib work
vlog ./rtl/i2c_cpld_switch.v
vlog ./tb/tb_i2c_cpld_switch.v
vsim -voptargs=+acc work.tb_i2c_cpld_switch
add wave -r /*
run -all
