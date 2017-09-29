# The CompilerRT build system requires CMake version 2.8.8 or higher in order
# to use its support for building convenience "libraries" as a collection of
# .o files. This is particularly useful in producing larger, more complex
# runtime libraries.

include(CheckIncludeFile)
include(CheckCXXSourceCompiles)

check_include_file(unwind.h HAVE_UNWIND_H)

# Top level target used to build all compiler-rt libraries.
add_custom_target(compiler-rt ALL)
add_custom_target(install-compiler-rt)
set_target_properties(compiler-rt PROPERTIES FOLDER "Compiler-RT Misc")

# Setting these variables from an LLVM build is sufficient that compiler-rt can
# construct the output paths, so it can behave as if it were in-tree here.
if (LLVM_LIBRARY_OUTPUT_INTDIR AND LLVM_RUNTIME_OUTPUT_INTDIR AND PACKAGE_VERSION)
  set(LLVM_TREE_AVAILABLE On)
endif()

if (LLVM_TREE_AVAILABLE)
  # Compute the Clang version from the LLVM version.
  # FIXME: We should be able to reuse CLANG_VERSION variable calculated
  #        in Clang cmake files, instead of copying the rules here.
  string(REGEX MATCH "[0-9]+\\.[0-9]+(\\.[0-9]+)?" CLANG_VERSION
         ${PACKAGE_VERSION})
  # Setup the paths where compiler-rt runtimes and headers should be stored.
  set(COMPILER_RT_OUTPUT_DIR ${LLVM_LIBRARY_OUTPUT_INTDIR}/clang/${CLANG_VERSION})
  set(COMPILER_RT_EXEC_OUTPUT_DIR ${LLVM_RUNTIME_OUTPUT_INTDIR})
  set(COMPILER_RT_INSTALL_PATH lib${LLVM_LIBDIR_SUFFIX}/clang/${CLANG_VERSION})
  option(COMPILER_RT_INCLUDE_TESTS "Generate and build compiler-rt unit tests."
         ${LLVM_INCLUDE_TESTS})
  option(COMPILER_RT_ENABLE_WERROR "Fail and stop if warning is triggered"
         ${LLVM_ENABLE_WERROR})
  # Use just-built Clang to compile/link tests on all platforms, except for
  # Windows where we need to use clang-cl instead.
  if(NOT MSVC)
    set(COMPILER_RT_TEST_COMPILER ${LLVM_RUNTIME_OUTPUT_INTDIR}/clang)
    set(COMPILER_RT_TEST_CXX_COMPILER ${LLVM_RUNTIME_OUTPUT_INTDIR}/clang++)
  else()
    set(COMPILER_RT_TEST_COMPILER ${LLVM_RUNTIME_OUTPUT_INTDIR}/clang.exe)
    set(COMPILER_RT_TEST_CXX_COMPILER ${LLVM_RUNTIME_OUTPUT_INTDIR}/clang++.exe)
  endif()
else()
    # Take output dir and install path from the user.
  set(COMPILER_RT_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR} CACHE PATH
    "Path where built compiler-rt libraries should be stored.")
  set(COMPILER_RT_EXEC_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/bin CACHE PATH
    "Path where built compiler-rt executables should be stored.")
  set(COMPILER_RT_INSTALL_PATH ${CMAKE_INSTALL_PREFIX} CACHE PATH
    "Path where built compiler-rt libraries should be installed.")
  option(COMPILER_RT_INCLUDE_TESTS "Generate and build compiler-rt unit tests." OFF)
  option(COMPILER_RT_ENABLE_WERROR "Fail and stop if warning is triggered" OFF)
  # Use a host compiler to compile/link tests.
  set(COMPILER_RT_TEST_COMPILER ${CMAKE_C_COMPILER} CACHE PATH "Compiler to use for testing")
  set(COMPILER_RT_TEST_CXX_COMPILER ${CMAKE_CXX_COMPILER} CACHE PATH "C++ Compiler to use for testing")
endif()

if("${COMPILER_RT_TEST_COMPILER}" MATCHES "clang[+]*$")
  set(COMPILER_RT_TEST_COMPILER_ID Clang)
