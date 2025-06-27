# Hello Module Example

This example demonstrates how to use C++ modules with Bazel using the `rules_cc_module` rules. It showcases various C++ module features including basic modules, module partitions, and module dependencies.

## Overview

The example contains:
- **module1**: A simple module that exports an `add` function
- **module2**: A partitioned module with main module and partition, exports `subtract` function and `get_message` function
- **module3**: A complex module that depends on both module1 and module2, exports `multiply_and_add` function
- **std.compat**: Standard library compatibility module for C++23
- **main.cpp**: Application that imports and uses all modules

## Project Structure

```
hello-module/
├── .bazelrc                 # Bazel configuration for C++ modules and clang-cl
├── BUILD                    # Platform definitions for clang-cl
├── MODULE.bazel             # Bazel module dependencies
├── README.md               # This file
└── src/
    ├── BUILD               # Build rules for modules and binary
    ├── main.cpp            # Main application
    ├── std.ixx             # Standard library module interface
    ├── std.compat.ixx      # Standard library compatibility module
    ├── module1/
    │   └── module1.ixx     # Simple module interface
    ├── module2/
    │   ├── module2.ixx         # Main module interface
    │   ├── module2-part.ixx    # Module partition interface
    │   ├── module2_impl.cpp    # Main module implementation
    │   └── module2-part_impl.cpp # Partition implementation
    └── module3/
        ├── module3.ixx     # Module interface
        └── module3_impl.cpp # Module implementation
```

## Prerequisites

1. **Bazel**: Install Bazel (version 7.0+ recommended)
2. **C++ Compiler with Module Support**:
   - **Windows**: Visual Studio 2022 with MSVC or clang-cl
   - **Linux**: Clang 15+

## Building and Running

### Method 1: Using MSVC (Windows)

```bash
# Build the example
bazel build //src:main

# Run the executable
bazel run //src:main
```

### Method 2: Using clang-cl (Windows)

First, update the path to your LLVM installation in `.bazelrc`:

```bash
# Edit .bazelrc and update this line with your LLVM path:
build:clang_config --action_env=BAZEL_LLVM="D:/Applications/VisualStudio/2022/Community/VC/Tools/Llvm"
```

Then build with clang-cl configuration:

```bash
# Build with clang-cl
bazel build --config=clang_config //src:main

# Run the executable
bazel run --config=clang_config //src:main
```

### Method 3: Using Clang (Linux)

```bash
# Build the example
bazel build //src:main --cxxopt=-std=c++20

# Run the executable  
bazel run //src:main --cxxopt=-std=c++20
```

## Expected Output

When you run the program, you should see:

```
add(1, 2) = 3
subtract(1, 2) = -1
get_message() = Hello from module2 partition!
multiply_and_add(5, 2, 3) = 13
```

## Module Descriptions

### module1 (Simple Module)
- **File**: `src/module1/module1.ixx`
- **Exports**: `add(int, int)` function
- **Type**: Basic module with inline implementation

### module2 (Partitioned Module)
- **Main Module**: `src/module2/module2.ixx`
- **Partition**: `src/module2/module2-part.ixx`
- **Implementations**: `module2_impl.cpp`, `module2-part_impl.cpp`
- **Exports**: 
  - `subtract(int, int)` function (from main module)
  - `get_message()` function (from partition)
- **Type**: Partitioned module demonstrating module partitions

### module3 (Dependent Module)
- **Interface**: `src/module3/module3.ixx`
- **Implementation**: `src/module3/module3_impl.cpp`
- **Dependencies**: module1, module2
- **Exports**: `multiply_and_add(int, int, int)` function
- **Type**: Module with external dependencies

## Build Rules Explained

### cc_module_library

Used to compile C++ module libraries:

```starlark
cc_module_library(
    name = "module2",
    module_interfaces = [
        "module2/module2.ixx",        # Main module
        "module2/module2-part.ixx",   # Partition (note the hyphen)
    ],
    srcs = glob(["module2/**/*.cpp"]),  # Implementation files
    deps = [":module1"],               # Module dependencies
    features = ["cpp_modules"],        # Enable C++ modules feature
)
```

### cc_module_binary

Used to compile executables that use C++ modules:

```starlark
cc_module_binary(
    name = "main",
    srcs = ["main.cpp"],
    deps = [
        ":std.compat",
        ":module1", 
        ":module2",
        ":module3",
    ],
    features = ["cpp_modules"],
)
```

## Key Features Demonstrated

1. **Basic Modules**: Simple module interface and implementation
2. **Module Partitions**: Using hyphens in filenames to denote partitions (`module2-part.ixx` → `module2:part`)
3. **Module Dependencies**: Modules importing other modules
4. **Mixed Compilation**: Combining module interfaces with regular C++ source files
5. **Cross-Platform**: Configuration for both MSVC and clang-cl on Windows

## Configuration Files

### .bazelrc
Contains Bazel configuration for:
- Enabling bzlmod
- C++ modules experimental support
- clang-cl toolchain configuration
- C++ standard and encoding settings

### MODULE.bazel
Defines Bazel module dependencies:
- `rules_cc` for C++ compilation
- `rules_cc_module` for C++ module support
- Platform definitions for cross-compilation

## Troubleshooting

### Common Issues

1. **"cpp_modules feature not supported"**
   - Ensure your compiler supports C++ modules
   - Check that `--experimental_cpp_modules` is set in .bazelrc

2. **clang-cl not found**
   - Update `BAZEL_LLVM` path in .bazelrc to your LLVM installation
   - Ensure Visual Studio 2022 with clang-cl is installed

3. **Module import errors**
   - Check module naming: hyphens in filenames become colons in module names
   - Verify module dependencies are correctly declared in BUILD files

4. **Linking errors**
   - Ensure all module dependencies are listed in `deps`
   - Check that implementation files are included in `srcs`

### Debugging Tips

1. **Verbose Build**: Add `--verbose_failures` to see detailed error messages
2. **Clean Build**: Use `bazel clean` to clear cached build artifacts
3. **Check Generated Files**: Look in `bazel-bin` to see generated module files

## Further Reading

- [C++ Modules Documentation](https://en.cppreference.com/w/cpp/language/modules)
- [Bazel C++ Rules](https://bazel.build/reference/be/c-cpp)
- [rules_cc_module Repository](https://github.com/hongyan32/rules_cc_module)

## Contributing

This example is part of the `rules_cc_module` project. Feel free to contribute improvements or report issues at the main repository.
