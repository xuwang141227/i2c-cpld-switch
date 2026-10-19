`timescale 1ns/1ps
module tb_i2c_cpld_switch;

    reg clk;
    reg reset_n;
    reg i2c_master_sel;

    reg  scl_m0, scl_m1;
    wire sda_m0, sda_m1;
    reg  m0_low, m1_low;
    assign sda_m0 = m0_low ? 1'b0 : 1'bz;
    assign sda_m1 = m1_low ? 1'b0 : 1'bz;
    pullup(sda_m0); pullup(sda_m1);

    wire scl_s0,scl_s1,scl_s2,scl_s3,scl_s4,scl_s5,scl_s6,scl_s7;
    wire sda_s0,sda_s1,sda_s2,sda_s3,sda_s4,sda_s5,sda_s6,sda_s7;

    reg s0_low,s1_low,s2_low,s3_low,s4_low,s5_low,s6_low,s7_low;
    assign sda_s0 = s0_low ? 1'b0 : 1'bz;
    assign sda_s1 = s1_low ? 1'b0 : 1'bz;
    assign sda_s2 = s2_low ? 1'b0 : 1'bz;
    assign sda_s3 = s3_low ? 1'b0 : 1'bz;
    assign sda_s4 = s4_low ? 1'b0 : 1'bz;
    assign sda_s5 = s5_low ? 1'b0 : 1'bz;
    assign sda_s6 = s6_low ? 1'b0 : 1'bz;
    assign sda_s7 = s7_low ? 1'b0 : 1'bz;
    pullup(sda_s0); pullup(sda_s1); pullup(sda_s2); pullup(sda_s3);
    pullup(sda_s4); pullup(sda_s5); pullup(sda_s6); pullup(sda_s7);

    i2c_cpld_switch #(
        .CLK_FREQ_HZ(50_000_000),
        .I2C_SPEED_HZ(100_000),
        .IDLE_FILTER_CYC(8)
    ) dut (
        .clk(clk), .reset_n(reset_n), .i2c_master_sel(i2c_master_sel),
        .scl_master0(scl_m0), .sda_master0(sda_m0),
        .scl_master1(scl_m1), .sda_master1(sda_m1),
        .scl_slave0(scl_s0), .sda_slave0(sda_s0),
        .scl_slave1(scl_s1), .sda_slave1(sda_s1),
        .scl_slave2(scl_s2), .sda_slave2(sda_s2),
        .scl_slave3(scl_s3), .sda_slave3(sda_s3),
        .scl_slave4(scl_s4), .sda_slave4(sda_s4),
        .scl_slave5(scl_s5), .sda_slave5(sda_s5),
        .scl_slave6(scl_s6), .sda_slave6(sda_s6),
        .scl_slave7(scl_s7), .sda_slave7(sda_s7)
    );

    initial begin clk=0; forever #10 clk=~clk; end
    task i2c_wait; begin #5000; end endtask

    task m0_start; begin
        m0_low=0; scl_m0=1; i2c_wait;
        m0_low=1;           i2c_wait;
        scl_m0=0;           i2c_wait;
    end endtask

    task m0_stop; begin
        m0_low=1; scl_m0=0; i2c_wait;
        scl_m0=1;           i2c_wait;
        m0_low=0;           i2c_wait;
    end endtask

    task m0_write_bit; input b; begin
        scl_m0=0; m0_low=(b==1'b0); i2c_wait;
        scl_m0=1; i2c_wait;
        scl_m0=0; i2c_wait;
    end endtask

    task m0_read_bit; output b; begin
        scl_m0=0; m0_low=0; i2c_wait;
        scl_m0=1; i2c_wait; b=sda_m0;
        scl_m0=0; i2c_wait;
    end endtask

    task m0_write_byte; input [7:0] data; output ack; integer i; reg b;
    begin
        for(i=7;i>=0;i=i-1) m0_write_bit(data[i]);
        m0_read_bit(b); ack=(b==1'b0);
    end endtask

    task m0_read_byte; output [7:0] data; input nack; integer i; reg b;
    begin
        for(i=7;i>=0;i=i-1) begin
            m0_read_bit(b); data[i]=b;
        end
        m0_write_bit(nack);
    end endtask

    reg ack;
    reg [7:0] rdata;
    integer err;

    initial begin
        err=0;
        reset_n=0; i2c_master_sel=0;
        scl_m0=1; scl_m1=1;
        m0_low=0; m1_low=0;
        s0_low=0; s1_low=0; s2_low=0; s3_low=0; s4_low=0; s5_low=0; s6_low=0; s7_low=0;
        #1000; reset_n=1;

        m0_start();
        m0_write_byte(8'hFE, ack); if(!ack) err=err+1;
        m0_write_byte(8'h01, ack); if(!ack) err=err+1;
        m0_write_byte(8'h8A, ack); if(!ack) err=err+1;
        m0_stop(); #20000;

        m0_start();
        m0_write_byte(8'hFE, ack); if(!ack) err=err+1;
        m0_write_byte(8'h01, ack); if(!ack) err=err+1;
        m0_low=0; scl_m0=1; i2c_wait; m0_low=1; i2c_wait; scl_m0=0; i2c_wait;
        m0_write_byte(8'hFF, ack); if(!ack) err=err+1;
        m0_read_byte(rdata, 1'b1);
        m0_stop();
        if(rdata!==8'h8A) err=err+1;

        $display("TB DONE err=%0d", err);
        if(err==0) $display("PASS"); else $display("FAIL");
        #20000; $finish;
    end
endmodule
