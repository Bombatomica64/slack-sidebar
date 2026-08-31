# Build for the plugin's native helper.
#
# The native side is nine C++20 named modules and four binaries. CMake is here
# for one reason the hand-written Makefile could not give: it scans the module
# graph with clang-scan-deps and records what every binary module interface was
# built with, so a BMI whose flags no longer match is rebuilt rather than
# silently reused. The Makefile's hand-listed import graph and flag-blind .pcm
# rules produced exactly that failure - "POSIX thread support was disabled in
# precompiled file" - whenever a dependency appeared or vanished mid-tree.
#
#   cmake -S . -B build -G Ninja
#   cmake --build build
#   ctest --test-dir build --output-on-failure
#   cmake --build build --target install
#
# `make` still works: the Makefile is now a thin shim over these commands, kept
# because the plugin builds its own helper on first run with a single `make`.
#
# Options (all default OFF):
#   SLACK_STRICT      warnings become errors; CI builds with this, users do not
#   SLACK_SANITIZE    AddressSanitizer + UndefinedBehaviorSanitizer
#   SLACK_COVERAGE    clang source-based coverage instrumentation
#   SLACK_FUZZ        build the libFuzzer parser target (implies sanitizers)
#   SLACK_PORTABLE    static libstdc++/libgcc, for release artifacts
#   SLACK_ALLOW_GCC   lift the clang-only gate and try gcc anyway

cmake_minimum_required(VERSION 3.28)

project(slack-agent
  VERSION 1.0.0
  DESCRIPTION "Slack helper for the Noctalia sidebar plugin"
  LANGUAGES CXX)

# Module dependency scanning is a Ninja feature. Make and the IDE generators
# cannot express the dynamic dependencies a module graph needs, and CMake's
# diagnostic for that arrives much later and much less clearly than this one.
if(NOT CMAKE_GENERATOR MATCHES "Ninja")
  message(FATAL_ERROR
    "generator is '${CMAKE_GENERATOR}'; C++20 modules need Ninja.\n"
    "  cmake -S . -B build -G Ninja")
endif()

# ---------------------------------------------------------------- compiler
#
# Our own code is C++20 named modules, with Qt included in each module's global
# module fragment. That combination builds on clang and on no other compiler,
# and the reason changed as the measurements came in:
#
#   gcc 13  segfaults compiling a four-line program that imports a module and
#           uses std::string at -O2. Still the default on Ubuntu 24.04 LTS.
#   gcc 14  ICEs on this code with and without debug info -
#           gen_enumeration_type_die (dwarf2out.cc), nothrow_spec_p (cp/except.cc).
#   gcc 15  fails; 15.3.0 against Qt 6.8.2, measured in CI.
#   gcc 16  does not crash. It *diagnoses*, and it is right to:
#
#             qbytearrayalgorithms.h:80: error: 'QtPrivate::toIntegral<...>'
#             exposes TU-local entity '...::<lambda()>'
#
# That is [basic.link]/17: a module interface may not expose a TU-local entity,
# and a lambda in the global module fragment is one. Qt's headers are full of
# them. So the honest statement is not "gcc cannot compile modules" - it is that
# putting Qt in a module's global module fragment is ill-formed, gcc 16 is the
# first compiler to enforce it, and clang has no such check at all (verified:
# clang 18 accepts a minimal repro silently and has no flag to turn it on).
#
# This build therefore rests on clang's leniency rather than on being correct.
# The fix, if it is ever wanted, is to keep Qt out of module interface units
# entirely - which means the Qt-facing code stops being modules. Until then the
# probe job watches, and SLACK_ALLOW_GCC=ON lifts the gate for anyone who wants
# to retry gcc themselves.
option(SLACK_ALLOW_GCC "Try gcc even though it cannot build modules against Qt" OFF)

set(SLACK_IS_CLANG $<BOOL:0>)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  set(SLACK_CLANG ON)
  set(SLACK_CXX_MIN 17)
