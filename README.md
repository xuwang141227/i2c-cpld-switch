# i2c-cpld-switch

## 功能
- 2 路 master / 8 路 slave I2C 透传
- `scl_master` 实时透传到被选中 `scl_slave`
- `sda` 开漏双向透传（按相位切换方向）
- 内部寄存器访问地址：7-bit `0x7F`
- 内部寄存器 `0x01`：`slave_port_sel`

## 端口选择
`slave_port_sel[3:0]`：
- `1000` -> slave0
- `1001` -> slave1
- `1010` -> slave2
- `1011` -> slave3
- `1100` -> slave4
- `1101` -> slave5
- `1110` -> slave6
- `1111` -> slave7

## 切换逻辑
- `active_master_sel` 只在两路 master 都空闲时才更新
- 空闲判定包括：
  1. protocol busy=0（通过 START/STOP 检测）
  2. 线电平空闲（SCL=1, SDA=1）
  3. 连续稳定 `IDLE_FILTER_CYC` 个 clk 周期

## 透传逻辑
- 外部事务：
  - 写数据阶段：master -> slave
  - ACK/读数据阶段：slave -> master
- 内部事务（地址命中 `0x7F`）：
  - CPLD 内部驱动 ACK/读数据到 master
  - 屏蔽外部 slave SDA 驱动，避免并驱动

## 参数
- `CLK_FREQ_HZ`：内部逻辑时钟
- `I2C_SPEED_HZ`：I2C 线速率（用于设计约束/检查）
- `IDLE_FILTER_CYC`：空闲防抖窗口

## 仿真
ModelSim:
```tcl
do sim/run.do
```

Icarus Verilog（命令行，RTL 不改动）：
```sh
iverilog -g2005 -o sim.out rtl/i2c_cpld_switch.v tb/tb_i2c_cpld_switch.v
vvp sim.out
```
末尾打印 `SUMMARY: pass=N fail=M` 及 `PASS`/`FAIL`。

## 测试方案（tb/tb_i2c_cpld_switch.v）
TB 内含 8 个 I2C slave 行为模型（地址 `0x50`，256 字节存储，指针自增；`mem[0xF0]` 预置 ID `0xC0+port`，用于确认透传路由），以及 2 个 master 的 bit-bang 驱动（START/STOP/Sr、写/读字节、ACK/NACK）。

### 1. 内部 slave port 寄存器读写
- 复位值检查（`0x01 == 0x00`）。
- 依次向 `0x7F` 的 reg `0x01` 写 `0x88~0x8F`、`0xA5`、`0x5A`，再读回，打印 `WRITE x -> READ y MATCH/MISMATCH`，并检查 DUT 内部 `slave_port_sel`。

### 2. 16 个 case（2 master × 8 slave）
每个 case：切换 `i2c_master_sel` → 经该 master 写 `0x01` 选择 slave → 写 slave `0x50` reg `0x20` → 读回比对 → 读 `0xF0` 核对 slave ID → 检查其它 7 个 slave 无流量。验证 master/slave 数据通道透传正确。

### 3. 异常 case
| 编号 | 场景 | 期望 |
|---|---|---|
| E1 | 访问不存在的地址 `0x33` | NACK，之后总线可正常访问 |
| E2 | 读未定义内部寄存器 `0x55` | 返回 `0x00` |
| E3 | 写内部 reg `0x02` | `0x01` 不变 |
| E4 | `slave_port_sel` 低 nibble < 8 | 访问 NACK，slave 无流量，所有 `scl_slave` 保持高 |
| E5 | master0 事务进行中改变 `i2c_master_sel` | 事务不被打断，STOP 后才切换；master1 可读到同一数据 |
| E6 | 多字节突发读写 | 指针自增，数据一致 |
| E7 | 重新选择 slave port | 旧 slave 不再收到流量 |
| E8 | 异步复位 | `slave_port_sel`、`active_master_sel` 回到 0 |

### 已知现象（RTL 未改动）
内部事务（地址 `0x7F`）的 START 与地址阶段在地址译码前会短暂透传到“之前选中”的 slave（该 slave 因地址不匹配不会 ACK）。TB 因此在配置 slave port 之后再统计“其它 slave 无流量”。

### 仿真结果
当前 Icarus Verilog 仿真：`pass=194 fail=0`，`PASS`。
