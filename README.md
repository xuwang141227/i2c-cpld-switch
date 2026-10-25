# i2c-cpld-switch

## 功能
- 2 路 master / 8 路 slave I2C 透传
- `scl_master` 实时透传到被选中 `scl_slave`
- `sda` 开漏双向透传；根据实际拉低 SDA 的一侧锁定方向，不依赖外部命令格式、字节计数或读写位
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
- 两路 master 的 SCL、SDA、八路 slave 的 SDA 和 `i2c_master_sel` 均先经过两级寄存器同步；第一级只连接第二级，不参与协议、空闲或方向判断。同步寄存器带 `ASYNC_REG` 属性，具体器件工具仍需检查 CDC 和布局约束。
- START/STOP 使用同步后的 SDA 边沿，要求当前与上一拍 SCL 均为高，避免 SCL/SDA 同时下降被误判为 START。
- `active_master_sel` 只在两路 master 都空闲时才更新
- 空闲判定包括：
  1. protocol busy=0（通过 START/STOP 检测）
  2. 线电平空闲（SCL=1, SDA=1）
  3. 连续稳定 `IDLE_FILTER_CYC` 个 clk 周期

## 透传逻辑
- 外部 SDA 透传使用独立的方向状态机：
  - 空闲时对两级同步后的 SDA 连续采样 8 个 clk 周期的低电平，选择 master 或 slave 为拉低源。
  - 转发期间只向另一侧拉低，不反向驱动源端；源端连续 3 个采样为高后关闭转发，抑制短高脉冲导致的过早释放。
  - 每个 SDA 引脚的完整拉低使能（包括路由选择、外部转发和内部 ACK/读数据）均由寄存器输出，只在 clk 上升沿改变，复位时异步释放。输出不再与原始异步 SDA 组合相与，避免输入短脉冲及组合译码毛刺直接出现在目的端。
  - 关闭转发后等待 `SDA_RELEASE_CYC` 个 clk 周期，并清除旧采样，避免把尚未上升的目的端误当成新的拉低源。
  - 等待结束后重新检测两侧电平，允许 ACK 等场景中另一侧已拉低的交接；不要求两侧同时变高。
  - 外部地址不是 `0x7F` 时，内部字节状态机不再解析后续数据；START、STOP、ACK/NACK 和数据由电平透传。
- 内部事务（地址命中 `0x7F`）：
  - CPLD 内部驱动 ACK/读数据到 master
  - 屏蔽外部 slave SDA 驱动，避免并驱动

## 参数
- `CLK_FREQ_HZ`：内部逻辑时钟
- `I2C_SPEED_HZ`：I2C 线速率（用于设计约束/检查）
- `IDLE_FILTER_CYC`：空闲防抖窗口
- `SDA_RELEASE_CYC`：方向交接时的释放等待，默认 `CLK_FREQ_HZ / 1_000_000 + 2`（50 MHz 时约 1.04 us）。应大于板级 SDA 最坏上升时间，并预留采样裕量；转发延迟、释放等待和 8 周期低电平确认必须在下一次 SCL 采样前完成。默认配置针对 100 kHz，不能据此宣称支持所有 I2C 速率。
- 时序预算还需包含两级输入同步、方向状态更新、输出寄存器以及源端连续 3 拍高电平释放确认的延迟；不能只按 8 拍低电平确认估算。SDA 同步与滤波会延迟 START/STOP 转发，master 必须留足相对 SCL 的建立/保持时间。
- SCL 仍为 master 输入、slave 输出；仅协议采样使用同步值，物理 SCL 路径保持组合透传，不提供 SCL 去毛刺，也不支持 slave 时钟拉伸或多主机仲裁。
- 电平判向不能保证重叠拉低交接完全无高脉冲：CPLD 无法在释放旧目的端之前区分其低电平来自自身还是外部设备。释放等待用于避免回授自锁，但旧源端可能先上升，待重新判向后才被拉低。应让方向交接在 SCL 低期间完成；若要求交接绝无高脉冲，需使用具备相应保证的专用 I2C 双向缓冲器，不能仅靠延长数字滤波保证。

