# rules_cc_module

**Production-ready Bazel rules for C++20 modules on Windows and cross-platform support**

This project provides comprehensive Bazel rules for compiling C++20 modules with support for MSVC, clang-cl, and future GCC/Clang compatibility. Unlike the incomplete official Bazel support, this implementation is fully functional and tested.

## Features

- ✅ **Full C++20 Module Support**: Complete implementation of module interfaces, partitions, and dependencies
- ✅ **Multi-Compiler Support**: MSVC (cl.exe) and clang-cl with automatic flag adaptation
- ✅ **Module Partitions**: Automatic handling of module partitions using filename conventions
- ✅ **Dependency Management**: Automatic module dependency resolution and compilation ordering
- ✅ **Standard Library Modules**: Easy integration with `std` and `std.compat` modules
- 🚧 **Cross-Platform Ready**: Code designed for GCC/Clang support on Linux/macOS (implementation complete, testing needed)
- ✅ **Bazel Integration**: Full integration with Bazel's C++ toolchain and feature system

## Requirements

### Tested Platforms
- **Windows**: Fully tested and supported with MSVC and clang-cl
- **Linux/macOS**: Code designed for compatibility with GCC/Clang, but not yet tested

### Compilers
- **Bazel**: Version 7.0+ (tested with Bazel 8.0)
- **MSVC**: Minimum version 14.30, recommended 14.38+ (Visual Studio 2022 17.8+) ✅ **Tested**
  - MSVC 14.30 (2022 17.0): Supports standard library modules (std.core, std.regex, etc.)
  - MSVC 14.38+ (2022 17.8+): Supports parallel module compilation
- **clang-cl**: For alternative compilation (comes with Visual Studio 2022) ✅ **Tested**
- **GCC/Clang**: Code designed for compatibility 🚧 **Untested**

## Quick Start

### 1. Add Dependency

Add this to your `MODULE.bazel` file:

```starlark
bazel_dep(name = "rules_cc_module", dev_dependency = True)

git_override(
    module_name = "rules_cc_module",
    remote = "https://github.com/hongyan32/rules_cc_module.git",
    commit = "b39f033",
)
```
You may repalce commit attribute with latest-commit-hash 

### 2. Basic Usage

Create a `BUILD` file with your C++ modules:

```starlark
load("@rules_cc_module//cc_module:defs.bzl", "cc_module_library", "cc_module_binary")

# Simple module library
cc_module_library(
    name = "math_module",
    module_interfaces = ["math_module.ixx"],  # Module interface
    srcs = ["math_impl.cpp"],                 # Implementation
    hdrs = ["math_common.h"],                 # Traditional headers
    copts = ["/std:c++20"],                   # C++20 standard
)

# Application using modules
cc_module_binary(
    name = "calculator",
    srcs = ["main.cpp"],
    deps = [":math_module"],
    copts = ["/std:c++20"],
)
```

### 3. Build and Run

```bash
# Build the application
bazel build //:calculator

# Run the application
bazel run //:calculator
```

## Rule Reference

### `cc_module_library`

Compiles C++ module libraries with full support for module interfaces and partitions.

**Key Attributes:**
- `module_interfaces`: List of module interface files (`.ixx`, `.cppm`, `.mpp`)
- `srcs`: Implementation source files (`.cpp`, `.cc`, `.cxx`)
- `hdrs`: Traditional header files (`.h`, `.hpp`, `.hxx`)
- `deps`: Dependencies on other `cc_module_library` or `cc_library` targets
- `copts`: Compiler options (e.g., `["/std:c++20"]` for MSVC)
- `includes`: Include directories
- `defines`: Preprocessor definitions

**Module Partitions:**
Use hyphens in filenames to create module partitions:
- `module-part1.ixx` → module partition `module:part1`
- `module-part2.ixx` → module partition `module:part2`
- `module.ixx` → main module `module`

**Example:**
```starlark
cc_module_library(
    name = "graphics_module",
    module_interfaces = [
        "graphics-2d.ixx",      # Partition: graphics:2d
        "graphics-3d.ixx",      # Partition: graphics:3d
        "graphics.ixx",         # Main module: graphics
    ],
    srcs = glob(["*.cpp"]),
    deps = [":math_module"],
    copts = ["/std:c++20"],
)
```

### `cc_module_binary`

Compiles executables that use C++ modules.

**Key Attributes:**
- `srcs`: Source files containing `main()` and other application code
- `module_interfaces`: Optional application-level module interfaces
- `deps`: Dependencies on `cc_module_library` targets
- `copts`: Compiler options
- `linkopts`: Linker options
- `linkstatic`: Whether to use static linking (default: `True`)

**Example:**
```starlark
cc_module_binary(
    name = "game_engine",
    srcs = ["main.cpp", "game_logic.cpp"],
    deps = [
        ":graphics_module",
        ":physics_module",
        ":audio_module",
    ],
    copts = ["/std:c++20"],
    linkopts = ["/SUBSYSTEM:CONSOLE"],
)
```

## Examples and Testing

### Hello-Module Example

The `examples/hello-module` directory contains a comprehensive example demonstrating:
- Basic modules (`module1`)
- Partitioned modules (`module2` with partitions)
- Dependent modules (`module3`)
- Standard library modules (`std`, `std.compat`)

