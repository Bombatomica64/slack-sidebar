# Build for the plugin's native helpers.
#
# Plain GNU make on purpose. The whole native side is three translation units;
# a generator that writes a build system to build three files is machinery
# nobody here wants to review.
#
#   make                 build the helpers into build/
#   make test            build and run the unit tests
#   make check           the full CI gate: strict warnings, tests, sanitizers
#   make install         install the agent where the plugin looks for it
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

# Our own code is C++20 named modules, and module support is where the compilers
# most recently grew up. This build is clang-only, and not by preference:
#
#   gcc 13  segfaults compiling a four-line program that imports a module and
#           uses std::string at -O2. It is still the default on Ubuntu 24.04 LTS.
#   gcc 14  ICEs on this code under every flag combination tried - in
#           gen_enumeration_type_die (dwarf2out.cc) with debug info, and in
#           nothrow_spec_p (cp/except.cc) without it. Modules plus Qt headers of
#           this size is more than its implementation handles.
#
# gcc 15 may well be fine; nothing here could test it. ALLOW_GCC=1 lifts the
# gate for anyone who wants to find out, rather than making that a patch.
ifeq ($(CXX_IS_CLANG),1)
  CXX_MIN := 17
else
  CXX_MIN := 15
  ifneq ($(ALLOW_GCC),1)
    ifneq ($(shell test "$(CXX_MAJOR)" -ge 15 2>/dev/null && echo ok),ok)
      $(error $(CXX) is gcc $(CXX_MAJOR), which cannot compile C++20 modules against Qt - \
        gcc 13 segfaults and gcc 14 hits an internal compiler error. Use `make CXX=clang++` \
        (clang 17 or newer). ALLOW_GCC=1 tries anyway. Each release also ships a prebuilt \
        binary, if building is not an option.)
    endif
  endif
endif
ifneq ($(shell test "$(CXX_MAJOR)" -ge "$(CXX_MIN)" 2>/dev/null && echo ok),ok)
ifneq ($(ALLOW_GCC),1)
$(error $(CXX) is version $(CXX_MAJOR); this needs clang >= 17. The plugin cannot run \
  without this binary - every Slack call goes through it - so a release build is also \
  attached to each tag.)
endif
endif

# Everything that has ever caught a real bug in this code, plus the conversion
# warnings, which are the ones that matter when the input is attacker-shaped
# bytes and every other line is an index or a shift.
WARNINGS := \
	-Wall -Wextra -Wpedantic \
	-Wshadow -Wconversion -Wsign-conversion -Wold-style-cast \
	-Wcast-qual -Wcast-align -Wdouble-promotion -Wformat=2 \
	-Wimplicit-fallthrough -Wnon-virtual-dtor \
	-Woverloaded-virtual -Wnull-dereference -Wundef -Wunused -Wextra-semi \
	-Wswitch-default -Wredundant-decls -Wwrite-strings

ifeq ($(CXX_IS_CLANG),1)
  # -Wmissing-declarations is clang-only here, not by preference: it exists to
  # catch a function in a .cpp that should have been static, and gcc applies it
  # to module interface units too, where every exported definition *is* its
  # declaration. clang understands module linkage and only warns where it means
  # something.
  WARNINGS += -Wloop-analysis -Wrange-loop-analysis -Wunreachable-code -Wmissing-declarations
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

# Qt and the C libraries the agent needs. Discovered with pkg-config rather than
# hardcoded: the Qt include layout differs between distros, and a missing
# development package should say which one by name.
DEP_PACKAGES := Qt6Core Qt6Network libsecret-1 openssl
DEP_MISSING  := $(strip $(foreach p,$(DEP_PACKAGES),$(if $(shell pkg-config --exists $(p) && echo 1),,$(p))))
ifneq ($(DEP_MISSING),)
  ifneq ($(MAKECMDGOALS),help)
    $(warning missing development packages: $(DEP_MISSING))
    $(warning on Debian/Ubuntu: apt install qt6-base-dev libsecret-1-dev libssl-dev)
    $(warning on Arch: pacman -S qt6-base libsecret openssl)
  endif
