# Build for the plugin's native helpers.
#
# Plain GNU make on purpose. The whole native side is three translation units;
# a generator that writes a build system to build three files is machinery
# nobody here wants to review.
#
#   make                 build the helpers into build/
#   make test            build and run the unit tests
#   make check           the full CI gate: strict warnings, tests, sanitizers
#   make install         copy the helpers where slack.sh looks for them
#   make clean
#
# Knobs:
#   CXX=g++              compiler (default: clang++ if present, else c++)
#   STRICT=1             turn warnings into errors (CI does; a user build does not)
#   SANITIZE=1           build with AddressSanitizer and UndefinedBehaviorSanitizer
#   PORTABLE=1           link libstdc++/libgcc statically, for release artifacts
#   PREFIX=...           install root (default: the plugin's own cache dir)

# `?=` would lose to make's own built-in default for CXX, which is always set;
# `origin` is how you tell "the user asked for g++" from "make guessed".
ifeq ($(origin CXX),default)
  CXX := $(shell command -v clang++ 2>/dev/null || echo c++)
endif

BUILDDIR ?= build
PREFIX   ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/noctalia-slack
BINDIR   ?= $(PREFIX)/bin

# The source targets C++26. Older toolchains still build it, so probe downwards
# rather than refusing to run on a distro that shipped last year. c++2b is here
# because gcc 12 and clang 13-16 know that spelling but not c++23.
STD := $(shell for s in c++2c c++23 c++2b c++20; do \
	  if printf 'int main(){}' | $(CXX) -x c++ -std=$$s -fsyntax-only - >/dev/null 2>&1; \
	  then echo $$s; break; fi; done)
ifeq ($(STD),)
$(error $(CXX) accepts none of c++2c/c++23/c++2b/c++20 - too old to build this)
endif

CXX_IS_CLANG := $(shell $(CXX) --version 2>/dev/null | grep -qi clang && echo 1)
CXX_MAJOR    := $(firstword $(subst ., ,$(shell $(CXX) -dumpfullversion -dumpversion 2>/dev/null)))

# The library is a C++20 named module, and module support is where the two
# compilers most recently grew up. gcc 13 - still the default on Ubuntu 24.04
# LTS - segfaults compiling a four-line program that imports a module and uses
# std::string at -O2, so there is no version of "try anyway" worth offering.
ifeq ($(CXX_IS_CLANG),1)
  CXX_MIN := 17
else
  CXX_MIN := 14
