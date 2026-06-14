# Makefile for the imported CTSRD cheritest subset on r9999.
#
# Targets:
#   make import          # copy + build the alu/branch/mem/cp0/tlb subset
#   make test            # run the whole imported suite under pytest
#   make test-alu        # run one category (alu|branch|mem|cp0|tlb)
#   make clean
#
# The ELF for each test is built by import_tests.py (n32 big-endian ELF32).
# beritest_tools.py runs ../../ooo_core on each ELF and parses the R<dd>=<hex>
# register dump our macros/dump shim prints.

PY      ?= python3
PYTEST  ?= $(PY) -m pytest
CATS    := alu branch mem cp0 tlb

.PHONY: import test clean $(addprefix test-,$(CATS))

import:
	$(PY) import_tests.py $(CATS)

test:
	$(PYTEST) $(CATS) -p no:cacheprovider --tb=line -q -rfE

$(addprefix test-,$(CATS)): test-%:
	$(PYTEST) $* -p no:cacheprovider --tb=line -q -rfE

clean:
	rm -f common/*.o $(foreach c,$(CATS),$c/*.o $c/*.elf)
	rm -rf .pytest_cache $(foreach c,$(CATS),$c/__pycache__) __pycache__
