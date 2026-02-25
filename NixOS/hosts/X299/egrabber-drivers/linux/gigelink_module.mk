GEV_COMMON_DIR ?= ../Common
GEV_DIR := $(M)
$(MODULE)-y := s2i_filter.o s2i_os.o s2i_utils.o os_no_memento.o os_time.o
ccflags-y += -DEURESYS_WITH_MEMENTO -DEURESYS_OS_LINUX -I$(M) -I$(GEV_DIR)/$(GEV_COMMON_DIR) -DS2I_FILTER_NAME=KBUILD_MODNAME