else()
  set(SLACK_CLANG OFF)
  set(SLACK_CXX_MIN 15)
endif()

if(NOT SLACK_ALLOW_GCC AND NOT SLACK_CLANG)
  message(FATAL_ERROR
    "${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION} cannot compile C++20 "
    "modules against Qt - gcc 13 and 14 crash, 16 correctly rejects Qt's headers "
    "for exposing TU-local entities from a module interface.\n"
    "  cmake -S . -B build -G Ninja -DCMAKE_CXX_COMPILER=clang++   (clang 17 or newer)\n"
    "-DSLACK_ALLOW_GCC=ON tries anyway. Each release also ships a prebuilt binary, "
    "if building is not an option.")
endif()

if(NOT SLACK_ALLOW_GCC AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS SLACK_CXX_MIN)
  message(FATAL_ERROR
    "${CMAKE_CXX_COMPILER} is version ${CMAKE_CXX_COMPILER_VERSION}; this needs "
    "clang >= ${SLACK_CXX_MIN}. The plugin cannot run without this binary - every "
    "Slack call goes through it - so a release build is also attached to each tag.")
endif()

# The source targets C++26. Older toolchains still build it, so probe downwards
# rather than refusing to run on a distro that shipped last year.
foreach(std 26 23 20)
  if("cxx_std_${std}" IN_LIST CMAKE_CXX_COMPILE_FEATURES)
    set(SLACK_STD ${std})
    break()
  endif()
endforeach()
if(NOT SLACK_STD)
  message(FATAL_ERROR
    "${CMAKE_CXX_COMPILER} accepts none of C++26/23/20 - too old to build this")
endif()

set(CMAKE_CXX_STANDARD ${SLACK_STD})
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  # -O2 with debug info, which is what the Makefile always built: the agent runs
  # on a keystroke and a backtrace from a user is worth its size on disk.
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

# ---------------------------------------------------------------- dependencies
#
# Found one package at a time on purpose. The Makefile asked pkg-config for all
# five at once, so a single missing package silently emptied the whole flag set
# and the build failed several steps later with `'QByteArray' file not found`.
# Here each one names itself, and names the package to install.

find_package(PkgConfig REQUIRED)
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

function(slack_missing what debian arch)
  message(FATAL_ERROR
    "missing development package: ${what}\n"
    "  Debian/Ubuntu: apt install ${debian}\n"
    "  Arch:          pacman -S ${arch}")
endfunction()

find_package(Qt6 6.4 QUIET COMPONENTS Core Network)
if(NOT Qt6_FOUND)
  slack_missing("Qt 6 Core and Network" "qt6-base-dev" "qt6-base")
endif()

find_package(OpenSSL QUIET)
if(NOT OpenSSL_FOUND)
  slack_missing("OpenSSL" "libssl-dev" "openssl")
endif()

pkg_check_modules(SECRET QUIET IMPORTED_TARGET libsecret-1)
if(NOT SECRET_FOUND)
  slack_missing("libsecret" "libsecret-1-dev" "libsecret")
endif()

pkg_check_modules(SQLCIPHER QUIET IMPORTED_TARGET sqlcipher)
if(NOT SQLCIPHER_FOUND)
  slack_missing("SQLCipher" "libsqlcipher-dev" "sqlcipher")
endif()

# Imported targets carry their include directories as SYSTEM, which is the whole
# point: Qt's and glib's headers do not compile clean under the warning set
# below (old-style casts in glib, sign conversions in qversiontagging), and
# holding somebody else's headers to our -Werror is not a thing that can be won.
# Ours stay strict; theirs are system headers.

# ---------------------------------------------------------------- build flags
#
# One INTERFACE target, linked PUBLIC by everything. That is not tidiness: a
# binary module interface records the configuration it was compiled under, and a
# consumer compiled with a different one is rejected outright. Propagating the
# flags through the link graph is what keeps producer and consumer identical.

