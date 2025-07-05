# Copyright 2025 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Attribute definitions for C++ Module Rules

This file contains all attribute definitions for cc_module_library and cc_module_binary rules.
Separating attributes into a dedicated file improves code organization and reusability.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//cc_module:providers.bzl", "ModuleInfo")

# File extensions for different types of C++ files
CC_SOURCE = [".cc", ".cpp", ".cxx", ".c++", ".C", ".cu", ".cl"]
C_SOURCE = [".c"]
CC_HEADER = [".h", ".hh", ".hpp", ".ipp", ".hxx", ".h++", ".inc", ".inl", ".tlh", ".tli", ".H", ".tcc"]
CC_MODULE = [".ixx", ".cppm", ".mpp"]

def _common_attrs():
    """Returns attributes common to both cc_module_library and cc_module_binary."""
    return {
        "module_interfaces": attr.label_list(
            allow_files = CC_MODULE,
            doc = """
            List of C++ module interface files.

            Supported file extensions: .ixx, .cppm, .mpp
            
            Module naming rules:
            - File name determines module name: foo.ixx -> module name "foo"
            - Partition modules use hyphens: foo-part.ixx -> module name "foo:part"
            
            Compilation order:
            - Partition modules will be compiled before main modules
            - Dependencies are handled automatically through module declarations
            
            Examples:
            - ["math.ixx"] -> single module "math"
            - ["math-algebra.ixx", "math-geometry.ixx", "math.ixx"] -> 
              partition modules "math:algebra", "math:geometry" and main module "math"
            """,
        ),
        "module_dependencies": attr.string_list_dict(
            default = {},
            doc = """
            Explicit module dependency declarations for parallel compilation.

            This attribute allows declaring dependencies between modules in module_interfaces,
            enabling parallel compilation based on dependency topological ordering.
            
            Format: {module_key: [dependency_list]}
            - module_key: File name (e.g., "math.ixx") or module name (e.g., "math")
            - dependency_list: List of dependencies as file names or module names
            
            Rules:
            - Modules not listed in this dict are considered to have no dependencies
            - Both file names and module names are supported as keys and dependencies
            - File name format: "foo.ixx", "foo-part.ixx"
            - Module name format: "foo", "foo:part" (for partitions)
            - Empty dependency list [] means the module has no dependencies
            
            Examples:
            {
                "math.ixx": ["math-algebra.ixx", "math-geometry.ixx"],  # File name as key
                "graphics": ["math"],                                   # Module name as key
                "app.ixx": ["graphics", "math"],                      # Mixed dependencies
            }
            
            Benefits:
            - Enables parallel compilation of independent modules
            - Prevents compilation errors from missing dependencies
            - Provides explicit control over build order
            """,
        ),
        "srcs": attr.label_list(
            allow_files = CC_SOURCE + CC_HEADER,
            doc = """
            List of C++ source and header files.

            Contains C++ implementation files and private header files that will be compiled.
            Supported source file extensions: .cc, .cpp, .cxx, .c++
            Supported header file extensions: .h, .hh, .hpp, .ipp, .hxx, .h++
            
            Header files included in srcs are treated as private headers and will not be propagated to dependent targets.
            For libraries: Use the hdrs attribute for public headers that should be available to dependent targets.
            For binaries: Can contain the main() function and application logic.
            
            Source files can:
            - Import modules defined in module_interfaces
            - Use traditional #include header files
            """,
        ),
        "additional_linker_inputs": attr.label_list(
            allow_files = True,
            doc = """
            Additional linker input files.

            These files will be provided as additional inputs to the linker during the linking phase.
            Commonly used for:
            - Linker scripts
            - Additional library files
            - Resource files (executables)
            - Version information files (executables)
            """,
        ),
        "deps": attr.label_list(
            allow_empty = True,
            providers = [[CcInfo], [CcInfo, ModuleInfo]],
            doc = """
            List of other C++ targets to depend on.

            Can depend on:
            - cc_module_library targets (module dependencies will be handled automatically)
            - Standard cc_library targets
            - Any target that provides CcInfo
            
            Module dependencies will be automatically propagated and handled.
            """,
        ),
        "data": attr.label_list(
            default = [],
            allow_files = True,
            doc = """
            List of runtime data files.

            These files will be included in the runtime environment.
            Commonly used for:
            - Configuration files
            - Resource files
            - Test data
            - Documentation files (libraries)
            
            Data files are not used during compilation but are available at runtime.
            """,
        ),
        "includes": attr.string_list(
            doc = """
            List of include paths.

            These paths will be added to the compilation command's -I arguments.
            Paths are relative to the current BUILD file's package.
            """,
        ),
        "quote_includes": attr.string_list(
            doc = """
            List of quote include paths.

            These paths will be added to the compilation command's -iquote arguments (for supported compilers).
            Used for #include "..." style includes.
            """,
        ),
        "defines": attr.string_list(
            doc = """
            List of preprocessor macro definitions.

            Each string will be added to the compilation command's -D arguments.
            Examples: 
            - Library: ["DEBUG=1", "FEATURE_ENABLED"]
            - Binary: ["VERSION=1.0", "RELEASE_BUILD"]
            """,
        ),
        "copts": attr.string_list(
            doc = """
            List of compilation options.

            These options will be added to the C++ compilation command. For C++ modules, you need to specify a supported C++ standard:
            - MSVC: ["/std:c++20"] or ["/std:c++latest"]
            - GCC/Clang: ["-std=c++20"] or ["-std=c++23"]
            
            Other common options:
            - Optimization: ["/O2"] (MSVC) or ["-O2"] (GCC/Clang)
            - Debug: ["/Zi"] (MSVC) or ["-g"] (GCC/Clang)
            """,
        ),
        "cxxopts": attr.string_list(
            doc = """
            List of C++-specific compilation options.

            These options will be added only when compiling C++ source files (.cpp, .cxx, .cc).
            They will not be applied to C source files (.c).
            
            Examples:
            - MSVC: ["/std:c++latest", "/permissive-"]
            - GCC/Clang: ["-std=c++20", "-fno-rtti"]
            """,
        ),
        "conlyopts": attr.string_list(
            doc = """
            List of C-specific compilation options.

            These options will be added only when compiling C source files (.c).
            They will not be applied to C++ source files (.cpp, .cxx, .cc).
            
            Examples:
            - MSVC: ["/TC"]
            - GCC/Clang: ["-std=c99", "-Wstrict-prototypes"]
            """,
        ),
        "linkopts": attr.string_list(
            doc = """
            List of linker options.

            These options will be added to the linking command.
            Examples:
            - Library: ["/SUBSYSTEM:CONSOLE"] (MSVC) or ["-pthread"] (GCC/Clang)
            - Binary: ["/SUBSYSTEM:CONSOLE", "/SUBSYSTEM:WINDOWS"] (Windows) or ["-pthread"] (Linux)
            """,
        ),
        "_cc_toolchain": attr.label(
            default = "@bazel_tools//tools/cpp:current_cc_toolchain",
            doc = "Internal C++ toolchain reference for internal use.",
        ),
    }