endif
# -isystem, not -I: Qt's and glib's headers do not compile clean under this
# warning set (old-style casts in glib, sign conversions in qversiontagging),
# and holding somebody else's headers to our -Werror is not a thing that can be
# won. Ours stay strict; theirs are system headers.
DEP_CFLAGS := $(patsubst -I%,-isystem %,$(shell pkg-config --cflags $(DEP_PACKAGES) 2>/dev/null)) -fPIC \
	-DQT_NO_KEYWORDS -DQT_DISABLE_DEPRECATED_UP_TO=0x060400
DEP_LIBS   := $(shell pkg-config --libs $(DEP_PACKAGES) 2>/dev/null)

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
# Our own code is C++20 named modules; Qt and the C libraries come in as
# ordinary includes inside each module's global module fragment, because Qt does
# not ship as modules and will not until it stops supporting header-only use.
#
# native/<name>.cppm declares module slack.<name>, compiles to $(BUILDDIR)/
# <name>.o and produces a binary module interface beside it. A module unit has
# to be built before anything that imports it, and the two compilers spell that
# completely differently:
#
#   clang  --precompile writes a .pcm, which is then compiled to an object like
#          any other TU; importers find it via -fprebuilt-module-path.
#   gcc    compiles the module unit straight to an object and writes a .gcm on
#          the side, placed by a mapper file so binary module interfaces stay
#          out of the source tree. Kept for whenever gcc can compile this again
#          (see the compiler gate above); reachable with ALLOW_GCC=1.
#
# The import graph is written out below rather than scanned for: eight modules
# in a DAG that changes about once a year does not justify clang-scan-deps and
# a two-phase build.
MODULE_NAMES := html util keyring net api store oauth commands
MODULE_SRCS  := $(MODULE_NAMES:%=native/%.cppm)
MODULE_OBJS  := $(MODULE_NAMES:%=$(BUILDDIR)/%.o)

ifeq ($(CXX_IS_CLANG),1)
  BMI_EXT       := pcm
  MODULE_IMPORT  = -fprebuilt-module-path=$(BUILDDIR)
else
  BMI_EXT       := gcm
  MODULE_MAP    := $(BUILDDIR)/modules.map
  MODULE_FLAGS   = -fmodules-ts -fmodule-mapper=$(MODULE_MAP)
  MODULE_IMPORT  = $(MODULE_FLAGS)
endif

MODULE_BMIS := $(MODULE_NAMES:%=$(BUILDDIR)/slack.%.$(BMI_EXT))

AGENT_SRC := native/agent_main.cpp
TEST_SRC  := native/tests/html_meta_test.cpp
FUZZ_SRC  := native/tests/html_meta_fuzz.cpp
CORPUS    := native/tests/corpus

AGENT := $(BUILDDIR)/slack-agent
TEST  := $(BUILDDIR)/html_meta_test
FUZZ  := $(BUILDDIR)/html_meta_fuzz

.PHONY: all test check qml fuzz install uninstall clean help print-config

all: $(AGENT)

ifeq ($(CXX_IS_CLANG),1)

$(BUILDDIR)/slack.%.pcm: native/%.cppm | $(BUILDDIR)
	$(CXX) $(BUILD_CXXFLAGS) $(DEP_CFLAGS) $(MODULE_IMPORT) --precompile -o $@ $<

# No DEP_CFLAGS here: the interface is already compiled, the include paths would
# go unused, and clang makes an unused flag an error once -Werror is on.
$(BUILDDIR)/%.o: $(BUILDDIR)/slack.%.pcm
	$(CXX) $(BUILD_CXXFLAGS) $(MODULE_IMPORT) -c -o $@ $<

else

$(MODULE_MAP): | $(BUILDDIR)
	@for m in $(MODULE_NAMES); do printf 'slack.%s %s/slack.%s.gcm\n' $$m $(BUILDDIR) $$m; done > $@

# gcc emits the .gcm as a side effect of compiling the module unit, so the
# object is the target and the interface comes along with it.
$(BUILDDIR)/%.o: native/%.cppm $(MODULE_MAP) | $(BUILDDIR)
	$(CXX) $(BUILD_CXXFLAGS) $(DEP_CFLAGS) $(MODULE_FLAGS) -x c++ -c -o $@ $<

