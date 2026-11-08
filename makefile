SHELL := /bin/sh
IVERILOG ?= iverilog
VVP ?= vvp
EX ?= apb
CASES := apb clkdiv spi_tx tristate fsm

.PHONY: all list run $(CASES)
all: $(CASES)
	@echo "ALL RESULT: PASS"
list:
	@echo "$(CASES)"
run:
	@test -f exercises/$(EX)/tb.v || { echo "Unknown exercise: $(EX)"; exit 1; }
	@mkdir -p sim
	@$(IVERILOG) -g2012 -Wall -s tb -o sim/$(EX).vvp exercises/$(EX)/design.v exercises/$(EX)/tb.v
	@$(VVP) sim/$(EX).vvp
$(CASES):
	@$(MAKE) --no-print-directory EX=$@ run