elseif("${COMPILER_RT_TEST_COMPILER}" MATCHES "clang.*.exe$")
  set(COMPILER_RT_TEST_COMPILER_ID Clang)
else()
  set(COMPILER_RT_TEST_COMPILER_ID GNU)
endif()

if(NOT DEFINED COMPILER_RT_OS_DIR)
  string(TOLOWER ${CMAKE_SYSTEM_NAME} COMPILER_RT_OS_DIR)
endif()
set(COMPILER_RT_LIBRARY_OUTPUT_DIR
  ${COMPILER_RT_OUTPUT_DIR}/lib/${COMPILER_RT_OS_DIR})
set(COMPILER_RT_LIBRARY_INSTALL_DIR
  ${COMPILER_RT_INSTALL_PATH}/lib/${COMPILER_RT_OS_DIR})

if(APPLE)
  # On Darwin if /usr/include doesn't exist, the user probably has Xcode but not
  # the command line tools. If this is the case, we need to find the OS X
  # sysroot to pass to clang.
  if(NOT EXISTS /usr/include)
    execute_process(COMMAND xcodebuild -version -sdk macosx Path
       OUTPUT_VARIABLE OSX_SYSROOT
       ERROR_QUIET
       OUTPUT_STRIP_TRAILING_WHITESPACE)
    set(OSX_SYSROOT_FLAG "-isysroot${OSX_SYSROOT}")
  endif()

  option(COMPILER_RT_ENABLE_IOS "Enable building for iOS" On)
  option(COMPILER_RT_ENABLE_WATCHOS "Enable building for watchOS - Experimental" Off)
  option(COMPILER_RT_ENABLE_TVOS "Enable building for tvOS - Experimental" Off)

else()
  option(COMPILER_RT_DEFAULT_TARGET_ONLY "Build builtins only for the default target" Off)
endif()

if(WIN32 AND NOT MINGW AND NOT CYGWIN)
  set(CMAKE_SHARED_LIBRARY_PREFIX_C "")
  set(CMAKE_SHARED_LIBRARY_PREFIX_CXX "")
  set(CMAKE_STATIC_LIBRARY_PREFIX_C "")
  set(CMAKE_STATIC_LIBRARY_PREFIX_CXX "")
  set(CMAKE_STATIC_LIBRARY_SUFFIX_C ".lib")
  set(CMAKE_STATIC_LIBRARY_SUFFIX_CXX ".lib")
endif()