option(SLACK_STRICT   "Turn warnings into errors" OFF)
option(SLACK_SANITIZE "Build with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)
option(SLACK_COVERAGE "Build with clang source-based coverage instrumentation" OFF)
option(SLACK_FUZZ     "Build the libFuzzer target for the HTML parser" OFF)
option(SLACK_PORTABLE "Link libstdc++/libgcc statically, for release artifacts" OFF)

add_library(slack_flags INTERFACE)

# Everything that has ever caught a real bug in this code, plus the conversion
# warnings, which are the ones that matter when the input is attacker-shaped
# bytes and every other line is an index or a shift.
target_compile_options(slack_flags INTERFACE
  -Wall -Wextra -Wpedantic
  -Wshadow -Wconversion -Wsign-conversion -Wold-style-cast
  -Wcast-qual -Wcast-align -Wdouble-promotion -Wformat=2
  -Wimplicit-fallthrough -Wnon-virtual-dtor
  -Woverloaded-virtual -Wnull-dereference -Wundef -Wunused -Wextra-semi
  -Wswitch-default -Wredundant-decls -Wwrite-strings)

if(SLACK_CLANG)
  # -Wmissing-declarations is clang-only here, not by preference: it exists to
  # catch a function in a .cpp that should have been static, and gcc applies it
  # to module interface units too, where every exported definition *is* its
  # declaration. clang understands module linkage and only warns where it means
  # something.
  target_compile_options(slack_flags INTERFACE
    -Wloop-analysis -Wrange-loop-analysis -Wunreachable-code -Wmissing-declarations)
else()
  target_compile_options(slack_flags INTERFACE
    -Wduplicated-cond -Wduplicated-branches -Wlogical-op -Wuseless-cast)
endif()

# -Werror is a CI gate, not a user-facing one: a compiler newer than this commit
# will eventually invent a warning, and that must not be the thing that stops
# someone's link previews from building on first use.
if(SLACK_STRICT)
  target_compile_options(slack_flags INTERFACE -Werror)
endif()

# _GLIBCXX_ASSERTIONS turns container preconditions into aborts, and
# _FORTIFY_SOURCE catches the obvious overflows; both are cheap here.
target_compile_options(slack_flags INTERFACE
  -fstack-protector-strong -fno-delete-null-pointer-checks)
target_compile_definitions(slack_flags INTERFACE
  _GLIBCXX_ASSERTIONS _FORTIFY_SOURCE=2
  QT_NO_KEYWORDS QT_DISABLE_DEPRECATED_UP_TO=0x060400)

# -pthread on every target, not only the Qt-facing ones, and spelled out rather
# than left to Threads::Threads: on glibc that target contributes no compile
# option at all, while glib's pkg-config cflags contribute -pthread to whatever
# links libsecret. A BMI built without thread support cannot be imported by a
# translation unit that has it - clang says "POSIX thread support was disabled
# in precompiled file ... but is currently enabled" and then fails to find every
# name in the module. The parser needs no threads; it needs to have been
# compiled the same way as the code that imports it.
target_compile_options(slack_flags INTERFACE -pthread)
target_link_libraries(slack_flags INTERFACE Threads::Threads)

# The sanitized pass is clang-only, and not by preference: gcc 14 hits an
# internal compiler error (cp/module.cc:9455) compiling a module unit with
# -fsanitize at all. Some distros also ship clang without its sanitizer runtime,
# where the failure surfaces as a linker error about libclang_rt several steps
# later, so probe for the runtime rather than for the compiler alone.
include(CheckCXXSourceCompiles)
if(SLACK_CLANG)
  set(CMAKE_REQUIRED_FLAGS "-fsanitize=address,undefined")
  set(CMAKE_REQUIRED_LINK_OPTIONS "-fsanitize=address,undefined")
  check_cxx_source_compiles("int main(){}" SLACK_CAN_SANITIZE)
  unset(CMAKE_REQUIRED_FLAGS)
  unset(CMAKE_REQUIRED_LINK_OPTIONS)
  set(SLACK_SAN_UNAVAILABLE
    "${CMAKE_CXX_COMPILER} cannot link the sanitizer runtime - install it (libclang-rt-*-dev)")
else()
  set(SLACK_CAN_SANITIZE OFF)
  set(SLACK_SAN_UNAVAILABLE
    "${CMAKE_CXX_COMPILER} is gcc, which ICEs compiling a module with -fsanitize")
endif()

if(SLACK_SANITIZE OR SLACK_FUZZ)
  if(NOT SLACK_CAN_SANITIZE)
    message(FATAL_ERROR "${SLACK_SAN_UNAVAILABLE}")
  endif()
  target_compile_options(slack_flags INTERFACE
    -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all)
  target_link_options(slack_flags INTERFACE
    -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all)
endif()

# Coverage, through clang's source-based instrumentation. Same clang-only story
# as the sanitizers, for the same reason: gcc cannot build this at all.
if(SLACK_COVERAGE)
  if(NOT SLACK_CLANG)
    message(FATAL_ERROR "coverage needs clang; configure with -DCMAKE_CXX_COMPILER=clang++")
  endif()
  target_compile_options(slack_flags INTERFACE -fprofile-instr-generate -fcoverage-mapping)
  target_link_options(slack_flags INTERFACE -fprofile-instr-generate -fcoverage-mapping)
endif()

if(SLACK_PORTABLE)
  # A release binary has to run against whatever libstdc++ the user's distro
  # shipped, which may well be older than the one that built it.
  target_link_options(slack_flags INTERFACE -static-libstdc++ -static-libgcc)
endif()

# ---------------------------------------------------------------- modules
#
# Two libraries rather than one, because the parser genuinely stands alone: it
# imports nothing, links nothing, and its tests and its fuzzer should not have
# to drag Qt, libsecret and OpenSSL in behind them.
#
# The import graph between the modules themselves is *not* written down here.
# CMake scans the sources for `import` and orders the build from what it finds,
# which is the other half of why this file exists: the Makefile's hand-listed
# graph was a copy of the truth that had to be maintained by hand.

add_library(slack_html STATIC)
target_sources(slack_html
  PUBLIC FILE_SET CXX_MODULES FILES
    native/html.cppm)
target_link_libraries(slack_html PUBLIC slack_flags)

add_library(slack_core STATIC)
target_sources(slack_core
  PUBLIC FILE_SET CXX_MODULES FILES
    native/util.cppm
    native/keyring.cppm
    native/net.cppm
    native/api.cppm
    native/store.cppm
    native/archive.cppm
    native/oauth.cppm
    native/commands.cppm)
target_link_libraries(slack_core PUBLIC
  slack_flags
  slack_html
  Qt6::Core
  Qt6::Network
  OpenSSL::SSL
  OpenSSL::Crypto
  PkgConfig::SECRET
  PkgConfig::SQLCIPHER)

# ---------------------------------------------------------------- binaries

add_executable(slack-agent native/agent_main.cpp)
target_link_libraries(slack-agent PRIVATE slack_core)

# The parser tests link only the parser: it imports nothing else and needs none
# of the libraries the agent does.
add_executable(html_meta_test native/tests/html_meta_test.cpp)
target_link_libraries(html_meta_test PRIVATE slack_html)

# The agent tests cover the pure logic - the address guard above all - so they
# link every module and the libraries with it.
add_executable(agent_test native/tests/agent_test.cpp)
target_link_libraries(agent_test PRIVATE slack_core)

include(CTest)
add_test(NAME parser COMMAND html_meta_test)
add_test(NAME agent COMMAND agent_test)

# libFuzzer, which is clang-only. Sixty seconds of this on every CI run is worth
# more than any number of hand-written malformed-input cases, because the parser
# reads bytes chosen by whoever owns the page behind a pasted link.
#
# Configured as its own build dir rather than as an extra target in the normal
# one, because -fsanitize=fuzzer has to reach the parser as well as the harness.
# The Makefile linked an *uninstrumented* html.o into an instrumented main, so
# ASan saw nothing the parser did; here the whole binary is instrumented.
if(SLACK_FUZZ)
  add_executable(html_meta_fuzz native/tests/html_meta_fuzz.cpp)
  target_link_libraries(html_meta_fuzz PRIVATE slack_html)
  target_compile_options(html_meta_fuzz PRIVATE -fsanitize=fuzzer)
  target_link_options(html_meta_fuzz PRIVATE -fsanitize=fuzzer)

  set(SLACK_FUZZ_TIME 60 CACHE STRING "Seconds to fuzz for")
  # Crashing inputs are written to the working directory, and CI collects them
  # from the checkout root.
  add_custom_target(fuzz
    COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_BINARY_DIR}/corpus
    COMMAND $<TARGET_FILE:html_meta_fuzz>
            -max_total_time=${SLACK_FUZZ_TIME} -max_len=65536 -print_final_stats=1
            ${CMAKE_BINARY_DIR}/corpus ${CMAKE_CURRENT_SOURCE_DIR}/native/tests/corpus
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    DEPENDS html_meta_fuzz
    USES_TERMINAL
    VERBATIM)
