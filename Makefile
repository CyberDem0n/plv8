
PLV8_VERSION = 3.2.5
V8_CMAKE_DIR := deps/v8-cmake
V8_BUILD_DIR := $(V8_CMAKE_DIR)/build

CP := cp
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
PG_CPPFLAGS := -fPIC -Wall -Wno-register -xc++

SRCS = plv8.cc plv8_type.cc plv8_func.cc plv8_param.cc plv8_allocator.cc plv8_guc.cc
OBJS = $(SRCS:.cc=.o)
MODULE_big = plv8
EXTENSION = plv8
PLV8_DATA = plv8.control plv8--$(PLV8_VERSION).sql

# Patches applied to the v8-cmake submodule when it is first checked out.
# gcc14-stats-collector.patch: GCC 14 / libstdc++ 14 no longer provides
# std::remove transitively, so the header must include <algorithm> itself
# (fixed upstream in V8 11.6).
PATCH_V8 := patches/v8-cmake/gcc14-stats-collector.patch

ifeq ($(OS),Windows_NT)
	# noop for now
else
	SHLIB_LINK += -L$(V8_BUILD_DIR)
	UNAME_S := $(shell uname -s)
	ifeq ($(UNAME_S),Darwin)
		CCFLAGS += -stdlib=libc++
		SHLIB_LINK += -stdlib=libc++ -lc++
		NUMPROC := $(shell sysctl hw.ncpu | awk '{print $$2}')
		PATCH_V8 += patches/v8-cmake/macos-build.patch
	endif
	ifeq ($(UNAME_S),Linux)
		SHLIB_LINK += -lrt
		NUMPROC := $(shell grep -c ^processor /proc/cpuinfo)
	endif
endif

ifeq ($(NUMPROC),0)
	NUMPROC = 1
endif

all: v8 $(OBJS)

# For some reason, this solves parallel make dependency.
plv8_config.h plv8.so: v8

$(V8_CMAKE_DIR)/README.md:
	@git submodule update --init --recursive
	cd deps/v8-cmake && $(foreach patch,$(PATCH_V8),patch -p1 <../../$(patch) &&) true

$(V8_BUILD_DIR)/libv8_snapshot.a: $(V8_CMAKE_DIR)/README.md
	@cmake -S $(V8_CMAKE_DIR) -B $(V8_BUILD_DIR) -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release $(V8_SANDBOX_CMAKE_ARGS) $(V8_CMAKE_ARGS) && cmake --build $(V8_BUILD_DIR) -j$(NUMPROC) --target v8_snapshot

v8: $(V8_BUILD_DIR)/libv8_snapshot.a

# Extra arguments for the v8-cmake configure step, for example
# V8_CMAKE_ARGS='-DCMAKE_CXX_FLAGS=-fstack-protector-strong'.
V8_CMAKE_ARGS ?=

# enable direct jsonb conversion by default
CCFLAGS += -DJSONB_DIRECT_CONVERSION

CCFLAGS += -I$(V8_CMAKE_DIR)/v8/include -Wno-pointer-arith -Wno-comment

# Pointer compression + V8 sandbox. These are ABI-affecting, so the SAME switches
# drive the v8-cmake configure (V8_SANDBOX_CMAKE_ARGS, so the library matches) and
# the -D defines below (so this embedder matches). A mismatch aborts the backend
# at isolate init. Default on; override on the make command line, e.g.
# `make V8_ENABLE_SANDBOX=0` or `make V8_ENABLE_POINTER_COMPRESSION=0 V8_ENABLE_SANDBOX=0`.
V8_ENABLE_POINTER_COMPRESSION ?= 1
V8_ENABLE_SANDBOX ?= 1

ifeq ($(V8_ENABLE_SANDBOX),1)
override V8_ENABLE_POINTER_COMPRESSION := 1
endif

ifeq ($(V8_ENABLE_POINTER_COMPRESSION),1)
CCFLAGS += -DV8_COMPRESS_POINTERS \
	-DV8_COMPRESS_POINTERS_IN_SHARED_CAGE \
	-DV8_31BIT_SMIS_ON_64BIT_ARCH \
	-DV8_EXTERNAL_CODE_SPACE
