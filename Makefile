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

CXXFLAGS ?= -O2
CXXFLAGS += -std=$(STD) $(WARNINGS) $(HARDENING) -g
LDFLAGS  ?=

SAN := -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all

# Some distros ship a clang without its sanitizer runtime, and the failure comes
# out as a linker error about libclang_rt several steps later. Probe once.
CAN_SANITIZE := $(shell printf 'int main(){}' | $(CXX) -x c++ $(SAN) -o /dev/null - >/dev/null 2>&1 && echo 1)

ifeq ($(SANITIZE),1)
  ifneq ($(CAN_SANITIZE),1)
    $(error $(CXX) cannot link the sanitizer runtime - install it, or build the sanitized pass with another compiler)
  endif
  CXXFLAGS += $(SAN)
  LDFLAGS  += $(SAN)
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
  LDFLAGS += -static-libstdc++ -static-libgcc
endif

LIB_SRC     := native/html_meta.cpp
UNFURL_SRC  := $(LIB_SRC) native/unfurl_main.cpp
TEST_SRC    := $(LIB_SRC) native/tests/html_meta_test.cpp
HEADERS     := native/html_meta.hpp

UNFURL := $(BUILDDIR)/slack-unfurl
TEST   := $(BUILDDIR)/html_meta_test

.PHONY: all test check qml install uninstall clean help print-config

all: $(UNFURL)

# Two translation units. Linking them in one invocation keeps the rules short
# and makes a stale object file impossible.
$(UNFURL): $(UNFURL_SRC) $(HEADERS) | $(BUILDDIR)
	$(CXX) $(CXXFLAGS) -o $@ $(UNFURL_SRC) $(LDFLAGS)

$(TEST): $(TEST_SRC) $(HEADERS) | $(BUILDDIR)
	$(CXX) $(CXXFLAGS) -o $@ $(TEST_SRC) $(LDFLAGS)

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
	@echo "skipped: $(CXX) has no sanitizer runtime here (CI runs this pass separately)"
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
	@echo "STRICT   = $(if $(filter 1,$(STRICT)),on,off)"
	@echo "SANITIZE = $(if $(filter 1,$(SANITIZE)),on,off)"
	@echo "BINDIR   = $(BINDIR)"
	@echo "SANITIZERS AVAILABLE = $(if $(filter 1,$(CAN_SANITIZE)),yes,no)"

help:
	@sed -n '1,20p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \{0,1\}//'
