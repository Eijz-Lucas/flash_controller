# =============================================================================
# Flash Controller 教学项目 —— Makefile
#
# 依赖：Icarus Verilog 12.0（本机装在 /usr/local/bin，Arch 仓库只有 13.0）
#       gtkwave 可选，只有 `make gui` 用得到
#
# 产物全部写进 sim/，recipe 不往仓库根目录写任何东西。
# 每个用例失败时 vvp 会以非零码退出（tb_common.vh 里用 $fatal），
# 所以 `make all` 中途失败会立刻停下来。
#
#     make            等价于 make all
#     make list       只列出用例，不编译
#     make read       跑单个用例（**同时留下 sim/read.vcd**）
#     make NOWAVE=1 all   快跑一遍，不生成波形
#     make vcd        列出已生成的波形
#     make clean
# =============================================================================

SHELL    := /bin/sh
IVERILOG ?= iverilog
VVP      ?= vvp
IFLAGS   ?= -g2012 -Wall
SIM      ?= sim

# 用例名（make 的目标）-> 测试模块名（文件 testbench/<模块>.v）
tc_apb   := tc_apb_proto
tc_regs  := tc_reg_rw
tc_read  := tc_fast_read
tc_addr  := tc_addr_sweep
tc_b2b   := tc_back2back
tc_div   := tc_clkdiv
tc_quad  := tc_quad_read
tc_write := tc_write_read

CASES := apb regs read addr b2b div quad write

.PHONY: all default smoke $(CASES) wave gui vcd clean clean-keep-vcd list help check-iverilog

# -----------------------------------------------------------------------------
# 波形 —— **每个用例默认都生成**，这是本工程的常态，不是可选项
#
# 这是拿来教学的工程，波形是主要观察手段；要波形还得记一条专门的命令，迟早会
# 出现「明明跑过怎么没波形」。所以 dump 直接并进正常流程。
#
# 代价是仿真变慢、sim/ 变大。要快跑一遍：make NOWAVE=1 all
#
# 实现：harness 里的 dump 代码是 `ifdef DUMPFILE 包着的，所以用 -DDUMPFILE 把
# 路径当**字符串宏**传进去（宏要展开成字符串字面量，因此外层带引号）。
# DUMPFLAG 写成递归展开（= 而不是 :=），$@ 才能在 recipe 里取到当前用例名 ——
# 于是 sim/<用例名>.vcd 自动对号入座，不用给每个用例单写一条规则。
# -----------------------------------------------------------------------------
NOWAVE ?=
ifeq ($(NOWAVE),1)
DUMPFLAG =
else
DUMPFLAG = -DDUMPFILE='"$(SIM)/$@.vcd"'
endif

all: check-iverilog smoke $(CASES)
	@echo ""
	@echo "全部用例通过。"

default: all

# -----------------------------------------------------------------------------
# 环境自检：本工程的 RTL/TB 依赖 iverilog 12.0
# -----------------------------------------------------------------------------
check-iverilog:
	@$(IVERILOG) -V 2>&1 | grep -q "version 12\." || { \
	    echo "错误: 需要 Icarus Verilog 12.x，实际是："; \
	    $(IVERILOG) -V 2>&1 | head -1; \
	    echo "（用 make IVERILOG=/path/to/iverilog 指定其它版本）"; \
	    exit 1; }
	@echo "[环境] $$($(IVERILOG) -V 2>&1 | head -1)"

# -----------------------------------------------------------------------------
# Flash 模型冒烟测试
#
# 它不经过 APB，直接手搓 cs_n/sclk 驱动模型。**先跑它**是刻意的：
# 模型通过之后，任何 tc_* 的失败都只可能出在 RTL / pad / TB，不可能在模型。
# -----------------------------------------------------------------------------
smoke:
	@echo "---- smoke ----"
	@mkdir -p $(SIM)
	@$(IVERILOG) $(IFLAGS) $(DUMPFLAG) -c filelist/flash_model_tb.f -s flash_model_tb \
	    -o $(SIM)/flash_model_tb.vvp
	@$(VVP) $(SIM)/flash_model_tb.vvp