endif
ifneq ($(shell test "$(CXX_MAJOR)" -ge "$(CXX_MIN)" 2>/dev/null && echo ok),ok)
$(error $(CXX) is version $(CXX_MAJOR); C++20 modules need clang >= 17 or gcc >= 14. \
  Try `make CXX=g++-14` or `make CXX=clang++`. The plugin does not need this built - \
  without it, link previews fall back to slack.sh's shell parser.)
endif

# Everything that has ever caught a real bug in this code, plus the conversion
# warnings, which are the ones that matter when the input is attacker-shaped
# bytes and every other line is an index or a shift.
WARNINGS := \
	-Wall -Wextra -Wpedantic \
	-Wshadow -Wconversion -Wsign-conversion -Wold-style-cast \
	-Wcast-qual -Wcast-align -Wdouble-promotion -Wformat=2 \
	-Wimplicit-fallthrough -Wmissing-declarations -Wnon-virtual-dtor \
	-Woverloaded-virtual -Wnull-dereference -Wundef -Wunused -Wextra-semi \
	-Wswitch-default -Wredundant-decls -Wwrite-strings

ifeq ($(CXX_IS_CLANG),1)
  WARNINGS += -Wloop-analysis -Wrange-loop-analysis -Wunreachable-code
else
  WARNINGS += -Wduplicated-cond -Wduplicated-branches -Wlogical-op -Wuseless-cast
endif

# -Werror is a CI gate, not a user-facing one: a compiler newer than this commit
# will eventually invent a warning, and that must not be the thing that stops
# someone's link previews from building on first use.
ifeq ($(STRICT),1)
  WARNINGS += -Werror
endif

# _GLIBCXX_ASSERTIONS turns container preconditions into aborts, and
# _FORTIFY_SOURCE catches the obvious overflows; both are cheap here.
HARDENING := -D_GLIBCXX_ASSERTIONS -D_FORTIFY_SOURCE=2 \
	-fstack-protector-strong -fno-delete-null-pointer-checks

# Flags the build owns, kept separate from CXXFLAGS: `make CXXFLAGS=-O0` on the
# command line replaces the variable wholesale, and silently dropping -std from
# a build whose sources are modules produces a wall of nonsense errors.
OPT ?= -O2
BUILD_CXXFLAGS = $(OPT) -std=$(STD) $(WARNINGS) $(HARDENING) -g $(CXXFLAGS)
BUILD_LDFLAGS  = $(LDFLAGS)

SAN := -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all

# The sanitized pass is clang-only, and not by preference: gcc 14 hits an
# internal compiler error (cp/module.cc:9455) compiling a module unit with
# -fsanitize at all. Nothing in the build can route around that, so say it
# rather than letting someone discover it.
#
# Even on clang, some distros ship the compiler without its sanitizer runtime
# and the failure surfaces as a linker error about libclang_rt several steps
# later, so probe for that too.
ifeq ($(CXX_IS_CLANG),1)
  CAN_SANITIZE := $(shell printf 'int main(){}' | $(CXX) -x c++ $(SAN) -o /dev/null - >/dev/null 2>&1 && echo 1)
  SAN_UNAVAILABLE := $(CXX) cannot link the sanitizer runtime - install it (libclang-rt-*-dev)
else
  CAN_SANITIZE :=
  SAN_UNAVAILABLE := $(CXX) is gcc, which ICEs compiling a module with -fsanitize - use CXX=clang++
endif

ifeq ($(SANITIZE),1)
  ifneq ($(CAN_SANITIZE),1)
    $(error $(SAN_UNAVAILABLE))
  endif
  BUILD_CXXFLAGS += $(SAN)
  BUILD_LDFLAGS  += $(SAN)
endif

# QML has no compiler to run in CI, but qmlformat parses it, and a parse gate is
# most of what a QML syntax error costs you. qmllint would be better still and
# is deliberately not used: it cannot resolve Noctalia's qs.Commons/qs.Widgets
# modules, so every run drowns in unresolved-import warnings.
QMLFORMAT := $(shell command -v qmlformat 2>/dev/null || echo /usr/lib/qt6/bin/qmlformat)
QML_FILES := $(wildcard *.qml Components/*.qml)

ifeq ($(PORTABLE),1)
  # A release binary has to run against whatever libstdc++ the user's distro
  # shipped, which may well be older than the one that built it.
  BUILD_LDFLAGS += -static-libstdc++ -static-libgcc
endif

# ---------------------------------------------------------------- modules
#
# The library is a C++20 named module, so a module unit has to be compiled
# before anything that imports it, and the two compilers spell that completely
# differently. This is the whole cost of using modules in a hand-written build,
# and at this size it is about fifteen lines:
#
#   clang  --precompile writes a .pcm, which is then compiled to an object like
#          any other TU; importers find it via -fprebuilt-module-path.
#   gcc    compiles the module unit straight to an object and writes a .gcm on
#          the side. Where that .gcm lands is decided by a mapper file, which is
#          how the build keeps binary module interfaces out of the source tree
#          (gcc's default is a gcm.cache/ directory next to wherever it was run,
#          and this build is often run from someone's checkout).
MODULE_NAME := slack.html
MODULE_SRC  := native/html_meta.cppm
MODULE_OBJ  := $(BUILDDIR)/html_meta.o

ifeq ($(CXX_IS_CLANG),1)
  MODULE_BMI   := $(BUILDDIR)/$(MODULE_NAME).pcm
  MODULE_IMPORT = -fprebuilt-module-path=$(BUILDDIR)
else
  MODULE_BMI   := $(BUILDDIR)/$(MODULE_NAME).gcm
  MODULE_MAP   := $(BUILDDIR)/modules.map
  MODULE_FLAGS  = -fmodules-ts -fmodule-mapper=$(MODULE_MAP)
  MODULE_IMPORT = $(MODULE_FLAGS)
endif

UNFURL_SRC := native/unfurl_main.cpp
TEST_SRC   := native/tests/html_meta_test.cpp
FUZZ_SRC   := native/tests/html_meta_fuzz.cpp
CORPUS     := native/tests/corpus

UNFURL := $(BUILDDIR)/slack-unfurl
TEST   := $(BUILDDIR)/html_meta_test
FUZZ   := $(BUILDDIR)/html_meta_fuzz

.PHONY: all test check qml fuzz install uninstall clean help print-config

all: $(UNFURL)

ifeq ($(CXX_IS_CLANG),1)

$(MODULE_BMI): $(MODULE_SRC) | $(BUILDDIR)
	$(CXX) $(BUILD_CXXFLAGS) --precompile -o $@ $<

$(MODULE_OBJ): $(MODULE_BMI)
	$(CXX) $(BUILD_CXXFLAGS) -c -o $@ $<

else

$(MODULE_MAP): | $(BUILDDIR)
	@printf '%s %s\n' $(MODULE_NAME) $(MODULE_BMI) > $@

# gcc emits the .gcm as a side effect of compiling the module unit, so the
# object is the target and the BMI comes along with it.
$(MODULE_OBJ): $(MODULE_SRC) $(MODULE_MAP) | $(BUILDDIR)
	$(CXX) $(BUILD_CXXFLAGS) $(MODULE_FLAGS) -x c++ -c -o $@ $<

$(MODULE_BMI): $(MODULE_OBJ)

endif

$(BUILDDIR)/unfurl_main.o: $(UNFURL_SRC) $(MODULE_BMI) | $(BUILDDIR)
	$(CXX) $(BUILD_CXXFLAGS) $(MODULE_IMPORT) -c -o $@ $<

$(BUILDDIR)/html_meta_test.o: $(TEST_SRC) $(MODULE_BMI) | $(BUILDDIR)
	$(CXX) $(BUILD_CXXFLAGS) $(MODULE_IMPORT) -c -o $@ $<

$(UNFURL): $(MODULE_OBJ) $(BUILDDIR)/unfurl_main.o
	$(CXX) $(BUILD_CXXFLAGS) -o $@ $^ $(BUILD_LDFLAGS)

$(TEST): $(MODULE_OBJ) $(BUILDDIR)/html_meta_test.o
	$(CXX) $(BUILD_CXXFLAGS) -o $@ $^ $(BUILD_LDFLAGS)

$(BUILDDIR):
	@mkdir -p $(BUILDDIR)

test: $(TEST)
	@$(TEST)

# What CI runs: the strict build, the tests, and the tests again under the
# sanitizers. The sanitized pass is a separate sub-make because it needs
# different flags for the same sources.
check:
	@$(MAKE) --no-print-directory STRICT=1 all test
	@echo "--- sanitizers ---"
ifeq ($(CAN_SANITIZE),1)
	@$(MAKE) --no-print-directory STRICT=1 SANITIZE=1 BUILDDIR=$(BUILDDIR)/san test
else
	@echo "skipped: $(SAN_UNAVAILABLE)"
endif
	@$(MAKE) --no-print-directory qml

qml:
	@if [ ! -x "$(QMLFORMAT)" ]; then \
	  echo "skipped: qmlformat not found (install qt6-declarative-dev-tools)"; exit 0; \
	fi; \
	fail=0; \
	for f in $(QML_FILES); do \
	  if "$(QMLFORMAT)" -n "$$f" >/dev/null; then echo "ok   $$f"; else fail=1; fi; \
	done; \
	exit $$fail

# libFuzzer, which is clang-only. Sixty seconds of this on every CI run is worth
# more than any number of hand-written malformed-input cases, because the parser
# reads bytes chosen by whoever owns the page behind a pasted link.
#
#   make fuzz FUZZ_TIME=300      longer local run
$(FUZZ): $(FUZZ_SRC) $(MODULE_BMI) $(MODULE_OBJ) | $(BUILDDIR)
	@if [ "$(CXX_IS_CLANG)" != "1" ]; then \
	  echo "fuzzing needs clang (libFuzzer); try make fuzz CXX=clang++" >&2; exit 1; \
	fi
	$(CXX) $(BUILD_CXXFLAGS) $(MODULE_IMPORT) -fsanitize=fuzzer,address,undefined \
	  -o $@ $(FUZZ_SRC) $(MODULE_OBJ)

FUZZ_TIME ?= 60

fuzz: $(FUZZ)
	@mkdir -p $(BUILDDIR)/corpus
	$(FUZZ) -max_total_time=$(FUZZ_TIME) -max_len=65536 -print_final_stats=1 \
	  $(BUILDDIR)/corpus $(CORPUS)

install: $(UNFURL)
	@mkdir -p $(BINDIR)
	install -m 0755 $(UNFURL) $(BINDIR)/slack-unfurl
	@echo "installed $(BINDIR)/slack-unfurl"

uninstall:
	rm -f $(BINDIR)/slack-unfurl

clean:
	rm -rf $(BUILDDIR)

print-config:
	@echo "CXX      = $(CXX)"
	@echo "STD      = $(STD)"
	@echo "VERSION  = $(CXX_MAJOR) (modules need >= $(CXX_MIN))"
	@echo "STRICT   = $(if $(filter 1,$(STRICT)),on,off)"
	@echo "SANITIZE = $(if $(filter 1,$(SANITIZE)),on,off)"
	@echo "BINDIR   = $(BINDIR)"
	@echo "SANITIZERS AVAILABLE = $(if $(filter 1,$(CAN_SANITIZE)),yes,no)"

help:
	@sed -n '1,20p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \{0,1\}//'
