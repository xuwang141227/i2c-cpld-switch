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