# -----------------------------------------------------------------------------
# 测试用例
#
# $(tc_$@) 取「以目标名为后缀的那个变量」，即上面的用例名 -> 模块名映射。
# filelist 不能嵌套（iverilog 的 -c 每行只能一个文件），所以这里把
# rtl.f + dtb.f + tc_<case>.f 三份 cat 成一份再编译。
# -----------------------------------------------------------------------------
$(CASES):
	@echo "---- $(tc_$@) ----"
	@mkdir -p $(SIM)
	@cat filelist/rtl.f filelist/dtb.f filelist/$(tc_$@).f > $(SIM)/$(tc_$@).f
	@$(IVERILOG) $(IFLAGS) $(DUMPFLAG) -c $(SIM)/$(tc_$@).f -s $(tc_$@) -o $(SIM)/$(tc_$@).vvp
	@$(VVP) $(SIM)/$(tc_$@).vvp

# -----------------------------------------------------------------------------
# 波形相关的小工具
#
# 波形已经是每个用例的默认产物，所以 wave 不再是「生成波形」的命令，只是
# `make <用例>` 的一个别名 —— 留着是为了不让旧习惯和旧文档里的命令失效。
# -----------------------------------------------------------------------------
TC ?= read

wave:
	@test -f filelist/$(tc_$(TC)).f || { \
	    echo "错误: 未知用例 '$(TC)'。可用: $(CASES)"; exit 1; }
	@$(MAKE) --no-print-directory $(TC)

# 列出已生成的波形（终端里方便复制路径）
vcd:
	@ls -l $(SIM)/*.vcd 2>/dev/null || \
	    echo "还没有波形。跑 make all（或 make <用例>）就有了。"

# 用 VSCode 打开某个用例的波形。
# 本机没装 gtkwave；Surfer 是 VSCode 插件，由它接管 .vcd 的打开方式，
# 所以这里只需要把文件交给 code。
gui:
	@test -f $(SIM)/$(TC).vcd || { \
	    echo "错误: 找不到 $(SIM)/$(TC).vcd —— 先跑 make $(TC)"; exit 1; }
	@command -v code >/dev/null 2>&1 || { \
	    echo "找不到 code 命令；波形在 $(SIM)/$(TC).vcd，手动打开即可"; exit 1; }
	@code $(SIM)/$(TC).vcd

# -----------------------------------------------------------------------------
# 杂项
# -----------------------------------------------------------------------------
list:
	@echo "可用用例："
	@echo "  smoke   Flash 模型冒烟测试（不经过 APB，先跑这个）"
	@echo "  apb     APB 协议握手 / 未映射地址 / 写后读回"
	@echo "  regs    寄存器映射写后读回，含 SPILEN 位宽截断"
	@echo "  read    核心用例：一次完整的 STIG 单线 Fast Read"
	@echo "  addr    24 bit 地址通路（含 0xFFFFFC / 0xFFFFF8 边界）"
	@echo "  b2b     连续两次读，中间不复位"
	@echo "  div     clk_div=49 -> 1 MHz，8 个 dummy，共 72 个 SPI 时钟"
	@echo "  quad    0x6B 四线读，与单线结果交叉验证位序"
	@echo "  write   写通路：WREN 0x06 + Page Program 0x02 + 读回逐位相等"
	@echo ""
	@echo "每个用例跑完都会留下 sim/<用例名>.vcd。"
	@echo ""
	@echo "  make all            跑全部（9 份波形）"
	@echo "  make read           跑单个用例"
	@echo "  make NOWAVE=1 all   快跑一遍，不生成波形"
	@echo "  make vcd            列出已生成的波形"
	@echo "  make gui TC=write   用 VSCode 打开 sim/write.vcd"
	@echo "  make clean          删掉整个 sim/（含波形）"
	@echo "  make clean-keep-vcd 只删编译产物，保留波形"

clean:
	@rm -rf $(SIM)
	@echo "已删除 $(SIM)/（含波形）"

# 只删编译产物，保留波形。
# 波形是 sim/ 里最贵的那份东西 —— 要重跑整个仿真才回得来。顺手 rm -rf 掉，
# 很容易让人以为「我明明跑过怎么没波形」，其实是被 clean 清掉了。
clean-keep-vcd:
	@rm -f $(SIM)/*.vvp $(SIM)/*.f
	@echo "已删除 vvp 与展开的 f，保留 $(SIM)/*.vcd"

help: list
