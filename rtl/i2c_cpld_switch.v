`timescale 1ns/1ps
module i2c_cpld_switch #(
    parameter integer CLK_FREQ_HZ     = 50_000_000,
    parameter integer I2C_SPEED_HZ    = 100_000,
    parameter integer IDLE_FILTER_CYC = 8,
    parameter integer SDA_RELEASE_CYC = (CLK_FREQ_HZ / 1_000_000) + 2
)(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        i2c_master_sel,

    // 2 masters
    input  wire        scl_master0,
    inout  wire        sda_master0,
    input  wire        scl_master1,
    inout  wire        sda_master1,

    // 8 slaves (SCL out, SDA inout)
    output wire        scl_slave0, inout wire sda_slave0,
    output wire        scl_slave1, inout wire sda_slave1,
    output wire        scl_slave2, inout wire sda_slave2,
    output wire        scl_slave3, inout wire sda_slave3,
    output wire        scl_slave4, inout wire sda_slave4,
    output wire        scl_slave5, inout wire sda_slave5,
    output wire        scl_slave6, inout wire sda_slave6,
    output wire        scl_slave7, inout wire sda_slave7
);

    localparam integer I2C_HALF_PERIOD_CLK = (CLK_FREQ_HZ/(I2C_SPEED_HZ*2));

    wire sda_m0_i = sda_master0;
    wire sda_m1_i = sda_master1;
    wire sda_s0_i = sda_slave0;
    wire sda_s1_i = sda_slave1;
    wire sda_s2_i = sda_slave2;
    wire sda_s3_i = sda_slave3;
    wire sda_s4_i = sda_slave4;
    wire sda_s5_i = sda_slave5;
    wire sda_s6_i = sda_slave6;
    wire sda_s7_i = sda_slave7;

    (* ASYNC_REG = "TRUE" *) reg [1:0] scl_meta, scl_sync;
    (* ASYNC_REG = "TRUE" *) reg [9:0] sda_meta, sda_sync;
    (* ASYNC_REG = "TRUE" *) reg master_sel_meta, master_sel_sync;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            scl_meta <= 2'b11;
            scl_sync <= 2'b11;
            sda_meta <= 10'h3FF;
            sda_sync <= 10'h3FF;
            master_sel_meta <= 1'b0;
            master_sel_sync <= 1'b0;
        end else begin
            scl_meta <= {scl_master1, scl_master0};
            scl_sync <= scl_meta;
            sda_meta <= {sda_s7_i, sda_s6_i, sda_s5_i, sda_s4_i,
                         sda_s3_i, sda_s2_i, sda_s1_i, sda_s0_i,
                         sda_m1_i, sda_m0_i};
            sda_sync <= sda_meta;
            master_sel_meta <= i2c_master_sel;
            master_sel_sync <= master_sel_meta;
        end
    end

    reg m0_scl_d, m0_sda_d, m1_scl_d, m1_sda_d;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            m0_scl_d <= 1'b1; m0_sda_d <= 1'b1;
            m1_scl_d <= 1'b1; m1_sda_d <= 1'b1;
        end else begin
            m0_scl_d <= scl_sync[0]; m0_sda_d <= sda_sync[0];
            m1_scl_d <= scl_sync[1]; m1_sda_d <= sda_sync[1];
        end
    end

    wire m0_start = m0_sda_d && !sda_sync[0] && m0_scl_d && scl_sync[0];
    wire m0_stop  = !m0_sda_d && sda_sync[0] && m0_scl_d && scl_sync[0];
    wire m1_start = m1_sda_d && !sda_sync[1] && m1_scl_d && scl_sync[1];
    wire m1_stop  = !m1_sda_d && sda_sync[1] && m1_scl_d && scl_sync[1];

    reg m0_busy, m1_busy;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            m0_busy <= 1'b0;
            m1_busy <= 1'b0;
        end else begin
            if(m0_start) m0_busy <= 1'b1;
            else if(m0_stop) m0_busy <= 1'b0;

            if(m1_start) m1_busy <= 1'b1;
            else if(m1_stop) m1_busy <= 1'b0;
        end
    end

    wire m0_idle_level = scl_sync[0] && sda_sync[0];
    wire m1_idle_level = scl_sync[1] && sda_sync[1];
    wire both_idle_now = (!m0_busy) && (!m1_busy) && m0_idle_level && m1_idle_level;

    reg [15:0] idle_cnt;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) idle_cnt <= 16'd0;
        else if(both_idle_now) begin
            if(idle_cnt < 16'hffff) idle_cnt <= idle_cnt + 16'd1;
        end else idle_cnt <= 16'd0;
    end
    wire switch_allowed = both_idle_now && (idle_cnt >= IDLE_FILTER_CYC);

    reg active_master_sel;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) active_master_sel <= 1'b0;
        else if(switch_allowed) active_master_sel <= master_sel_sync;
    end

    wire cur_scl_raw = active_master_sel ? scl_master1 : scl_master0;
    wire cur_scl_m = scl_sync[active_master_sel];
    wire cur_sda_m = sda_sync[active_master_sel];

    reg [7:0] slave_port_sel;
    reg [2:0] phase;
    reg [3:0] bit_cnt;
    reg [7:0] shreg;
    reg       internal_hit;
    localparam PH_ADDR_E = 3'd1;
    // Internal (slave-port register) access is detected from the address byte:
    // after 7 address bits equal 0x7F the slave side is blocked immediately
    // (before the R/W bit), and stays blocked via internal_hit afterwards.
    wire addr_internal_early = (phase==PH_ADDR_E) && (bit_cnt==4'd7) && (shreg[6:0]==7'h7F);
    wire internal_access = internal_hit | addr_internal_early;
    wire slave_path_en = selected_slave_en && !internal_access;
    wire selected_slave_en = (slave_port_sel[3:0] >= 4'h8);
    wire [2:0] slave_idx   = slave_port_sel[2:0];

    reg cur_sda_s;
    always @(*) begin
        case(slave_idx)
            3'd0: cur_sda_s = sda_sync[2];
            3'd1: cur_sda_s = sda_sync[3];
            3'd2: cur_sda_s = sda_sync[4];
            3'd3: cur_sda_s = sda_sync[5];
            3'd4: cur_sda_s = sda_sync[6];
            3'd5: cur_sda_s = sda_sync[7];
            3'd6: cur_sda_s = sda_sync[8];
            default: cur_sda_s = sda_sync[9];
        endcase
    end

    // SCL forwarding is combinational; only its synchronized copy enters logic.
    assign scl_slave0 = (slave_path_en && slave_idx==3'd0) ? cur_scl_raw : 1'b1;
    assign scl_slave1 = (slave_path_en && slave_idx==3'd1) ? cur_scl_raw : 1'b1;
    assign scl_slave2 = (slave_path_en && slave_idx==3'd2) ? cur_scl_raw : 1'b1;
    assign scl_slave3 = (slave_path_en && slave_idx==3'd3) ? cur_scl_raw : 1'b1;
    assign scl_slave4 = (slave_path_en && slave_idx==3'd4) ? cur_scl_raw : 1'b1;
    assign scl_slave5 = (slave_path_en && slave_idx==3'd5) ? cur_scl_raw : 1'b1;
    assign scl_slave6 = (slave_path_en && slave_idx==3'd6) ? cur_scl_raw : 1'b1;
    assign scl_slave7 = (slave_path_en && slave_idx==3'd7) ? cur_scl_raw : 1'b1;

    localparam DIR_IDLE=2'd0, DIR_MASTER=2'd1, DIR_SLAVE=2'd2, DIR_RELEASE=2'd3;
    reg [1:0] dir_state;
    reg [7:0] sda_m_samples, sda_s_samples;
    integer release_cnt;

    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            dir_state <= DIR_RELEASE;
            sda_m_samples <= 8'hFF;
            sda_s_samples <= 8'hFF;
            release_cnt <= 0;
        end else if(!slave_path_en) begin
            dir_state <= DIR_RELEASE;
            sda_m_samples <= 8'hFF;
            sda_s_samples <= 8'hFF;
            release_cnt <= 0;
        end else begin
            sda_m_samples <= {sda_m_samples[6:0], cur_sda_m};
            sda_s_samples <= {sda_s_samples[6:0], cur_sda_s};
            case(dir_state)
                DIR_IDLE: begin
                    if(sda_m_samples==8'h00) dir_state <= DIR_MASTER;
                    else if(sda_s_samples==8'h00) dir_state <= DIR_SLAVE;
                end
                DIR_MASTER: begin
                    if(&sda_m_samples[2:0]) begin
                        dir_state <= DIR_RELEASE;
                        release_cnt <= 0;
                    end
                end
                DIR_SLAVE: begin
                    if(&sda_s_samples[2:0]) begin
                        dir_state <= DIR_RELEASE;
                        release_cnt <= 0;
                    end
                end
                DIR_RELEASE: begin
                    // Both outputs stay released while the old destination rises.
                    // Discard its reflected-low history before choosing a new source.
                    sda_m_samples <= 8'hFF;
                    sda_s_samples <= 8'hFF;
                    if(release_cnt >= SDA_RELEASE_CYC-1) begin
                        dir_state <= DIR_IDLE;
                        release_cnt <= 0;
                    end else release_cnt <= release_cnt + 1;
                end
                default: begin
                    dir_state <= DIR_RELEASE;
                    release_cnt <= 0;
                end
            endcase
        end
    end

    reg cur_scl_d, cur_sda_d;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            cur_scl_d <= 1'b1; cur_sda_d <= 1'b1;
        end else begin
            cur_scl_d <= cur_scl_m; cur_sda_d <= cur_sda_m;
        end
    end

    wire start_cond = cur_sda_d && !cur_sda_m && cur_scl_d && cur_scl_m;
    wire stop_cond  = !cur_sda_d && cur_sda_m && cur_scl_d && cur_scl_m;

    reg scl_q;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) scl_q <= 1'b1;
        else scl_q <= cur_scl_m;
    end
    wire scl_rise = (scl_q==1'b0 && cur_scl_m==1'b1);
    wire scl_fall = (scl_q==1'b1 && cur_scl_m==1'b0);

    localparam PH_IDLE=3'd0, PH_ADDR=3'd1, PH_ACK1=3'd2, PH_REG=3'd3,
               PH_ACK2=3'd4, PH_DATA=3'd5, PH_ACK3=3'd6;

    reg [7:0] reg_addr;
    reg [7:0] reg_rdata;
    reg       rw_bit;
    reg       in_txn;
    reg       reg_addr_valid;
    reg       ack_started;
    reg [7:0] pending_slave_port_sel;
    reg       slave_port_sel_update_pending;

    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            phase <= PH_IDLE;
            bit_cnt <= 4'd0;
            shreg <= 8'h00;
            reg_addr <= 8'h00;
            reg_rdata <= 8'h00;
            rw_bit <= 1'b0;
            internal_hit <= 1'b0;
            in_txn <= 1'b0;
            reg_addr_valid <= 1'b0;
            ack_started <= 1'b0;
            pending_slave_port_sel <= 8'h00;
            slave_port_sel_update_pending <= 1'b0;
            slave_port_sel <= 8'h00;
        end else begin
            if(start_cond) begin
                if(!in_txn) begin
                    reg_addr_valid <= 1'b0;
                end
                if(slave_port_sel_update_pending) begin
                    slave_port_sel <= pending_slave_port_sel;
                    slave_port_sel_update_pending <= 1'b0;
                end
                in_txn <= 1'b1;
                phase <= PH_ADDR;
                bit_cnt <= 4'd0;
                shreg <= 8'h00;
                internal_hit <= 1'b0;
                ack_started <= 1'b0;
            end

            if(stop_cond) begin
                if(slave_port_sel_update_pending) begin
                    slave_port_sel <= pending_slave_port_sel;
                    slave_port_sel_update_pending <= 1'b0;
                end
                in_txn <= 1'b0;
                phase <= PH_IDLE;
                bit_cnt <= 4'd0;
                reg_addr_valid <= 1'b0;
                internal_hit <= 1'b0;
                ack_started <= 1'b0;
            end else if(in_txn && !start_cond) begin
                case(phase)
                    PH_ADDR: begin
                        if(scl_rise) begin
                            shreg <= {shreg[6:0], cur_sda_m};
                            bit_cnt <= bit_cnt + 1'b1;
                            if(bit_cnt==4'd7) begin
                                rw_bit <= cur_sda_m;
                                if(shreg[6:0]==7'h7F) internal_hit <= 1'b1;
                                else                  internal_hit <= 1'b0;
                                phase <= PH_ACK1;
                                bit_cnt <= 4'd0;
                                ack_started <= 1'b0;
                            end
                        end
                    end

                    PH_ACK1: begin
                        if(scl_fall) begin
                            if(!ack_started) begin
                                ack_started <= 1'b1;
                            end else begin
                                ack_started <= 1'b0;
                                if(internal_hit) begin
                                    if(rw_bit) begin
                                        if(reg_addr_valid) begin
                                            phase <= PH_DATA;
                                            if(reg_addr==8'h01) reg_rdata <= slave_port_sel;
                                            else                reg_rdata <= 8'h00;
                                        end else begin
                                            phase <= PH_IDLE;
                                        end
                                    end else begin
                                        phase <= PH_REG;
                                    end
                                end else begin
                                    phase <= PH_IDLE;
                                end
                            end
                        end
                    end

                    PH_REG: begin
                        if(scl_rise) begin
                            shreg <= {shreg[6:0], cur_sda_m};
                            bit_cnt <= bit_cnt + 1'b1;
                            if(bit_cnt==4'd7) begin
                                reg_addr <= {shreg[6:0], cur_sda_m};
                                reg_addr_valid <= 1'b1;
                                phase <= PH_ACK2;
                                bit_cnt <= 4'd0;
                                ack_started <= 1'b0;
                            end
                        end
                    end

                    PH_ACK2: begin
                        if(scl_fall) begin
                            if(!ack_started) begin
                                ack_started <= 1'b1;
                            end else begin
                                ack_started <= 1'b0;
                                phase <= PH_DATA;
                                if(rw_bit) begin
                                    if(reg_addr==8'h01) reg_rdata <= slave_port_sel;
                                    else                reg_rdata <= 8'h00;
                                end
                            end
                        end
                    end

                    PH_DATA: begin
                        if(internal_hit) begin
                            if(!rw_bit) begin
                                if(scl_rise) begin
                                    shreg <= {shreg[6:0], cur_sda_m};
                                    bit_cnt <= bit_cnt + 1'b1;
                                    if(bit_cnt==4'd7) begin
                                        if(reg_addr==8'h01) begin
                                            pending_slave_port_sel <= {shreg[6:0], cur_sda_m};
                                            slave_port_sel_update_pending <= 1'b1;
                                        end
                                        phase <= PH_ACK3;
                                        bit_cnt <= 4'd0;
                                        ack_started <= 1'b0;
                                    end
                                end
                            end else begin
                                if(scl_fall) begin
                                    bit_cnt <= bit_cnt + 1'b1;
                                    if(bit_cnt==4'd7) begin
                                        phase <= PH_ACK3;
                                        bit_cnt <= 4'd0;
                                        ack_started <= 1'b1;
                                    end
                                end
                            end
                        end
                    end

                    PH_ACK3: begin
                        if(scl_fall) begin
                            if(!ack_started) begin
                                ack_started <= 1'b1;
                            end else begin
                                ack_started <= 1'b0;
                                if(internal_hit) begin
                                    phase <= PH_IDLE;
                                    in_txn <= 1'b0;
                                end
                            end
                        end
                    end

                    default: phase <= PH_IDLE;
                endcase
            end
        end
    end

    wire int_ack1_low = (internal_hit && phase==PH_ACK1 && ack_started);
    wire int_ack2_low = (internal_hit && phase==PH_ACK2 && ack_started);
    wire int_ack3_low = (internal_hit && phase==PH_ACK3 && ack_started && !rw_bit);
    wire int_rdat_low = (internal_hit && rw_bit && phase==PH_DATA && (reg_rdata[7-bit_cnt]==1'b0));
    wire int_drive_master_low = int_ack1_low | int_ack2_low | int_ack3_low | int_rdat_low;

    // Only the originating side is sampled for release while forwarding a low.
    wire external_master_to_slave = slave_path_en && (dir_state==DIR_MASTER);
    wire external_slave_to_master = slave_path_en && (dir_state==DIR_SLAVE);
    wire external_slave_sda_low = external_master_to_slave;
    wire external_master_sda_low = external_slave_to_master;

    reg [1:0] master_sda_low;
    reg [7:0] slave_sda_low;
    wire drive_master_low = |master_sda_low;
    wire drive_slave_low = |slave_sda_low;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            master_sda_low <= 2'b00;
            slave_sda_low <= 8'h00;
        end else begin
            // Register the complete pin enables, including route and internal ACK/data.
            master_sda_low <= 2'b00;
            slave_sda_low <= 8'h00;
            master_sda_low[active_master_sel] <=
                internal_hit ? int_drive_master_low : external_master_sda_low;
            slave_sda_low[slave_idx] <= external_slave_sda_low;
        end
    end

    assign sda_master0 = master_sda_low[0] ? 1'b0 : 1'bz;
    assign sda_master1 = master_sda_low[1] ? 1'b0 : 1'bz;

    assign sda_slave0 = slave_sda_low[0] ? 1'b0 : 1'bz;
    assign sda_slave1 = slave_sda_low[1] ? 1'b0 : 1'bz;
    assign sda_slave2 = slave_sda_low[2] ? 1'b0 : 1'bz;
    assign sda_slave3 = slave_sda_low[3] ? 1'b0 : 1'bz;
    assign sda_slave4 = slave_sda_low[4] ? 1'b0 : 1'bz;
    assign sda_slave5 = slave_sda_low[5] ? 1'b0 : 1'bz;
    assign sda_slave6 = slave_sda_low[6] ? 1'b0 : 1'bz;
    assign sda_slave7 = slave_sda_low[7] ? 1'b0 : 1'bz;

endmodule
