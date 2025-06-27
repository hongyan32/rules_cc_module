# C++ Module Rules Project Architecture

## Project Structure

```
rules_cc_module/
├── MODULE.bazel                    # Bazel module definition
├── BUILD.bazel                     # Root BUILD file
├── ARCHITECTURE.md                 # Project architecture documentation (this file)
├── USAGE.md                        # Usage documentation
├── README.md                       # Main project documentation
├── cc_module/                      # Core rule implementation
│   ├── BUILD.bazel                 # cc_module package BUILD file
│   ├── defs.bzl                    # Main export file
│   ├── providers.bzl               # Provider definitions
│   ├── cc_module_rules.bzl         # Core rule implementation (unified file)
│   └── cc_helper.bzl               # Utility functions and helpers
├── test/                           # Test examples
│   ├── BUILD.bazel                 # Test BUILD file
│   ├── math_module.ixx             # Module interface example
│   ├── math_impl.cpp               # Module implementation example
│   ├── math_common.h               # Common header file
│   └── main.cpp                    # Main program example
└── examples/                       # Complete examples
    └── hello-module/               # Fully featured example project
        ├── README.md               # Example usage instructions
        ├── .bazelrc                # Bazel configuration
        ├── BUILD                   # Platform definitions
        ├── MODULE.bazel            # Module dependencies
        └── src/                    # Source code
            ├── BUILD               # Build rules
            ├── main.cpp            # Main program
            ├── std.ixx             # Standard library module
            ├── std.compat.ixx      # Compatibility module
            ├── module1/            # Simple module
            ├── module2/            # Partitioned module
            └── module3/            # Dependent module
```

## Implemented Features

### 1. Core Rule Definitions
- ✅ **cc_module_library**: For compiling C++ module libraries
- ✅ **cc_module_binary**: For compiling executables that use C++ modules

### 2. Provider System
- ✅ **CcModuleInfo**: Passes module information (interface files, implementation files, BMI files, etc.)
- ✅ **CcModuleBinaryInfo**: Passes binary information

### 3. File Type Support
- ✅ Module interface files: `.ixx`, `.cppm`, `.mpp`
- ✅ Module implementation files: `.cpp`
- ✅ Traditional header files: `.h`, `.hpp`, `.hxx`, `.hh`

### 4. Dependency Management
- ✅ Inter-module dependency handling
- ✅ Transitive dependency collection
- ✅ Compatibility with traditional cc_library

### 5. Compilation Attribute Support
- ✅ `srcs`: Source file list
- ✅ `hdrs`: Header file list
- ✅ `deps`: Dependencies
- ✅ `includes`: Include directories
- ✅ `defines`: Preprocessor definitions
- ✅ `copts`: Compiler options
- ✅ `linkopts`: Linker options (binary files only)

## Current Status

### Fully Implemented Features
1. ✅ Bazel rule syntax is correct with no syntax errors
2. ✅ Targets can be successfully parsed and analyzed
3. ✅ Provider system works correctly
4. ✅ Dependencies are properly propagated
5. ✅ File type recognition works correctly
6. ✅ **Real compilation logic**: Calls actual compilers to generate module files
7. ✅ **BMI/IFC file generation**: Successfully generates binary module interface files
8. ✅ **Module dependency sorting**: Correctly sorts compilation by dependencies (partitions first)
9. ✅ **Multi-compiler support**: Supports MSVC (cl.exe) and clang-cl
10. ✅ **Linking logic**: Generates runnable executable files
11. ✅ **Module partition support**: Correctly handles compilation order for module partitions
12. 🚧 **Cross-platform flag adaptation**: Automatically adapts command-line flags for different compilers (Windows tested, Linux/macOS designed but untested)

### Core Compilation Features
- ✅ **Module interface compilation**: Generates .ifc/.pcm files
- ✅ **Module implementation compilation**: Compiles .cpp implementation files  
- ✅ **Module dependency management**: Automatically handles `/reference` and `-fmodule-file` flags
- ✅ **Toolchain integration**: Fully integrated with Bazel C++ toolchain
- ✅ **Feature flag support**: Correctly applies all compiler features and optimization options

### Cross-Platform Status
- ✅ **Windows (MSVC/clang-cl)**: Fully tested and working
- 🚧 **Linux/macOS (GCC/Clang)**: Implementation complete but requires testing

The rules include comprehensive support for GCC and Clang with appropriate module compilation flags and logic, but this functionality hasn't been validated on actual Linux/macOS systems yet.

## Testing and Validation

Run the following commands to verify the framework's complete functionality:

```bash
# Query all test targets
bazel query //test:all

# Build module library
bazel build //test:math_module

# Build binary file  
bazel build //test:calculator

# Run binary file
bazel run //test:calculator

# Test hello-module example
cd examples/hello-module
bazel build //src:main
./bazel-bin/src/main.exe  # Outputs module function call results

# Compile with clang-cl (Windows)
bazel build --config=clang_config //src:main
```

## Actual Compilation Process

Current implementation compilation flow:

1. **Module interface compilation**:
   - MSVC: `cl.exe /ifcOutput=module.ifc /c module.ixx`
   - Clang: `clang++ -fmodule-output=module.pcm -x c++-module -c module.ixx`

2. **Module dependency handling**:
   - MSVC: `/reference module=module.ifc`
   - Clang: `-fmodule-file=module=module.pcm`

3. **Partition compilation order**: Automatically detects and prioritizes partition module compilation

4. **Linking stage**: Integrates generated object files and module files into final executable

## Implemented Advanced Features

### 1. Compiler Adaptation
- ✅ **MSVC support**: Complete support for `/ifcOutput`, `/reference`, `/std:c++20` flags
- ✅ **clang-cl support**: Automatically detects and uses `-fmodule-output`, `-fmodule-file` flags
- 🚧 **GCC/Clang support**: Designed but untested support for Linux/macOS
- ✅ **Architecture detection**: Automatically adds `-m64`/`-m32` flags for clang-cl

### 2. Module System Features
- ✅ **Module partitions**: Hyphens in filenames automatically converted to module partitions (`module-part.ixx` → `module:part`)
- ✅ **Compilation order**: Partition modules compiled before main modules
- ✅ **Dependency propagation**: Module dependencies automatically propagated to dependent targets

### 3. Toolchain Integration
- ✅ **Feature configuration**: Fully integrated with Bazel C++ feature configuration system
- ✅ **Compilation variables**: Uses `cc_common.create_compile_variables` for consistency
- ✅ **Command line generation**: Generated through `cc_common.get_memory_inefficient_command_line`

### 4. Build System Integration
- ✅ **Provider system**: Custom `ModuleInfo` and `ModuleCompilationInfo` providers
- ✅ **Dependency collection**: Automatically collects and propagates module dependency information
- ✅ **File types**: Supports `.ixx`, `.cppm`, `.mpp` module interface files

## Current Feature Status Summary

📦 **Production-ready implementation fully available**
- Supports real C++ module compilation
- Generates runnable executable files
- Cross-compiler compatibility (MSVC, clang-cl tested; GCC/Clang designed)
- Complete module partition support
- Compatible with existing Bazel C++ rules

## Future Improvement Directions

1. **Extended compiler support**
   - Validate GCC support (-fmodules-ts)
   - Validate pure Clang support (Linux/macOS)

2. **Feature enhancements**
   - Add unit testing support
   - Improve error diagnostic information
   - Add debug information support

3. **Performance optimization**
   - Parallel module compilation optimization
   - Incremental compilation support
   - Cache optimization

## Usage Examples

```bazel
load("@rules_cc_module//cc_module:defs.bzl", "cc_module_library", "cc_module_binary")

# Simple module library
cc_module_library(
    name = "my_module",
    module_interfaces = ["my_module.ixx"],    # Module interface
    srcs = ["my_module.cpp"],                 # Module implementation
    hdrs = ["my_module.h"],                   # Traditional header files
)

# Partitioned module library
cc_module_library(
    name = "partitioned_module", 
    module_interfaces = [
        "module-part1.ixx",   # Partition: module:part1
        "module-part2.ixx",   # Partition: module:part2
        "module.ixx",         # Main module: module
    ],
    srcs = glob(["*.cpp"]),
)

# Executable file
cc_module_binary(
    name = "my_app",
    srcs = ["main.cpp"],
    deps = [
        ":my_module", 
        ":partitioned_module"
    ],
    copts = ["/std:c++20"],  # MSVC (tested)
    # copts = ["-std=c++20"],  # GCC/Clang (designed but untested)
)
```

## Cross-Platform Support Status

### Windows (Production Ready)
- ✅ **MSVC**: Fully tested and working
- ✅ **clang-cl**: Fully tested and working
- ✅ **Standard library modules**: Working with `std` and `std.compat`

### Linux/macOS (Implementation Complete, Testing Needed)
- 🚧 **GCC**: Code designed with appropriate flags, needs testing
- 🚧 **Clang**: Code designed with appropriate flags, needs testing
- 🚧 **Module file formats**: Uses `.pcm` files for GCC/Clang

The rules are architected to handle cross-platform differences:
- Automatic compiler detection and flag adaptation
- Platform-specific module file extensions (`.ifc` for MSVC, `.pcm` for GCC/Clang)
- Architecture-specific compilation flags

🎉 **Project Status**: Production-ready C++ module Bazel rules for Windows, with Linux/macOS support designed and ready for testing!