V8_SANDBOX_CMAKE_ARGS += -DV8_ENABLE_POINTER_COMPRESSION=ON
else
V8_SANDBOX_CMAKE_ARGS += -DV8_ENABLE_POINTER_COMPRESSION=OFF
endif

ifeq ($(V8_ENABLE_SANDBOX),1)
CCFLAGS += -DV8_ENABLE_SANDBOX
V8_SANDBOX_CMAKE_ARGS += -DV8_ENABLE_SANDBOX=ON
else
V8_SANDBOX_CMAKE_ARGS += -DV8_ENABLE_SANDBOX=OFF
endif

ifdef EXECUTION_TIMEOUT
	CCFLAGS += -DEXECUTION_TIMEOUT
endif

ifdef BIGINT_GRACEFUL
	CCFLAGS += -DBIGINT_GRACEFUL
endif

DATA = $(PLV8_DATA)
DATA_built = plv8.sql
REGRESS = init-extension plv8 plv8-errors scalar_args inline json startup_pre startup varparam json_conv \
		  jsonb_conv window guc es6 arraybuffer composites currentresource startup_perms bytea find_function_perms \
		  memory_limits reset show array_spread regression procedure security_definer

ifndef BIGINT_GRACEFUL
	REGRESS += bigint
else
	REGRESS += bigint_graceful
endif

SHLIB_LINK += -Wl,--exclude-libs,ALL,--start-group \
	-lv8_base_without_compiler \
	-lv8_compiler \
	-lv8_libbase \
	-lv8_libplatform \
	-lv8_libsampler \
	-lv8_snapshot \
	-lv8_torque_generated \
	-Wl,--end-group

OPTFLAGS = -std=c++20 -fno-rtti -O2
CCFLAGS += -Wall $(OPTFLAGS)

generate_upgrades:
	@mkdir -p upgrade
	@./generate_upgrade.sh $(PLV8_VERSION)
	$(eval PLV8_DATA +=  $(wildcard upgrade/*.sql))

all: generate_upgrades

plv8_config.h: plv8_config.h.in Makefile
	sed -e 's/^#undef PLV8_VERSION/#define PLV8_VERSION "$(PLV8_VERSION)"/' $< > $@

%.o : %.cc plv8_config.h plv8.h
	$(CXX) $(CCFLAGS) $(CPPFLAGS) -fconcepts -fPIC -c -o $@ $<

COMPILE.cxx.bc = $(CLANG) -xc++ -Wno-ignored-attributes $(BITCODE_CXXFLAGS) $(CCFLAGS) $(CPPFLAGS) -emit-llvm -c

%.bc : %.cc
	$(COMPILE.cxx.bc) $(CCFLAGS) $(CPPFLAGS) -fPIC -c -o $@ $<
	$(LLVM_BINPATH)/opt -module-summary -f $@ -o $@

DATA_built =

all: $(DATA)

%--$(PLV8_VERSION).sql: plv8.sql.common
	sed -e 's/@LANG_NAME@/$*/g' $< | sed -e 's/@PLV8_VERSION@/$(PLV8_VERSION)/g' | $(CC) -E -P $(CPPFLAGS) -DLANG_$* - > $@

%.control: plv8.control.common
	sed -e 's/@PLV8_VERSION@/$(PLV8_VERSION)/g' $< | $(CXX) -E -P -DLANG_$* - > $@

subclean:
	rm -f plv8_config.h $(DATA)

clean: subclean

distclean: clean
	@cd $(V8_BUILD_DIR) && make clean

.PHONY: subclean all clean installcheck

include $(PGXS)
# PGXS links MODULE_big with $(CC); point it at the C++ compiler.
CC=$(CXX)
# Do not leak the PGXS toolchain settings into the v8-cmake build.  Packaging
# environments export CC and the *FLAGS variables (rpm's %set_build_flags,
# which EL10/Fedora apply automatically; Debian's dpkg-buildflags), and make
# then re-exports whatever this Makefile and PGXS turned them into.  CC=g++
# makes CMake fail its C compiler check, and PostgreSQL's CXXFLAGS (for
# example -flto=auto) break the V8 link.  V8 is built with its own flags;
# use V8_CMAKE_ARGS to pass additional options to cmake.
unexport CC CFLAGS CXXFLAGS LDFLAGS
