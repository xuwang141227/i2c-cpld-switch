`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// 简易 I2C slave 行为模型：7-bit 地址 ADDR，256x8 存储，首字节为指针，指针自增
// mem[8'hF0] 预置为 ID，用来确认透传到了哪一个 slave 端口
// ---------------------------------------------------------------------------
module i2c_slave_model #(
    parameter [6:0] ADDR = 7'h50,
    parameter [7:0] ID   = 8'h00
)(
    input  wire        scl,
    inout  wire        sda,
    output reg  [15:0] txn_cnt,    // 收到的 START 次数
    output reg  [15:0] wr_cnt,     // 收到的写数据字节数
    output reg  [7:0]  last_wdata
);
    localparam ST_IDLE=0, ST_RX=1, ST_ACKW=2, ST_ACKD=3, ST_TX=4, ST_MACK=5, ST_IGN=6;
    localparam K_ADDR=0, K_PTR=1, K_DATA=2;

    reg low;
    assign sda = low ? 1'b0 : 1'bz;

    reg [7:0] mem [0:255];
    reg [2:0] st;
    reg [1:0] kind;
    reg [3:0] bitcnt;
    reg [7:0] sh, tx, ptr;
    reg       rw, m_ack;
    integer   k;

    initial begin
        low = 0; st = ST_IDLE; kind = K_ADDR; bitcnt = 0; sh = 0; tx = 0; ptr = 0;
        rw = 0; m_ack = 0; txn_cnt = 0; wr_cnt = 0; last_wdata = 0;
        for (k = 0; k < 256; k = k + 1) mem[k] = 8'h00;
        mem[8'hF0] = ID;
    end

    always @(negedge sda) if (scl === 1'b1) begin     // START / repeated START
        st = ST_RX; kind = K_ADDR; bitcnt = 0; sh = 0; low = 0;
        txn_cnt = txn_cnt + 1;
    end
    always @(posedge sda) if (scl === 1'b1) begin     // STOP
        st = ST_IDLE; low = 0;
    end

    always @(posedge scl) begin
        if (st == ST_RX) begin
            sh = {sh[6:0], (sda === 1'b0) ? 1'b0 : 1'b1};
            bitcnt = bitcnt + 1;
            if (bitcnt == 8) begin
                case (kind)
                    K_ADDR: begin
                        rw = sh[0];
                        st = (sh[7:1] == ADDR) ? ST_ACKW : ST_IGN;
                    end
                    K_PTR: begin ptr = sh; st = ST_ACKW; end
                    default: begin
                        mem[ptr] = sh; last_wdata = sh; wr_cnt = wr_cnt + 1;
                        ptr = ptr + 1; st = ST_ACKW;
                    end
                endcase
            end
        end else if (st == ST_MACK) begin
            m_ack = (sda === 1'b0);
        end
    end

    always @(negedge scl) begin
        case (st)
            ST_ACKW: begin low = 1'b1; st = ST_ACKD; end
            ST_ACKD: begin
                low = 1'b0;
                if (kind == K_ADDR && rw) begin
                    tx = mem[ptr]; ptr = ptr + 1; bitcnt = 1; low = ~tx[7]; st = ST_TX;
                end else begin
                    kind = (kind == K_ADDR) ? K_PTR : K_DATA;
                    bitcnt = 0; st = ST_RX;
                end
            end
            ST_TX: begin
                if (bitcnt < 8) begin low = ~tx[7-bitcnt]; bitcnt = bitcnt + 1; end
                else begin low = 1'b0; st = ST_MACK; end
            end
            ST_MACK: begin
                if (m_ack) begin
                    tx = mem[ptr]; ptr = ptr + 1; bitcnt = 1; low = ~tx[7]; st = ST_TX;
                end else begin
                    low = 1'b0; st = ST_IGN;
                end
            end
            default: ;
        endcase
    end
endmodule


module tb_i2c_cpld_switch;

    reg clk, reset_n, i2c_master_sel;
    reg scl_m0, scl_m1;
    reg [1:0] m_low;
    wire sda_m0, sda_m1;
    assign sda_m0 = m_low[0] ? 1'b0 : 1'bz;
    assign sda_m1 = m_low[1] ? 1'b0 : 1'bz;
    pullup(sda_m0); pullup(sda_m1);

    wire [7:0] scl_s, sda_s;
    wire [8*16-1:0] txn_flat, wrc_flat;
    wire [8*8-1:0]  lastw_flat;
    pullup(sda_s[0]); pullup(sda_s[1]); pullup(sda_s[2]); pullup(sda_s[3]);
    pullup(sda_s[4]); pullup(sda_s[5]); pullup(sda_s[6]); pullup(sda_s[7]);

    genvar g;
    generate for (g = 0; g < 8; g = g + 1) begin : gs
        i2c_slave_model #(.ADDR(7'h50), .ID(8'hC0 + g)) u (
            .scl(scl_s[g]), .sda(sda_s[g]),
            .txn_cnt(txn_flat[g*16 +: 16]), .wr_cnt(wrc_flat[g*16 +: 16]),
            .last_wdata(lastw_flat[g*8 +: 8]));
    end endgenerate

    i2c_cpld_switch #(.CLK_FREQ_HZ(50_000_000), .I2C_SPEED_HZ(100_000), .IDLE_FILTER_CYC(8)) dut (
        .clk(clk), .reset_n(reset_n), .i2c_master_sel(i2c_master_sel),
        .scl_master0(scl_m0), .sda_master0(sda_m0),
        .scl_master1(scl_m1), .sda_master1(sda_m1),
        .scl_slave0(scl_s[0]), .sda_slave0(sda_s[0]),
        .scl_slave1(scl_s[1]), .sda_slave1(sda_s[1]),
        .scl_slave2(scl_s[2]), .sda_slave2(sda_s[2]),
        .scl_slave3(scl_s[3]), .sda_slave3(sda_s[3]),
        .scl_slave4(scl_s[4]), .sda_slave4(sda_s[4]),
        .scl_slave5(scl_s[5]), .sda_slave5(sda_s[5]),
        .scl_slave6(scl_s[6]), .sda_slave6(sda_s[6]),
        .scl_slave7(scl_s[7]), .sda_slave7(sda_s[7]));

    initial begin clk = 0; forever #10 clk = ~clk; end

    // ------------------------------------------------------------------
    // 公共：计数、检查
    // ------------------------------------------------------------------
    integer pass_cnt, fail_cnt;
    task check; input cond; input [8*40-1:0] name; begin
        if (cond) begin pass_cnt = pass_cnt + 1; $display("  [PASS] %0s", name); end
        else      begin fail_cnt = fail_cnt + 1; $display("  [FAIL] %0s", name); end
    end endtask

    // ------------------------------------------------------------------
    // I2C master 驱动（m=0/1 选择 master）
    // ------------------------------------------------------------------
    localparam HP = 5000;
    task hp; begin #HP; end endtask
    task set_scl; input m; input v; begin if (m) scl_m1 = v; else scl_m0 = v; end endtask
    task set_sda; input m; input v; begin m_low[m] = (v == 1'b0); end endtask
    function get_sda; input m; begin get_sda = m ? sda_m1 : sda_m0; end endfunction

    task m_start; input m; begin      // 兼容 repeated START
        set_sda(m, 1); hp; set_scl(m, 1); hp;
        set_sda(m, 0); hp; set_scl(m, 0); hp;
    end endtask
    task m_stop; input m; begin
        set_sda(m, 0); set_scl(m, 0); hp;
        set_scl(m, 1); hp; set_sda(m, 1); hp;
    end endtask
    task m_wbit; input m; input b; begin
        set_scl(m, 0); set_sda(m, b); hp; set_scl(m, 1); hp; set_scl(m, 0); hp;
    end endtask
    task m_rbit; input m; output b; begin
        set_scl(m, 0); set_sda(m, 1); hp; set_scl(m, 1); hp; b = get_sda(m); set_scl(m, 0); hp;
    end endtask
    task m_wbyte; input m; input [7:0] d; output ack; integer i; reg b; begin
        for (i = 7; i >= 0; i = i - 1) m_wbit(m, d[i]);
        m_rbit(m, b); ack = (b === 1'b0);
    end endtask
    task m_rbyte; input m; output [7:0] d; input nack; integer i; reg b; begin
        for (i = 7; i >= 0; i = i - 1) begin m_rbit(m, b); d[i] = b; end
        m_wbit(m, nack);
        set_sda(m, 1);
    end endtask

    // 高层事务
    reg a0, a1, a2;
    // 写 N=1 字节寄存器：START, addr_w, reg, data, STOP；返回 3 个 ACK
    task wr_reg; input m; input [6:0] dev; input [7:0] r; input [7:0] d; begin
        m_start(m);
        m_wbyte(m, {dev, 1'b0}, a0); m_wbyte(m, r, a1); m_wbyte(m, d, a2);
        m_stop(m); hp;
    end endtask
    // 读寄存器：START, addr_w, reg, Sr, addr_r, data(NACK), STOP
    reg [7:0] rd_val;
    task rd_reg; input m; input [6:0] dev; input [7:0] r; begin
        m_start(m);
        m_wbyte(m, {dev, 1'b0}, a0); m_wbyte(m, r, a1);
        m_start(m);
        m_wbyte(m, {dev, 1'b1}, a2);
        m_rbyte(m, rd_val, 1'b1);
        m_stop(m); hp;
    end endtask

    // 切换 master 并等待 DUT 生效
    task sel_master; input m; begin
        i2c_master_sel = m; #3000;
    end endtask

    localparam [6:0] CPLD = 7'h7F, SLV = 7'h50;
    reg [7:0] exp_d;
    integer i, m, s, n;
    reg [15:0] txn_before [0:7];

    function [15:0] txn; input integer idx; begin txn = txn_flat[idx*16 +: 16]; end endfunction
    function [15:0] wrc; input integer idx; begin wrc = wrc_flat[idx*16 +: 16]; end endfunction
    function [7:0] lastw; input integer idx; begin lastw = lastw_flat[idx*8 +: 8]; end endfunction

    initial begin
        pass_cnt = 0; fail_cnt = 0;
        reset_n = 0; i2c_master_sel = 0; scl_m0 = 1; scl_m1 = 1; m_low = 2'b00;
        #1000; reset_n = 1; #2000;

        // ============================================================
        $display("\n===== TEST 1: 内部 slave port 寄存器(0x01) 读写 =====");
        $display("  复位后 slave_port_sel = 0x%02h", dut.slave_port_sel);
        check(dut.slave_port_sel === 8'h00, "reset value of reg0x01 is 0x00");
        for (i = 0; i < 8; i = i + 1) begin
            exp_d = 8'h88 + i;
            wr_reg(0, CPLD, 8'h01, exp_d);
            check(a0 && a1 && a2, "internal write all ACK");
            rd_reg(0, CPLD, 8'h01);
            $display("  WRITE 0x%02h -> READ 0x%02h (ack=%b%b%b)  %s", exp_d, rd_val, a0, a1, a2,
                     (rd_val === exp_d) ? "MATCH" : "MISMATCH");
            check(rd_val === exp_d, "reg0x01 write/read match");
            check(dut.slave_port_sel === exp_d, "dut.slave_port_sel updated");
        end
        // 其它 pattern
        wr_reg(0, CPLD, 8'h01, 8'hA5); rd_reg(0, CPLD, 8'h01);
        $display("  WRITE 0xA5 -> READ 0x%02h", rd_val);
        check(rd_val === 8'hA5, "reg0x01 pattern 0xA5");
        wr_reg(0, CPLD, 8'h01, 8'h5A); rd_reg(0, CPLD, 8'h01);
        $display("  WRITE 0x5A -> READ 0x%02h", rd_val);
        check(rd_val === 8'h5A, "reg0x01 pattern 0x5A");

        // ============================================================
        $display("\n===== TEST 2: 2 master x 8 slave = 16 case 透传读写 =====");
        for (m = 0; m < 2; m = m + 1) begin
            for (s = 0; s < 8; s = s + 1) begin
                $display("--- case %0d : master%0d -> slave%0d ---", m*8 + s, m, s);
                sel_master(m);
                check(dut.active_master_sel === m[0], "active master switched");
                // 经当前 master 配置 slave port
                // (内部事务的 START/地址阶段会短暂透传到旧 slave, 故在配置完成后再统计流量)
                wr_reg(m, CPLD, 8'h01, 8'h88 + s);
                rd_reg(m, CPLD, 8'h01);
                check(rd_val === 8'h88 + s, "select reg readback");
                for (i = 0; i < 8; i = i + 1) txn_before[i] = txn(i);
                // 写 slave 0x50 reg 0x20
                exp_d = 8'hA0 ^ {3'd0, m[0], 1'b0, s[2:0]} ^ 8'h0F;
                wr_reg(m, SLV, 8'h20, exp_d);
                check(a0 && a1 && a2, "slave write all ACK");
                $display("  slave%0d mem[0x20]: wrote 0x%02h, last_wdata=0x%02h", s, exp_d, lastw(s));
                check(lastw(s) === exp_d, "data arrived at selected slave");
                // 读回
                rd_reg(m, SLV, 8'h20);
                $display("  WRITE 0x%02h -> READ 0x%02h  %s", exp_d, rd_val, (rd_val === exp_d) ? "MATCH" : "MISMATCH");
                check(a0 && a1 && a2, "slave read all ACK");
                check(rd_val === exp_d, "slave read-back matches");
                // 读 ID 确认路由
                rd_reg(m, SLV, 8'hF0);
                $display("  slave ID read = 0x%02h (expect 0x%02h)", rd_val, 8'hC0 + s[7:0]);
                check(rd_val === 8'hC0 + s, "routed to correct slave (ID)");
                // 其它 slave 没有任何事务
                n = 0;
                for (i = 0; i < 8; i = i + 1)
                    if (i != s && txn(i) !== txn_before[i]) n = n + 1;
                check(n == 0, "non-selected slaves untouched");
                check(txn(s) !== txn_before[s], "selected slave saw traffic");
            end
        end

        // ============================================================
        $display("\n===== TEST 3: 异常 case =====");
        sel_master(0);
        wr_reg(0, CPLD, 8'h01, 8'h8B);  // slave3

        $display("--- E1: 访问不存在的 slave 地址 0x33 -> 应 NACK ---");
        m_start(0); m_wbyte(0, {7'h33, 1'b0}, a0); m_stop(0); hp;
        $display("  ack=%b", a0);
        check(a0 === 1'b0, "NACK on absent address");
        wr_reg(0, SLV, 8'h30, 8'h77); rd_reg(0, SLV, 8'h30);
        check(rd_val === 8'h77, "bus recovers after NACK");

        $display("--- E2: 读未定义内部寄存器 0x55 -> 应返回 0x00 ---");
        rd_reg(0, CPLD, 8'h55);
        $display("  read 0x55 = 0x%02h", rd_val);
        check(rd_val === 8'h00, "undefined internal reg reads 0");

        $display("--- E3: 写其它内部寄存器 0x02 不应改变 slave_port_sel ---");
        wr_reg(0, CPLD, 8'h02, 8'h8F);
        rd_reg(0, CPLD, 8'h01);
        check(rd_val === 8'h8B, "reg0x01 unchanged");

        $display("--- E4: slave_port_sel 低 nibble <8 (未使能) -> slave 无流量, 无 ACK ---");
        wr_reg(0, CPLD, 8'h01, 8'h03);
        for (i = 0; i < 8; i = i + 1) txn_before[i] = txn(i);
        m_start(0); m_wbyte(0, {SLV, 1'b0}, a0); m_stop(0); hp;
        $display("  ack=%b", a0);
        check(a0 === 1'b0, "NACK when port disabled");
        n = 0; for (i = 0; i < 8; i = i + 1) if (txn(i) !== txn_before[i]) n = n + 1;
        check(n == 0, "no slave sees traffic when disabled");
        check(scl_s === 8'hFF, "all slave SCL idle high when disabled");
        wr_reg(0, CPLD, 8'h01, 8'h00); rd_reg(0, CPLD, 8'h01);
        check(rd_val === 8'h00, "sel=0x00 readback");

        $display("--- E5: 总线忙时改变 i2c_master_sel, 事务不应被打断 ---");
        wr_reg(0, CPLD, 8'h01, 8'h8C);  // slave4
        m_start(0);
        m_wbyte(0, {SLV, 1'b0}, a0);
        i2c_master_sel = 1; #3000;
        check(dut.active_master_sel === 1'b0, "no switch while master0 busy");
        m_wbyte(0, 8'h40, a1); m_wbyte(0, 8'h5C, a2);
        m_stop(0); hp;
        check(a0 && a1 && a2, "txn completes on master0");
        check(lastw(4) === 8'h5C, "data reached slave4");
        #3000;
        check(dut.active_master_sel === 1'b1, "switch after bus idle");
        rd_reg(1, SLV, 8'h40);
        $display("  master1 read-back = 0x%02h", rd_val);
        check(rd_val === 8'h5C, "master1 reads same data");
        sel_master(0);

        $display("--- E6: 多字节突发写/读 (指针自增) ---");
        m_start(0);
        m_wbyte(0, {SLV, 1'b0}, a0); m_wbyte(0, 8'h60, a1);
        m_wbyte(0, 8'h11, a2); check(a2, "burst byte0 ACK");
        m_wbyte(0, 8'h22, a2); check(a2, "burst byte1 ACK");
        m_wbyte(0, 8'h33, a2); check(a2, "burst byte2 ACK");
        m_stop(0); hp;
        m_start(0);
        m_wbyte(0, {SLV, 1'b0}, a0); m_wbyte(0, 8'h60, a1);
        m_start(0);
        m_wbyte(0, {SLV, 1'b1}, a2);
        m_rbyte(0, rd_val, 1'b0); $display("  burst rd0=0x%02h", rd_val); check(rd_val === 8'h11, "burst read byte0");
        m_rbyte(0, rd_val, 1'b0); $display("  burst rd1=0x%02h", rd_val); check(rd_val === 8'h22, "burst read byte1");
        m_rbyte(0, rd_val, 1'b1); $display("  burst rd2=0x%02h", rd_val); check(rd_val === 8'h33, "burst read byte2");
        m_stop(0); hp;

        $display("--- E7: 切换 slave port 后旧 slave 不再收到流量 ---");
        wr_reg(0, CPLD, 8'h01, 8'h8D);  // slave5
        for (i = 0; i < 8; i = i + 1) txn_before[i] = txn(i);
        wr_reg(0, SLV, 8'h70, 8'hE5);
        check(lastw(5) === 8'hE5, "data to slave5");
        check(txn(4) === txn_before[4], "slave4 untouched after re-select");

        $display("--- E8: 异步复位后 slave_port_sel 回到 0x00 ---");
        reset_n = 0; #200; reset_n = 1; #2000;
        check(dut.slave_port_sel === 8'h00, "reset clears select");
        check(dut.active_master_sel === 1'b0, "reset clears active master");

        $display("\n===== SUMMARY: pass=%0d fail=%0d =====", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("PASS"); else $display("FAIL");
        #20000; $finish;
    end

    // 看门狗
    initial begin #400_000_000; $display("TIMEOUT"); $finish; end
endmodule