## 仿真
ModelSim:
```tcl
do sim/run.do
```

Icarus Verilog：
```sh
iverilog -g2005 -o sim.out rtl/i2c_cpld_switch.v tb/tb_i2c_cpld_switch.v
vvp sim.out
```
末尾打印 `SUMMARY: pass=N fail=M` 及 `PASS`/`FAIL`。

模拟 SDA 释放后延迟 1 us 才上升（覆盖低电平回授风险）：
```sh
iverilog -g2005 -s tb_i2c_cpld_switch -Ptb_i2c_cpld_switch.SDA_RISE_NS=1000 -o sim.out rtl/i2c_cpld_switch.v tb/tb_i2c_cpld_switch.v
vvp sim.out
```
TB 默认每 bit 为 3 × 3333 ns，约 100 kHz；`HP` 可覆盖各 bit-bang 子阶段的延时，`SDA_RISE_NS` 可覆盖 SDA 上升延迟。上板仍需验证电气负载和时序裕量。

## 测试方案（tb/tb_i2c_cpld_switch.v）
TB 内含 8 个 I2C slave 行为模型（地址 `0x50`，256 字节存储，指针自增；`mem[0xF0]` 预置 ID `0xC0+port`，用于确认透传路由），以及 2 个 master 的 bit-bang 驱动（START/STOP/Sr、写/读字节、ACK/NACK）。

### 0. 异步同步与输出使能检查
- 在非 clk 边沿同时改变全部 SCL/SDA 输入，检查第一拍同步值不变、第二拍更新，并检查 `i2c_master_sel` 两级同步。
- SCL/SDA 同时下降不产生 START。
- 全程检查 SDA 输出使能只在 clk 上升沿变化，且不会同时驱动 master 和 slave。

### 1. 内部 slave port 寄存器读写
- 复位值检查（`0x01 == 0x00`）。
- 依次向 `0x7F` 的 reg `0x01` 写 `0x88~0x8F`、`0xA5`、`0x5A`，再读回，打印 `WRITE x -> READ y MATCH/MISMATCH`，并检查 DUT 内部 `slave_port_sel`。
- 内部寄存器只支持 `S 0x7F+W, ACK, 0x01, ACK, Sr 0x7F+R, ACK, data, NACK, STOP` 读格式。

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
| E5b | 任意多字节外部写入 | 数据和 ACK 正确透传 |
| E5c | 与字节阶段无关的双向拉低、重叠拉低交接及短脉冲 | 正确选择源端，释放后不卡低；理想上升时间下扫描不同 clk 相位的 60 ns 低脉冲，并以输出边沿计数确认无透传；转发中的 40 ns 高脉冲不释放目的端 |
| E6 | 多字节突发读写 | 指针自增，数据一致 |
| E6b | 两个 master 分别写入并读回全部 256 种字节 | 全部匹配，包括连续 0、连续 1、ACK 交接及最终 NACK/STOP |
| E7 | 重新选择 slave port | 旧 slave 不再收到流量 |
| E8 | 异步复位 | `slave_port_sel`、`active_master_sel` 回到 0 |

### 已知现象
内部事务（地址 `0x7F`）的 START 与地址阶段在地址译码前会短暂透传到“之前选中”的 slave（该 slave 因地址不匹配不会 ACK）。TB 因此在配置 slave port 之后再统计“其它 slave 无流量”。

### 仿真结果
50 MHz clk、约 100 kHz I2C：理想 SDA 上升时间为 `pass=1264 fail=0`；1 us SDA 上升延迟为 `pass=1246 fail=0`，均为 `PASS`。短脉冲检查只在理想上升时间下执行，因此两个配置的检查总数不同。RTL 仿真不能模拟真实亚稳态或证明布局布线后的引脚无毛刺，上板仍需检查 CDC 报告和示波器波形。
