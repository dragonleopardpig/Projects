savedcmd_os_no_memento.o := gcc -Wp,-MMD,./.os_no_memento.o.d -nostdinc -I/nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/arch/x86/include -I/nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/build/arch/x86/include/generated -I/nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/include -I/nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/build/include -I/nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/arch/x86/include/uapi -I/nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/build/arch/x86/include/generated/uapi -I/nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/include/uapi -I/nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/build/include/generated/uapi -include /nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/include/linux/compiler-version.h -include /nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/include/linux/kconfig.h -include /nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/include/linux/compiler_types.h -D__KERNEL__ -std=gnu11 -fshort-wchar -funsigned-char -fno-common -fno-PIE -fno-strict-aliasing -mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -mno-sse4a -fcf-protection=branch -fno-jump-tables -m64 -falign-jumps=1 -falign-loops=1 -mno-80387 -mno-fp-ret-in-387 -mpreferred-stack-boundary=3 -mskip-rax-setup -march=x86-64 -mtune=generic -mno-red-zone -mcmodel=kernel -mstack-protector-guard-reg=gs -mstack-protector-guard-symbol=__ref_stack_chk_guard -Wno-sign-compare -fno-asynchronous-unwind-tables -mindirect-branch=thunk-extern -mindirect-branch-register -mindirect-branch-cs-prefix -mfunction-return=thunk-extern -fno-jump-tables -mharden-sls=all -fpatchable-function-entry=16,16 -fno-delete-null-pointer-checks -O2 -fno-allow-store-data-races -fstack-protector-strong -ftrivial-auto-var-init=zero -fzero-init-padding-bits=all -fno-stack-clash-protection -pg -mrecord-mcount -mfentry -DCC_USING_FENTRY -fmin-function-alignment=16 -fstrict-flex-arrays=3 -fms-extensions -fno-strict-overflow -fno-stack-check -fconserve-stack -fno-builtin-wcslen -Wall -Wextra -Wundef -Werror=implicit-function-declaration -Werror=implicit-int -Werror=return-type -Werror=strict-prototypes -Wno-format-security -Wno-trigraphs -Wno-frame-address -Wno-address-of-packed-member -Wmissing-declarations -Wmissing-prototypes -Wframe-larger-than=2048 -Wno-main -Wno-dangling-pointer -Wvla-larger-than=1 -Wno-pointer-sign -Wcast-function-type -Wno-unterminated-string-initialization -Wno-array-bounds -Wno-stringop-overflow -Wno-alloc-size-larger-than -Wimplicit-fallthrough=5 -Werror=date-time -Werror=incompatible-pointer-types -Werror=designated-init -Wenum-conversion -Wunused -Wno-unused-but-set-variable -Wno-unused-const-variable -Wno-packed-not-aligned -Wno-format-overflow -Wno-format-truncation -Wno-stringop-truncation -Wno-override-init -Wno-missing-field-initializers -Wno-type-limits -Wno-shift-negative-value -Wno-maybe-uninitialized -Wno-sign-compare -Wno-unused-parameter -g -DGCC_PLUGINS -DEURESYS_OS_LINUX -Wno-strict-prototypes -fno-exceptions -Wno-deprecated-declarations -DEURESYS_PTRSIZE_64_BITS -DEURESYS_HARDENED -DEURESYS_NO_MEMENTO -DEURESYS_NO_MEMENTO -DEURESYS_WARN_IF_NO_MEMENTO  -DMODULE  -DKBUILD_BASENAME='"os_no_memento"' -DKBUILD_MODNAME='"grablink"' -D__KBUILD_MODNAME=grablink -c -o os_no_memento.o os_no_memento.c  

source_os_no_memento.o := os_no_memento.c

deps_os_no_memento.o := \
  /nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/include/linux/compiler-version.h \
    $(wildcard include/config/CC_VERSION_TEXT) \
  /nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/build/include/generated/gcc-plugins.h \
  /nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/include/linux/kconfig.h \
    $(wildcard include/config/CPU_BIG_ENDIAN) \
    $(wildcard include/config/BOOGER) \
    $(wildcard include/config/FOO) \
  /nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/include/linux/compiler_types.h \
    $(wildcard include/config/DEBUG_INFO_BTF) \
    $(wildcard include/config/PAHOLE_HAS_BTF_TAG) \
    $(wildcard include/config/FUNCTION_ALIGNMENT) \
    $(wildcard include/config/CC_HAS_SANE_FUNCTION_ALIGNMENT) \
    $(wildcard include/config/X86_64) \
    $(wildcard include/config/ARM64) \
    $(wildcard include/config/LD_DEAD_CODE_DATA_ELIMINATION) \
    $(wildcard include/config/LTO_CLANG) \
    $(wildcard include/config/HAVE_ARCH_COMPILER_H) \
    $(wildcard include/config/CC_HAS_ASSUME) \
    $(wildcard include/config/CC_HAS_COUNTED_BY) \
    $(wildcard include/config/CC_HAS_MULTIDIMENSIONAL_NONSTRING) \
    $(wildcard include/config/UBSAN_INTEGER_WRAP) \
    $(wildcard include/config/CFI) \
    $(wildcard include/config/ARCH_USES_CFI_GENERIC_LLVM_PASS) \
    $(wildcard include/config/CC_HAS_ASM_INLINE) \
  /nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/include/linux/compiler_attributes.h \
  /nix/store/jm1r8xwcalll7b85h9gippv50w7ixwzb-linux-6.19.2-dev/lib/modules/6.19.2/source/include/linux/compiler-gcc.h \
    $(wildcard include/config/ARCH_USE_BUILTIN_BSWAP) \
    $(wildcard include/config/SHADOW_CALL_STACK) \
    $(wildcard include/config/KCOV) \
    $(wildcard include/config/CC_HAS_TYPEOF_UNQUAL) \
  os_types.h \
  ../os_size_t.h \

os_no_memento.o: $(deps_os_no_memento.o)

$(deps_os_no_memento.o):
