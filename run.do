onerror {quit -code 1}

if {![file isdirectory work]} {
    vlib work
}

vlog -sv -timescale 1ns/1ps AHB_master.sv AHB_interconnect.sv tb_master_interconnect.sv
vsim -onfinish stop -voptargs=+acc work.tb_master_interconnect
run -all

if {[examine -radix unsigned sim:/tb_master_interconnect/passed] != 1} {
    quit -code 1
}
quit -code 0