macro(test_targets)
  # Find and run MSVC (not clang-cl) and get its version. This will tell clang-cl
  # what version of MSVC to pretend to be so that the STL works.
  set(MSVC_VERSION_FLAG "")
  if (MSVC)
    # Find and run MSVC (not clang-cl) and get its version. This will tell
    # clang-cl what version of MSVC to pretend to be so that the STL works.
    execute_process(COMMAND "$ENV{VSINSTALLDIR}/VC/bin/cl.exe"
      OUTPUT_QUIET
      ERROR_VARIABLE MSVC_COMPAT_VERSION
      )
    string(REGEX REPLACE "^.*Compiler Version ([0-9.]+) for .*$" "\\1"
      MSVC_COMPAT_VERSION "${MSVC_COMPAT_VERSION}")
    if (MSVC_COMPAT_VERSION MATCHES "^[0-9].+$")
      set(MSVC_VERSION_FLAG "-fms-compatibility-version=${MSVC_COMPAT_VERSION}")
      # Add this flag into the host build if this is clang-cl.
      if (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        append("${MSVC_VERSION_FLAG}" CMAKE_C_FLAGS CMAKE_CXX_FLAGS)
      elseif (COMPILER_RT_TEST_COMPILER_ID MATCHES "Clang")
        # Add this flag to test compiles to suppress clang's auto-detection
        # logic.
        append("${MSVC_VERSION_FLAG}" COMPILER_RT_TEST_COMPILER_CFLAGS)
      endif()
    endif()
  endif()

  # Generate the COMPILER_RT_SUPPORTED_ARCH list.
  if(ANDROID)
    # Examine compiler output to determine target architecture.
    detect_target_arch()
    set(COMPILER_RT_OS_SUFFIX "-android")
  elseif(NOT APPLE) # Supported archs for Apple platforms are generated later
    if(COMPILER_RT_DEFAULT_TARGET_ONLY)
      add_default_target_arch(${COMPILER_RT_DEFAULT_TARGET_ARCH})
    elseif("${COMPILER_RT_DEFAULT_TARGET_ARCH}" MATCHES "i[2-6]86|x86|amd64")
      if(NOT MSVC)
        test_target_arch(x86_64 "" "-m64")
        test_target_arch(i386 __i386__ "-m32")
      else()
        if (CMAKE_SIZEOF_VOID_P EQUAL 4)
          test_target_arch(i386 "" "")
        else()
          test_target_arch(x86_64 "" "")
        endif()
      endif()
    elseif("${COMPILER_RT_DEFAULT_TARGET_ARCH}" MATCHES "powerpc")
      # Strip out -nodefaultlibs when calling TEST_BIG_ENDIAN. Configuration
      # will fail with this option when building with a sanitizer.
      cmake_push_check_state()
      string(REPLACE "-nodefaultlibs" "" CMAKE_REQUIRED_FLAGS ${OLD_CMAKE_REQUIRED_FLAGS})
      TEST_BIG_ENDIAN(HOST_IS_BIG_ENDIAN)
      cmake_pop_check_state()

      if(HOST_IS_BIG_ENDIAN)
        test_target_arch(powerpc64 "" "-m64")
      else()
        test_target_arch(powerpc64le "" "-m64")
      endif()
    elseif("${COMPILER_RT_DEFAULT_TARGET_ARCH}" MATCHES "s390x")
      test_target_arch(s390x "" "")
    elseif("${COMPILER_RT_DEFAULT_TARGET_ARCH}" MATCHES "mipsel|mips64el")
      # Gcc doesn't accept -m32/-m64 so we do the next best thing and use
      # -mips32r2/-mips64r2. We don't use -mips1/-mips3 because we want to match
      # clang's default CPU's. In the 64-bit case, we must also specify the ABI
      # since the default ABI differs between gcc and clang.
      # FIXME: Ideally, we would build the N32 library too.
      test_target_arch(mipsel "" "-mips32r2" "--target=mipsel-linux-gnu")
      test_target_arch(mips64el "" "-mips64r2" "--target=mips64el-linux-gnu" "-mabi=64")
    elseif("${COMPILER_RT_DEFAULT_TARGET_ARCH}" MATCHES "mips")
      test_target_arch(mips "" "-mips32r2" "--target=mips-linux-gnu")
      test_target_arch(mips64 "" "-mips64r2" "--target=mips64-linux-gnu" "-mabi=64")
    elseif("${COMPILER_RT_DEFAULT_TARGET_ARCH}" MATCHES "arm")
      if(WIN32)
        test_target_arch(arm "" "" "")
      else()
        test_target_arch(arm "" "-march=armv7-a" "-mfloat-abi=soft")
        test_target_arch(armhf "" "-march=armv7-a" "-mfloat-abi=hard")
        test_target_arch(armv6m "" "-march=armv6m" "-mfloat-abi=soft")
      endif()
    elseif("${COMPILER_RT_DEFAULT_TARGET_ARCH}" MATCHES "aarch32")
      test_target_arch(aarch32 "" "-march=armv8-a")
    elseif("${COMPILER_RT_DEFAULT_TARGET_ARCH}" MATCHES "aarch64")
      test_target_arch(aarch64 "" "-march=armv8-a")
    elseif("${COMPILER_RT_DEFAULT_TARGET_ARCH}" MATCHES "wasm32")
      test_target_arch(wasm32 "" "--target=wasm32-unknown-unknown")
    elseif("${COMPILER_RT_DEFAULT_TARGET_ARCH}" MATCHES "wasm64")
      test_target_arch(wasm64 "" "--target=wasm64-unknown-unknown")
    endif()
    set(COMPILER_RT_OS_SUFFIX "")
  endif()
endmacro()