```bash
cd examples/hello-module

# Build with MSVC
bazel build //src:main

# Build with clang-cl (update .bazelrc with your LLVM path first)
bazel build --config=clang_config //src:main

# Run the example
./bazel-bin/src/main.exe
```

**Expected output:**
```
add(1, 2) = 3
subtract(1, 2) = -1
get_message() = Hello from module2 partition!
multiply_and_add(5, 2, 3) = 13
```

### Test Directory

The `test/` directory contains additional test cases:

```bash
# Build all test targets
bazel build //test:all

# Build specific test
bazel build //test:math_module

# Build test binary
bazel build //test:calculator

# Run test (if executable)
bazel run //test:calculator
```

## Configuration

### For MSVC (Default)

No additional configuration needed. Uses standard MSVC toolchain.

### For clang-cl (Windows)

Update `.bazelrc` with your LLVM installation path:

```bazelrc
build:clang_config --action_env=BAZEL_LLVM="C:/Program Files/LLVM"
# Or your Visual Studio clang-cl path:
# build:clang_config --action_env=BAZEL_LLVM="D:/Applications/VisualStudio/2022/Community/VC/Tools/Llvm"

build:clang_config --extra_toolchains=@local_config_cc//:cc-toolchain-x64_windows-clang-cl
build:clang_config --extra_execution_platforms=//:x64_windows-clang-cl
```

Then build with:
```bash
bazel build --config=clang_config //your:target
```

## Standard Library Modules

You can find the standard library module files at:
```
%VCToolsInstallDir%\modules\std.ixx
%VCToolsInstallDir%\modules\std.compat.ixx
```

Reference: [Microsoft C++ Modules Documentation](https://learn.microsoft.com/en-us/cpp/cpp/tutorial-import-stl-named-module?view=msvc-170)

## Advanced Features

### Module Partition Support

The rules automatically handle module partitions based on filename conventions:

```cpp
// File: math-algebra.ixx
export module math:algebra;  // Partition

// File: math-geometry.ixx  
export module math:geometry; // Partition

// File: math.ixx
export module math;          // Main module
export import :algebra;      // Import partition
export import :geometry;     // Import partition
```

### Cross-Compiler Compatibility

The rules automatically adapt compiler flags based on the detected toolchain:

**Tested and Working:**
- **MSVC** (Windows): `/ifcOutput`, `/reference`, `/std:c++20`
- **clang-cl** (Windows): `-fmodule-output=`, `-fmodule-file=`, `-std=c++20`

**Designed but Untested:**
- **GCC** (Linux): `-fmodule-output=`, `-fmodule-file=`, `-std=c++20` (code ready, needs testing)
- **Clang** (Linux/macOS): `-fmodule-output=`, `-fmodule-file=`, `-std=c++20` (code ready, needs testing)

The implementation includes cross-platform compiler detection and flag adaptation logic that should work with GCC and Clang, but these platforms haven't been tested yet.

### Toolchain Integration

Full integration with Bazel's C++ toolchain system ensures:
- Consistent compilation flags across targets
- Proper dependency propagation
- Platform-specific optimizations
- Feature flag support

## Troubleshooting

### Common Issues

1. **Module interface not found**: Ensure module dependencies are listed in `deps`
2. **Compilation errors**: Check that `/std:c++20` or higher is specified in `copts`
3. **clang-cl not found**: Verify `BAZEL_LLVM` path in `.bazelrc`
4. **Linking errors**: Ensure all required module libraries are in `deps`
5. **Linux/macOS support**: The code includes GCC/Clang support but hasn't been tested yet on non-Windows platforms

### Cross-Platform Status

**Current State:**
- ✅ **Windows (MSVC/clang-cl)**: Fully tested and working
- 🚧 **Linux/macOS (GCC/Clang)**: Implementation complete but untested

The rules include comprehensive support for GCC and Clang compilers with appropriate flags and module compilation logic. However, this cross-platform functionality hasn't been validated on actual Linux/macOS systems yet. Community testing and feedback are welcome!

### Debug Commands

```bash
# Verbose build output
bazel build --verbose_failures //your:target

# Clean build
bazel clean

# Check generated files
ls bazel-bin/
```

## Future Plans

- 🧪 **Cross-Platform Testing**: Validate GCC/Clang support on Linux/macOS (code ready, needs testing)
- 🔄 **Performance**: Parallel module compilation optimizations
- 🔄 **Testing**: Enhanced unit testing framework
- 🔄 **Documentation**: More examples and use cases
- 🔄 **CI/CD**: Automated testing across multiple platforms and compilers

## Contributing

This project welcomes contributions! Areas of interest:
- **Cross-platform testing**: Help validate GCC/Clang support on Linux/macOS
- Performance optimizations
- Additional examples
- Documentation improvements
- Bug reports and fixes

### Testing Cross-Platform Support

If you're using Linux or macOS, we'd love your help testing the GCC/Clang support:

1. Try building the `examples/hello-module` example
2. Report any issues or successes in the GitHub issues
3. Share your `.bazelrc` configuration for your platform
4. Help identify any platform-specific compilation flags needed

The code is designed to work with standard GCC/Clang module compilation flags, but real-world validation is needed.

## License

Apache 2.0 

## Acknowledgments

Special thanks to the Bazel community and Microsoft for C++20 module support.

---

*This implementation bridges the gap until official Bazel C++ module support is complete.*