def _cc_module_library_attrs():
    """Returns the attributes for cc_module_library rule."""
    attrs = _common_attrs()
    
    # Add library-specific attributes
    attrs.update({
        "hdrs": attr.label_list(
            allow_files = CC_HEADER,
            doc = """
            List of public header files.

            These header files will be included in the compilation context and can be used by other targets
            that depend on this library.
            Supported file extensions: .h, .hh, .hpp, .ipp, .hxx, .h++
            """,
        ),
        "linkstatic": attr.bool(
            default = True,
            doc = """
            Whether to create a static library.

            - True (default): Create static library (.a/.lib)
            - False: Create dynamic library (.so/.dll) if supported
            
            Note: Module libraries usually use static linking.
            """,
        ),
        "alwayslink": attr.bool(
            default = False,
            doc = """
            Whether to always link this library.

            - True: Link all symbols from this library even if not directly referenced
            - False (default): Only link referenced symbols
            
            May need to be set to True for module libraries containing global initialization code.
            """,
        ),
    })
    
    return attrs

def _cc_module_binary_attrs():
    """Returns the attributes for cc_module_binary rule."""
    attrs = _common_attrs()
    
    # Add binary-specific attributes
    attrs.update({
        "linkstatic": attr.bool(
            default = True,
            doc = """
            Whether to statically link dependency libraries.

            - True (default): Statically link all dependencies, generating standalone executable
            - False: Dynamically link dependencies, requires runtime library support
            
            For C++ module applications, static linking is usually recommended.
            """,
        ),
        "linkshared": attr.bool(
            default = False,
            doc = """
            Whether to create a shared library instead of an executable.

            - False (default): Create executable
            - True: Create dynamic library (.so/.dll)
            
            Usually used for creating plugins or shared modules.
            """,
        ),
        "stamp": attr.int(
            default = -1,
            doc = """
            Whether to embed build information in the binary file.

            - -1 (default): Decided by --stamp flag
            - 0: Don't embed build information
            - 1: Always embed build information (build time, version, etc.)
            """,
        ),
        "malloc": attr.label(
            default = "@bazel_tools//tools/cpp:malloc",
            providers = [CcInfo],
            doc = """
            Custom memory allocator.

            Uses the system's standard malloc implementation by default.
            Can specify a custom memory allocator implementation.
            """,
        ),
    })
    
    # Update shared attributes with binary-specific documentation
    attrs["module_interfaces"] = attr.label_list(
        allow_files = CC_MODULE,
        doc = """
        List of application-level C++ module interface files (optional).

        Usually binary files don't need to export module interfaces, but may be useful in some cases:
        - Internal modular organization of applications
        - Interface definitions in plugin architectures
        
        Supported file extensions: .ixx, .cppm, .mpp
        Module naming and partition rules are the same as cc_module_library.
        Use module_dependencies to declare dependencies for parallel compilation.
        """,
    )
    
    return attrs

# Public functions to get attribute dictionaries
def cc_module_library_attrs():
    """Public function to get cc_module_library attributes."""
    return _cc_module_library_attrs()

def cc_module_binary_attrs():
    """Public function to get cc_module_binary attributes."""
    return _cc_module_binary_attrs()