endif()

# What is tested, and - more usefully - what is not.
if(SLACK_COVERAGE)
  set(SLACK_COVERAGE_FLOOR 25 CACHE STRING "Line coverage below this counts as untested")
  find_program(LLVM_PROFDATA NAMES llvm-profdata llvm-profdata-${CMAKE_CXX_COMPILER_VERSION})
  find_program(LLVM_COV      NAMES llvm-cov      llvm-cov-${CMAKE_CXX_COMPILER_VERSION})
  if(NOT LLVM_PROFDATA OR NOT LLVM_COV)
    message(FATAL_ERROR "llvm-profdata/llvm-cov not found (install llvm)")
  endif()
  add_custom_target(coverage
    COMMAND ${CMAKE_COMMAND} -E env
            LLVM_PROFDATA=${LLVM_PROFDATA}
            LLVM_COV=${LLVM_COV}
            COVERAGE_FLOOR=${SLACK_COVERAGE_FLOOR}
            ${CMAKE_CURRENT_SOURCE_DIR}/cmake/coverage.sh
            ${CMAKE_BINARY_DIR}
            $<TARGET_FILE:html_meta_test>
            $<TARGET_FILE:agent_test>
    DEPENDS html_meta_test agent_test
    USES_TERMINAL
    VERBATIM)
endif()

# ---------------------------------------------------------------- install
#
# Into the plugin's own cache directory by default: a plugin directory is
# somebody's checkout, not a build tree, and the QML side looks for the binary
# here.
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  if(DEFINED ENV{XDG_CACHE_HOME})
    set(CMAKE_INSTALL_PREFIX "$ENV{XDG_CACHE_HOME}/noctalia-slack" CACHE PATH "" FORCE)
  else()
    set(CMAKE_INSTALL_PREFIX "$ENV{HOME}/.cache/noctalia-slack" CACHE PATH "" FORCE)
  endif()
endif()

install(TARGETS slack-agent RUNTIME DESTINATION bin)

message(STATUS "compiler   ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION} (modules need clang >= ${SLACK_CXX_MIN})")
message(STATUS "standard   C++${SLACK_STD}")
message(STATUS "strict     ${SLACK_STRICT}   sanitize ${SLACK_SANITIZE}   coverage ${SLACK_COVERAGE}   portable ${SLACK_PORTABLE}")
message(STATUS "sanitizers ${SLACK_CAN_SANITIZE}")
message(STATUS "install to ${CMAKE_INSTALL_PREFIX}/bin")
