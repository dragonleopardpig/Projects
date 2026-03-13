KVERSION ?= $(shell uname -r)
KREVISION ?= $(shell echo $(KVERSION) | cut -d'-' -f2 | cut -d'.' -f1)
ifeq (,$(KREVISION))
KREVISION := 0
endif
MODULE_LOWERCASE=$(shell echo $(MODULE) | tr '[A-Z]' '[a-z]')

ifeq ($(CONFIG_X86_64),y)
HARDENED =
ifeq ($(CONFIG_RETHUNK),y)
HARDENED = _h
else ifeq ($(CONFIG_MITIGATION_RETHUNK),y)
HARDENED = _h
endif
endif

ccflags-y := -DEURESYS_OS_LINUX -Wno-strict-prototypes -fno-exceptions -Wno-deprecated-declarations
ccflags-y += -D__DISABLE_TRACE_MMIO__
ccflags-$(CONFIG_64BIT) += -DEURESYS_PTRSIZE_64_BITS
ccflags-$(CONFIG_RETHUNK) += -DEURESYS_HARDENED
ccflags-$(CONFIG_MITIGATION_RETHUNK) += -DEURESYS_HARDENED
ldflags-y := -r
ldflags-$(CONFIG_X86_32) += $(M)/../precompiled/x86/mc_$(MODULE_LOWERCASE).o
ldflags-$(CONFIG_X86_64) += $(M)/../precompiled/x86_64/mc_$(MODULE_LOWERCASE)$(HARDENED).o
ldflags-$(CONFIG_ARM64)  += $(M)/../precompiled/aarch64/mc_$(MODULE_LOWERCASE).o
ldflags-$(CONFIG_ARM)    += $(M)/../precompiled/armv7a/mc_$(MODULE_LOWERCASE).o

ifneq (,$(wildcard /etc/redhat-release))
ifneq (,$(findstring 3.10.0-957,$(KVERSION)))
ccflags-$(CONFIG_X86) += -DOSAL_ENABLE_NO_SME_ACTIVE_WORKAROUND
endif
ifneq (,$(findstring 4.18.0,$(KVERSION)))
ifeq (,$(findstring 4.18.0-80.,$(KVERSION)))
ccflags-y += -DOSAL_ACCESS_OK_MACRO_2_ARGS
endif
endif
ifneq (,$(findstring 5.14.0-,$(KVERSION)))
ifeq (1,$(shell expr $(KREVISION) \>= 513))
ccflags-y += -DOSAL_GET_USER_PAGES_REMOTE_NO_VMAS
endif
ifneq (,$(wildcard $(srctree)/include/linux/stdarg.h))
ccflags-y += -DOSAL_EARLY_STDARG_MOVE
endif
endif
endif

ifeq ($(USE_PCI_ALLOC_CONSISTENT_TEGRA_WORKAROUND),)
ifneq (,$(wildcard /etc/nv_tegra_release))
USE_PCI_ALLOC_CONSISTENT_TEGRA_WORKAROUND := $(shell [ $$(sed -n 's/^\# R\([0-9]\+\).*/\1/p' /etc/nv_tegra_release) -ge 31 ] && echo 1)
endif
endif
ifeq ($(USE_PCI_ALLOC_CONSISTENT_TEGRA_WORKAROUND),1)
ccflags-$(CONFIG_ARM64) += -DPCI_ALLOC_CONSISTENT_TEGRA_WORKAROUND
endif

ifeq ($(USE_PCI_BRIDGE_INIT_TEGRA_WORKAROUND),)
ifneq (,$(wildcard /etc/nv_tegra_release))
USE_PCI_BRIDGE_INIT_TEGRA_WORKAROUND := 1
endif
endif
ifeq ($(USE_PCI_BRIDGE_INIT_TEGRA_WORKAROUND),1)
ccflags-y += -DPCI_BRIDGE_INIT_TEGRA_WORKAROUND
endif

ifneq ("$(MODULE)","memento")
PATH_TO_MEMENTO_MODULE_SYMVERS ?= /opt/euresys/memento/drivers/linux/Module.symvers
ifneq ("$(wildcard $(PATH_TO_MEMENTO_MODULE_SYMVERS))","")
export KBUILD_EXTRA_SYMBOLS=$(PATH_TO_MEMENTO_MODULE_SYMVERS)
else
ccflags-y += -DEURESYS_NO_MEMENTO
endif
endif

ifneq (,$(NVIDIA_KERNEL_PATH))
ifneq (,$(wildcard $(NVIDIA_KERNEL_PATH)/Module.symvers))
$(info Enabling NVIDIA RDMA build)
ccflags-y += -I$(NVIDIA_KERNEL_PATH) -DNVIDIA_RDMA
KBUILD_EXTRA_SYMBOLS:=$(KBUILD_EXTRA_SYMBOLS) $(NVIDIA_KERNEL_PATH)/Module.symvers
else
$(error Could not find NVIDIA Module.symvers, invalid NVIDIA_KERNEL_PATH)
endif
endif

M ?= .
obj-m := $(MODULE).o

CFILES := $(notdir $(wildcard $M/os_*.c))
OBJS := $(CFILES:.c=.o)

$(MODULE)-y := $(OBJS) $(MODULE)Ids.o

KDIR    ?= /lib/modules/$(KVERSION)/build
PWD     := $(shell pwd)

MODULES ?= $(MODULE)

SIGN_MOD ?= 0
SIGN_ALGO ?= sha256

ifeq ($(shell cat /proc/version | grep -q clang; echo $$?),0)
LLVM ?= 1
WITH_CLANG = "LLVM=$(LLVM)"
else
WITH_CLANG =
endif

default: SHELL:=/bin/bash
default:
	@for m in $(MODULES); do \
	    echo "Building $$m"; \
	    if [ x"$(HARDENED)" = x"_h" ]; then \
	        $(MAKE) $(WITH_CLANG) KDIR=$(KDIR) -f $(M)/Makefile.precomp MODULE=$$m; \
	    fi; \
	    $(MAKE) $(WITH_CLANG) -C $(KDIR) M=$(PWD) MODULE=$$m modules || exit $?; \
	    if [ $(SIGN_MOD) -eq 1 ]; then \
	        echo "Signing $$m"; \
	        grep -q ENCRYPTED $(SIGN_KEY); \
	        if [ $$? -eq 0 ]; then \
	            echo -n "Enter signing key passphrase: " >/dev/tty; \
	            read -s KBUILD_SIGN_PIN </dev/tty; \
	            export KBUILD_SIGN_PIN; \
	        fi; \
	        $(KDIR)/scripts/sign-file $(SIGN_ALGO) $(SIGN_KEY) $(SIGN_X509) $$m.ko || exit $?; \
	    fi; \
	    echo; \
	done

-include $(M)/sign.mk
-include $(M)/package.mk
-include $(M)/$(MODULE_LOWERCASE)_module.mk

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