$(BUILDDIR)/slack.%.gcm: $(BUILDDIR)/%.o ;

endif

# The import graph. Left imports right.
$(BUILDDIR)/slack.net.$(BMI_EXT):      $(BUILDDIR)/slack.util.$(BMI_EXT)
$(BUILDDIR)/slack.api.$(BMI_EXT):      $(BUILDDIR)/slack.util.$(BMI_EXT) $(BUILDDIR)/slack.keyring.$(BMI_EXT) $(BUILDDIR)/slack.net.$(BMI_EXT)
$(BUILDDIR)/slack.store.$(BMI_EXT):    $(BUILDDIR)/slack.util.$(BMI_EXT) $(BUILDDIR)/slack.api.$(BMI_EXT)
$(BUILDDIR)/slack.oauth.$(BMI_EXT):    $(BUILDDIR)/slack.util.$(BMI_EXT) $(BUILDDIR)/slack.keyring.$(BMI_EXT) $(BUILDDIR)/slack.net.$(BMI_EXT)
$(BUILDDIR)/slack.commands.$(BMI_EXT): $(BUILDDIR)/slack.util.$(BMI_EXT) $(BUILDDIR)/slack.keyring.$(BMI_EXT) $(BUILDDIR)/slack.net.$(BMI_EXT) \
                                       $(BUILDDIR)/slack.api.$(BMI_EXT) $(BUILDDIR)/slack.store.$(BMI_EXT) \
                                       $(BUILDDIR)/slack.oauth.$(BMI_EXT) $(BUILDDIR)/slack.html.$(BMI_EXT)

$(BUILDDIR)/agent_main.o: $(AGENT_SRC) $(MODULE_BMIS) | $(BUILDDIR)
	$(CXX) $(BUILD_CXXFLAGS) $(DEP_CFLAGS) $(MODULE_IMPORT) -c -o $@ $<

# DEP_CFLAGS even though the tests need no Qt: a binary module interface records
# the configuration it was built under, and importing a -pthread BMI from a
# compilation without it is rejected as a mismatch.
$(BUILDDIR)/html_meta_test.o: $(TEST_SRC) $(BUILDDIR)/slack.html.$(BMI_EXT) | $(BUILDDIR)
	$(CXX) $(BUILD_CXXFLAGS) $(DEP_CFLAGS) $(MODULE_IMPORT) -c -o $@ $<

$(AGENT): $(MODULE_OBJS) $(BUILDDIR)/agent_main.o
	$(CXX) $(BUILD_CXXFLAGS) -o $@ $^ $(DEP_LIBS) $(BUILD_LDFLAGS)

# The tests cover the pure parser, which imports nothing else and needs none of
# the libraries the agent links.
$(TEST): $(BUILDDIR)/html.o $(BUILDDIR)/html_meta_test.o
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
$(FUZZ): $(FUZZ_SRC) $(BUILDDIR)/slack.html.$(BMI_EXT) $(BUILDDIR)/html.o | $(BUILDDIR)
	@if [ "$(CXX_IS_CLANG)" != "1" ]; then \
	  echo "fuzzing needs clang (libFuzzer); try make fuzz CXX=clang++" >&2; exit 1; \
	fi
	$(CXX) $(BUILD_CXXFLAGS) $(DEP_CFLAGS) $(MODULE_IMPORT) -fsanitize=fuzzer,address,undefined \
	  -o $@ $(FUZZ_SRC) $(BUILDDIR)/html.o

FUZZ_TIME ?= 60

fuzz: $(FUZZ)
	@mkdir -p $(BUILDDIR)/corpus
	$(FUZZ) -max_total_time=$(FUZZ_TIME) -max_len=65536 -print_final_stats=1 \
	  $(BUILDDIR)/corpus $(CORPUS)

install: $(AGENT)
	@mkdir -p $(BINDIR)
	install -m 0755 $(AGENT) $(BINDIR)/slack-agent
	@echo "installed $(BINDIR)/slack-agent"

uninstall:
	rm -f $(BINDIR)/slack-agent

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
