# A shim over CMake, which is the build system of record - see CMakeLists.txt.
#
# It stays because the plugin builds its own helper on first run, with one
# command and no configure step to remember, and because `make check` is what
# CI and everyone's muscle memory reach for. Every target here is a couple of
# cmake invocations; nothing about the build is decided in this file.
#
#   make                 build the helper into build/
#   make test            build and run the unit tests
#   make check           the full CI gate: strict warnings, tests, sanitizers
#   make luau            parse every .luau entry point of the plugin
#   make install         install the agent where the plugin looks for it
#   make clean
#
# Knobs:
#   CXX=g++              compiler (default: clang++ if present, else c++)
#   STRICT=1             turn warnings into errors (CI does; a user build does not)
#   SANITIZE=1           build with AddressSanitizer and UndefinedBehaviorSanitizer
#   PORTABLE=1           link libstdc++/libgcc statically, for release artifacts
#   PREFIX=...           install root (default: the v5 plugin directory, so the
#                        helper lands at <pluginDir>/bin/slack-agent)

# `?=` would lose to make's own built-in default for CXX, which is always set;
# `origin` is how you tell "the user asked for g++" from "make guessed".
ifeq ($(origin CXX),default)
  CXX := $(shell command -v clang++ 2>/dev/null || echo c++)
endif

BUILDDIR ?= build
# Noctalia v5 resolves the helper as `noctalia.pluginDir() .. "/bin/slack-agent"`,
# so the install root is the plugin directory itself and not a private cache dir
# the way it was under v4. Overridable: `make install PREFIX=/somewhere/else`.
PREFIX   ?= $(if $(XDG_DATA_HOME),$(XDG_DATA_HOME),$(HOME)/.local/share)/noctalia/plugins/slack
BINDIR   ?= $(PREFIX)/bin

CMAKE  ?= cmake
CTEST  ?= ctest
SRCDIR := $(dir $(firstword $(MAKEFILE_LIST)))

on = $(if $(filter 1,$1),ON,OFF)

# Passed on every configure rather than only the first: re-running cmake against
# an existing build directory is how a changed knob reaches it.
BUILD_TYPE ?= RelWithDebInfo

CMAKE_CONFIG = -S $(SRCDIR) -G Ninja \
	-DCMAKE_CXX_COMPILER=$(CXX) \
	-DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
	$(if $(OPT),-DCMAKE_CXX_FLAGS=$(OPT)) \
	-DCMAKE_INSTALL_PREFIX=$(PREFIX) \
	-DSLACK_STRICT=$(call on,$(STRICT)) \
	-DSLACK_PORTABLE=$(call on,$(PORTABLE)) \
	-DSLACK_ALLOW_GCC=$(call on,$(ALLOW_GCC)) \
	-DSLACK_SANITIZE=$(call on,$(SANITIZE))

# Same probes as the old hand-written build, kept in the shim because `check`
# has to decide whether to run the sanitized pass before any configure happens.
CXX_IS_CLANG := $(shell $(CXX) --version 2>/dev/null | grep -qi clang && echo 1)
SAN := -fsanitize=address,undefined
ifeq ($(CXX_IS_CLANG),1)
  CAN_SANITIZE := $(shell printf 'int main(){}' | $(CXX) -x c++ $(SAN) -o /dev/null - >/dev/null 2>&1 && echo 1)
  SAN_UNAVAILABLE := $(CXX) cannot link the sanitizer runtime - install it (libclang-rt-*-dev)
else
  CAN_SANITIZE :=
  SAN_UNAVAILABLE := $(CXX) is gcc, which ICEs compiling a module with -fsanitize - use CXX=clang++
endif

# The plugin is Luau since v5. `luau-compile --null` parses and compiles every
# entry point and throws the bytecode away, which is the whole syntax gate the
# old qmlformat pass was: a broken entry point is otherwise only visible as a
# plugin that silently fails to load.
#
# Not luau-analyze: the host injects `noctalia`, `ui`, `panel` and `widget` as
# globals and calls `onOpen`/`update`/`onClick` itself, so an untyped analyze
# pass reports nothing but unknown globals and unused functions.
#
# Deliberately not a CMake target: the CI job that runs it downloads one zip and
# needs no C++ toolchain at all.
LUAU_COMPILE := $(shell command -v luau-compile 2>/dev/null || echo luau-compile)
LUAU_FILES   := $(wildcard *.luau)

FUZZ_TIME      ?= 60
COVERAGE_FLOOR ?= 25

.PHONY: all configure test check luau fuzz coverage install uninstall clean help print-config

all: configure
	@$(CMAKE) --build $(BUILDDIR)

configure:
	@$(CMAKE) -B $(BUILDDIR) $(CMAKE_CONFIG)

test: all
	@$(CMAKE) --build $(BUILDDIR) --target html_meta_test agent_test
	@$(CTEST) --test-dir $(BUILDDIR) --output-on-failure

# What CI runs: the strict build, the tests, and the tests again under the
# sanitizers. The sanitized pass is a separate build directory because it needs
# different flags for the same sources.
check:
	@$(MAKE) --no-print-directory STRICT=1 test
	@echo "--- sanitizers ---"
ifeq ($(CAN_SANITIZE),1)
	@$(MAKE) --no-print-directory STRICT=1 SANITIZE=1 BUILDDIR=$(BUILDDIR)/san test
else
	@echo "skipped: $(SAN_UNAVAILABLE)"
endif
	@$(MAKE) --no-print-directory luau

luau:
	@if ! command -v $(LUAU_COMPILE) >/dev/null 2>&1 && [ ! -x "$(LUAU_COMPILE)" ]; then \
	  echo "skipped: luau-compile not found (get it from the luau-lang/luau releases)"; exit 0; \
	fi; \
	fail=0; \
	for f in $(LUAU_FILES); do \
	  if "$(LUAU_COMPILE)" --null "$$f" >/dev/null; then echo "ok   $$f"; else fail=1; fi; \
	done; \
	exit $$fail

# Its own build directory: -fsanitize=fuzzer has to reach the parser as well as
# the harness, so the whole configuration differs.
#
#   make fuzz FUZZ_TIME=300      longer local run
fuzz:
	@$(CMAKE) -B $(BUILDDIR)/fuzz $(CMAKE_CONFIG) -DSLACK_FUZZ=ON -DSLACK_FUZZ_TIME=$(FUZZ_TIME)
	@$(CMAKE) --build $(BUILDDIR)/fuzz --target fuzz

coverage:
	@$(CMAKE) -B $(BUILDDIR)/cov $(CMAKE_CONFIG) -DSLACK_COVERAGE=ON -DSLACK_COVERAGE_FLOOR=$(COVERAGE_FLOOR)
	@$(CMAKE) --build $(BUILDDIR)/cov --target coverage

install: all
	@$(CMAKE) --install $(BUILDDIR)
	@echo "installed $(BINDIR)/slack-agent"

uninstall:
	rm -f $(BINDIR)/slack-agent

clean:
	rm -rf $(BUILDDIR)

# cmake prints the toolchain it settled on while configuring; this is that
# summary on its own, without building anything.
print-config:
	@$(CMAKE) -B $(BUILDDIR) $(CMAKE_CONFIG) | grep -E '^-- (compiler|standard|strict|sanitizers|install)'
	@echo "-- builddir   $(BUILDDIR)"

help:
	@sed -n '1,21p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \{0,1\}//'
