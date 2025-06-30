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

"""C++ Module Rules for Bazel

This file implements C++ module support rules for Bazel, including:

1. cc_module_library: Compile C++ module libraries
   - Support for C++ module interface files (.ixx, .cppm, .mpp)
   - Support for module partitions (represented by hyphens in file names)
   - Cross-platform compiler support (MSVC, Clang)
   - Mixed compilation with traditional C++ code

2. cc_module_binary: Compile executables containing C++ modules
   - Support for linking C++ module libraries
   - Support for application-level module interfaces (optional)
   - Static/dynamic linking options

Key features:
- Automatic handling of module dependencies and compilation order
- Support for correct compilation order of module partitions (partitions first, main module last)
- Cross-platform compiler flag adaptation
- C++ standard version checking (requires C++20 or higher)
- Compatible with existing cc_library/cc_binary rules

See the documentation of each rule for usage examples.
"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc:action_names.bzl", "CPP_COMPILE_ACTION_NAME")
load("//cc_module:cc_helper.bzl", "cc_helper")
load("//cc_module:providers.bzl", "ModuleCompilationInfo", "ModuleInfo")


CC_SOURCE = [".cc", ".cpp", ".cxx", ".c++", ".C", ".cu", ".cl"]
C_SOURCE = [".c"]
CC_HEADER = [".h", ".hh", ".hpp", ".ipp", ".hxx", ".h++", ".inc", ".inl", ".tlh", ".tli", ".H", ".tcc"]
CC_MODULE = [".ixx", ".cppm", ".mpp"]


def get_module_name_from_file(interface_file):
    """Extract module name from interface file path
    
    Args:
        interface_file: File object representing the module interface file
        
    Returns:
        string: Module name, hyphens are converted to colons for partitions
        
    Example:
        "foo/foo.ixx" -> "foo"
        "foo/foo-part.ixx" -> "foo:part"
    """
    basename = interface_file.basename
    # Remove extension
    for ext in CC_MODULE:
        if basename.endswith(ext):
            basename = basename[:-len(ext)]
            break

    # Convert first hyphen to colon (for module partition)
    if "-" in basename:
        parts = basename.split("-", 1)  # Only split on first hyphen
        return parts[0] + ":" + parts[1]
    
    return basename

def _filter_headers_from_srcs(srcs_files):
    """Filter header files from source files list.
    
    Args:
        srcs_files: List of source files
        
    Returns:
        tuple: (header_files, non_header_files) - separated header and non-header files
    """
    header_files = []
    non_header_files = []
    
    for file in srcs_files:
        is_header = False
        for ext in CC_HEADER:
            if file.basename.endswith(ext):
                header_files.append(file)
                is_header = True
                break
        if not is_header:
            non_header_files.append(file)
    
    return header_files, non_header_files

def _filter_none(input_list):
    filtered_list = []
    for element in input_list:
        if element != None:
            filtered_list.append(element)
    return filtered_list

def _cc_module_library_impl(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    
    # Collect C++ compilation contexts
    compilation_contexts = []
    linking_contexts = []
    
    for dep in ctx.attr.deps:
        if CcInfo in dep:
            compilation_contexts.append(dep[CcInfo].compilation_context)
            linking_contexts.append(dep[CcInfo].linking_context)


    cc_helper.check_cpp_modules(ctx, feature_configuration)
    
    # Filter headers from srcs (following Bazel's standard approach)
    private_hdrs, actual_srcs = _filter_headers_from_srcs(ctx.files.srcs)
    
    # Collect module compilation contexts, not including current module information yet
    module_compilation_infos = []
    for dep in ctx.attr.deps:
        if ModuleInfo in dep:
            # Extract all module compilation information from ModuleInfo
            module_compilation_infos.extend(dep[ModuleInfo].module_dependencies.to_list())

    # If there are module interface files, compile all module interface files in order
    current_module_compilation_infos = []
    if hasattr(ctx.attr, "module_interfaces") and ctx.attr.module_interfaces:
        # Ensure cpp_modules feature is available, report error if not

        current_module_compilation_infos = compile_module_interfaces(
            ctx = ctx,
            cc_toolchain = cc_toolchain,
            feature_configuration = feature_configuration,
            interface_files = ctx.files.module_interfaces,
            module_compilation_infos = module_compilation_infos,
            compilation_contexts = compilation_contexts,
            current_target_headers = ctx.files.hdrs + private_hdrs,
        )
    

    # Collect all module object files for regular compilation
    module_obj_files = []
    for module_info in current_module_compilation_infos:
        module_obj_files.append(module_info.obj_file)

    # Collect dependent module information depset
    transitive_module_deps = []
    for dep in ctx.attr.deps:
        if ModuleInfo in dep:
            transitive_module_deps.append(dep[ModuleInfo].module_dependencies)
    all_module_dependencies = depset(
        direct = current_module_compilation_infos if current_module_compilation_infos else [],
        transitive = transitive_module_deps,
    )

    additional_make_variable_substitutions = cc_helper.get_toolchain_global_make_variables(cc_toolchain)

    # Collect module dependency .ifc files as additional inputs to ensure correct compilation order
    module_ifc_inputs = []
    for module_info in all_module_dependencies.to_list():
        module_ifc_inputs.append(module_info.ifc_file)

    # Collect C++ and general compilation flags separately
    cxx_flags = []
    cxx_flags.extend(ctx.attr.copts)  # Rule-level compilation options
    cxx_flags.extend(ctx.fragments.cpp.cxxopts)  # C++ specific compilation options
    
    user_compile_flags = []
    user_compile_flags.extend(ctx.fragments.cpp.copts)  # General C/C++ compilation options
    user_compile_flags.extend(get_module_compile_flags(cc_toolchain, all_module_dependencies))  # C++ module flags


    # Regular C++ compilation
    (compilation_context, compilation_outputs) = cc_common.compile(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        public_hdrs = ctx.files.hdrs,
        private_hdrs = private_hdrs,
        srcs = actual_srcs,
        quote_includes = ctx.attr.quote_includes,
        system_includes = cc_helper.system_include_dirs(ctx, additional_make_variable_substitutions),
        defines = ctx.attr.defines,
        compilation_contexts = compilation_contexts,
        additional_inputs = module_ifc_inputs,  # Add module .ifc files as input dependencies
        user_compile_flags = user_compile_flags,
        cxx_flags = cxx_flags,  # C++ specific compilation flags
    )
    
    compilation_outputs_without_module = compilation_outputs
    # Add module object files to compilation outputs
    if module_obj_files:
        # Create new compilation outputs including original object files and module object files
        # compilation_outputs.objects is a list of depsets, need to merge correctly
        all_objects_depset = depset(
            direct = module_obj_files,
            transitive = [depset(compilation_outputs.objects)]
        )
        compilation_outputs = cc_common.create_compilation_outputs(
            objects = all_objects_depset,
            pic_objects = depset(compilation_outputs.pic_objects),
        )
    
    # has_compilation_outputs = (len(compilation_outputs.pic_objects) > 0 or
    #                           len(compilation_outputs.objects) > 0)

    # Process link flags using cc_helper directly
    user_link_flags = cc_helper.linkopts(ctx, additional_make_variable_substitutions, cc_toolchain)

    # Handle the case when compilation_outputs is empty (e.g., header-only libraries)
    # For header-only libraries, we don't need to create actual library files,
    # but we still need to provide compilation context for dependencies
    
    supports_dynamic_linker = cc_common.is_enabled(
        feature_configuration = feature_configuration,
        feature_name = "supports_dynamic_linker",
    )
    create_dynamic_library = (not ctx.attr.linkstatic and
                              supports_dynamic_linker and
                              (not cc_helper.is_compilation_outputs_empty(compilation_outputs_without_module) or
                               cc_common.is_enabled(
                                   feature_configuration = feature_configuration,
                                   feature_name = "header_module_codegen",
                               )))

    # Check if we have any actual compilation outputs to link
    has_compilation_outputs = not cc_helper.is_compilation_outputs_empty(compilation_outputs)
    
    if has_compilation_outputs:
        # Normal case: we have object files to link
        (linking_context, linking_outputs) = cc_common.create_linking_context_from_compilation_outputs(
            name = ctx.label.name,
            actions = ctx.actions,
            cc_toolchain = cc_toolchain,
            compilation_outputs = compilation_outputs,
            feature_configuration = feature_configuration,
            language = "c++",
            additional_inputs = ctx.files.additional_linker_inputs,
            linking_contexts = linking_contexts,
            user_link_flags = user_link_flags,
            alwayslink = ctx.attr.alwayslink,
            disallow_dynamic_library = not create_dynamic_library,
        )
        
        # Collect output files
        library = linking_outputs.library_to_link
        files = []
        files.extend(compilation_outputs.objects)
        files.extend(compilation_outputs.pic_objects)
        if library:
            if library.pic_static_library:
                files.append(library.pic_static_library)
            if library.static_library:
                files.append(library.static_library)
            if library.dynamic_library:
                files.append(library.dynamic_library)
    else:
        # Header-only library case: create minimal linking context
        linking_context = cc_common.merge_linking_contexts(
            linking_contexts = linking_contexts
        )
        files = []

    # Return providers
    providers = [
        DefaultInfo(files = depset(_filter_none(files))),
        CcInfo(
            compilation_context = compilation_context,
            linking_context = linking_context,
        ),
        # Add ModuleInfo provider
        ModuleInfo(
            module_dependencies = all_module_dependencies
        ),
    ]
    
    return providers

def is_partition_module(file):
    """Checks if a file is a partition module.

    A file is considered a partition module if its name contains a hyphen.
    Args:
        file: The file to check.
    Returns:
        True if the file is a partition module, False otherwise.
    """
    return "-" in file.basename

def sort_module_interface_files(interface_files):
    """Sorts module interface files so that partition modules come first, followed by main modules.

    Sort module interface files to ensure partition modules come before main modules,
    since main modules depend on partition modules.
    Args:
        interface_files: List of interface files to sort
    Returns:
        Sorted list of interface files
    """
    main_modules = []
    partition_modules = []
    for file in interface_files:
        if is_partition_module(file):
            partition_modules.append(file)
        else:
            main_modules.append(file)
    # Return partition modules first, then main modules
    return partition_modules + main_modules

def compile_module_interfaces(ctx, cc_toolchain, feature_configuration, interface_files, module_compilation_infos, compilation_contexts, current_target_headers):
    """Compiles multiple C++ module interface files, ensuring partitions are built before main modules.

    If there are partitions, partition files must be compiled first, so sorting is needed.
    Partition modules come first, for example:
    ├── MyModule.ixx            # Main module: export module MyModule;
    ├── MyModule-part1.ixx      # Partition: export module MyModule:Part1;
    ├── MyModule-part2.ixx      # Partition: export module MyModule:Part2;
    Additionally, a cc_module_library can only have 1 main module.
    Args:
        ctx: Rule context
        cc_toolchain: C++ toolchain
        feature_configuration: C++ feature configuration
        interface_files: List of interface files to compile
        module_compilation_infos: List of ModuleCompileInfo for module dependencies
        compilation_contexts: C++ compilation contexts
        current_target_headers: List of header files from the current target (hdrs + private_hdrs)
        
    Returns:
        tuple: (current_module_compilation_infos, all_module_compilation_infos)
               - current_module_compilation_infos: List of currently compiled module information
               - all_module_compilation_infos: List of all module information including dependencies and current modules
    """
    current_module_compilation_infos = []

    # All module dependency information, because later compiled modules like partition modules will depend on earlier modules like main modules
    all_module_compilation_infos = module_compilation_infos[:]
    interface_files = sort_module_interface_files(interface_files)
    for interface_file in interface_files:
        module_name = get_module_name_from_file(interface_file)
        
        # Compile single module interface
        module_compilation_info = compile_single_module_interface(
            ctx = ctx,
            cc_toolchain = cc_toolchain,
            feature_configuration = feature_configuration,
            module_name = module_name,
            interface_file = interface_file,
            module_compilation_infos = all_module_compilation_infos,
            compilation_contexts = compilation_contexts,
            current_target_headers = current_target_headers,
        )
        all_module_compilation_infos.append(module_compilation_info)
        current_module_compilation_infos.append(module_compilation_info)

    return current_module_compilation_infos

def compile_single_module_interface(ctx, cc_toolchain, feature_configuration, module_name, interface_file, module_compilation_infos, compilation_contexts, current_target_headers):
    """
    Compiles a single module interface file, generating .ifc and .obj files.
    
    This function uses cc_common.create_compile_variables and cc_common.get_memory_inefficient_command_line
    to ensure module compilation uses the same toolchain configuration and feature flags as cc_common.compile.
    
    Advantages compared to other methods (such as compile_action_argv, etc.):
    1. Toolchain consistency: Uses the same compilation variables and command line generation logic as cc_common.compile
    2. Cross-platform compatibility: Automatically handles specific flag formats for different compilers (MSVC, Clang)
    3. Feature configuration: Correctly applies all toolchain feature flags, optimization options, and platform-specific settings
    4. Future compatibility: Uses Bazel public APIs, avoiding dependency on internal implementation details
    5. Automatic handling: Include paths, preprocessor definitions, and compilation flags are all handled automatically through the toolchain
    
    Args:
        ctx: Rule context
        cc_toolchain: C++ toolchain
        feature_configuration: Feature configuration
        module_name: Module name
        interface_file: Module interface file
        module_compilation_infos: List of module compilation information (dependent modules)
        compilation_contexts: List of compilation contexts (from dependencies)
        current_target_headers: List of header files from the current target (hdrs + private_hdrs)
        
    Returns:
        ModuleCompilationInfo: Contains compiled .ifc and .obj file information
    """
    # Generate safe filename for output files (colons cannot be used in filenames)
    safe_name = module_name.replace(":", "-")
    
    # Determine output file extension based on compiler type. 
    # For MSVC: toolchain_id = msvc-x64, compiler = msvc-cl.exe
    is_msvc = cc_toolchain.compiler == "msvc-cl"
    
    if is_msvc:
        # MSVC compiler uses .ifc and .obj
        ifc_file = ctx.actions.declare_file("_bmis/{}/{}.ifc".format(ctx.label.name, safe_name))
        obj_file = ctx.actions.declare_file("_bmis/{}/{}.obj".format(ctx.label.name, safe_name))
    else:
        # GCC/Clang compilers use .pcm and .o
        ifc_file = ctx.actions.declare_file("_bmis/{}/{}.pcm".format(ctx.label.name, safe_name))
        obj_file = ctx.actions.declare_file("_bmis/{}/{}.o".format(ctx.label.name, safe_name))
    
    # Merge all compilation contexts
    merged_compilation_context = cc_common.merge_compilation_contexts(
        compilation_contexts = compilation_contexts
    )
    
    # Create compilation variables - let cc_common handle output files in a cross-platform way
    # Merge user compilation flags, including rule-level and fragment-level options
    all_user_compile_flags = []
    all_user_compile_flags.extend(ctx.attr.copts)
    all_user_compile_flags.extend(ctx.fragments.cpp.copts)
    all_user_compile_flags.extend(ctx.fragments.cpp.cxxopts)
    # Use get_module_compile_flags to get module dependency flags, ensuring consistency with other places
    # Create a temporary depset to pass to get_module_compile_flags
    module_deps_depset = depset(direct = module_compilation_infos)
    all_user_compile_flags.extend(get_module_compile_flags(cc_toolchain, module_deps_depset))
    additional_make_variable_substitutions = cc_helper.get_toolchain_global_make_variables(cc_toolchain)

    compilation_variables = cc_common.create_compile_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        source_file = interface_file.path,
        output_file = obj_file.path,  # Use obj_file as primary output
        user_compile_flags = all_user_compile_flags,
        include_directories = depset(merged_compilation_context.includes.to_list()),
        quote_include_directories = depset(merged_compilation_context.quote_includes.to_list()),
        system_include_directories = depset(cc_helper.system_include_dirs(ctx, additional_make_variable_substitutions) + merged_compilation_context.system_includes.to_list()),
        preprocessor_defines = depset(merged_compilation_context.defines.to_list() + ctx.attr.defines),
        add_legacy_cxx_options = True,  # Ensure legacy C++ options are included
    )
    
    # Get the same compilation command line as cc_common.compile
    # Use appropriate action_name to ensure correct compiler configuration
    # Here we use CPP_COMPILE_ACTION_NAME instead of CPP_MODULE_COMPILE_ACTION_NAME because
    # CPP_MODULE_COMPILE_ACTION_NAME will miss adding /MD parameter in MSVC, causing incompatibility
    # between generated obj files and other files
    base_compiler_options = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_COMPILE_ACTION_NAME,
        variables = compilation_variables,
    )
    c_compiler_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = CPP_COMPILE_ACTION_NAME,
    )
    env = cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = CPP_COMPILE_ACTION_NAME,
        variables = compilation_variables,
    )
    # Build final compilation arguments
    compile_args = ctx.actions.args()
    
    # Add base compilation options (standard options from cc_common), filter out -c file, will add later
    for option in base_compiler_options:
        # Filter out -c and the file argument that follows it
        if option == "-c":
            continue
        if option.endswith(".ixx") or option.endswith(".cppm") or option.endswith(".mpp"):
            continue
        compile_args.add(option)
    
    # Add module-specific output arguments
    # Note: cc_common.get_memory_inefficient_command_line already includes standard output file arguments
    # We only need to add module interface file output arguments
    if is_msvc:
        # MSVC compiler: add interface file output
        compile_args.add("/ifcOutput", ifc_file.path)
        compile_args.add("/c", interface_file.path) 
    else:
        # GCC/Clang compilers: add module output
        compile_args.add("-fmodule-output=" + ifc_file.path)
        # Here we need to change "-c ixxfile" to "-x c++-module -c ixxfile", additionally specify module file with -x c++-module
        compile_args.add("-x", "c++-module")
        compile_args.add("-c", interface_file.path)  # Ensure compiler knows this is a module interface file
    # Collect all input files efficiently using depsets
    direct_inputs = [interface_file]
    transitive_inputs = []
    
    # Add module dependency .ifc files as inputs (these are actual dependencies)
    for module_dep in module_compilation_infos:
        direct_inputs.append(module_dep.ifc_file)
    
    # Add headers from compilation context as inputs
    # Include both dependency headers and current target headers
    if merged_compilation_context.headers:
        transitive_inputs.append(merged_compilation_context.headers)
    if current_target_headers:
        direct_inputs.extend(current_target_headers)
    
    # Create final input depset
    all_inputs = depset(
        direct = direct_inputs,
        transitive = transitive_inputs
    )

    # Execute compilation
    # This method ensures that module interface compilation uses exactly the same toolchain settings
    # as regular C++ compilation, including all feature flags, optimization options, and platform-specific configurations
    ctx.actions.run(
        executable = c_compiler_path,
        arguments = [compile_args],
        env = env,
        inputs = all_inputs,
        outputs = [ifc_file, obj_file],
        mnemonic = "CppModuleCompile",
        progress_message = "Compiling C++ module {} from {}".format(module_name, interface_file.basename),
    )
    
    return ModuleCompilationInfo(
        module_name = module_name,
        ixx_file = interface_file,
        ifc_file = ifc_file,
        obj_file = obj_file,
    )

def get_module_compile_flags(cc_toolchain, all_module_dependencies):
    """Get compilation flags (including module dependencies)
    
    Args:
        cc_toolchain: C++ toolchain (used to detect compiler type)
        all_module_dependencies: depset[ModuleCompilationInfo] containing all module dependency information
    Returns:
        List[string]: Compile flags including module dependencies
    """
    flags = []
    # Determine output file extension based on compiler type. For MSVC: toolchain_id = msvc-x64, compiler = msvc-cl
    # For clang-cl: toolchain: clang_cl_x64, compiler: clang-cl
    is_msvc = cc_toolchain.compiler == "msvc-cl" 
    is_clang_cl = cc_toolchain.compiler == "clang-cl"
    # Add C++ CPU architecture compilation flags for clang-cl, because clang-cl cannot recognize x64_windows
    # or defaults to x386, need to choose appropriate compilation options based on target architecture
    # This is not an issue when using MSVC
    if is_clang_cl:
        # Check target architecture, add appropriate parameters
        target_cpu = cc_toolchain.cpu
        if target_cpu in ("x64_windows", "x86_64", "amd64", "x64"):
            # 64-bit target
            flags.append("-m64")
        elif target_cpu in ("x86", "x86_32", "i386", "i686"):
            # 32-bit target
            flags.append("-m32")


    # Add module dependency information - support cross-platform compilers
    for module_info in all_module_dependencies.to_list():
        # Check compiler type to use correct flag format
        if is_msvc:
            # MSVC compiler
            flags.append("/reference{}={}".format(module_info.module_name, module_info.ifc_file.path))
        else:
            # GCC/Clang compilers
            flags.append("-fmodule-file={}={}".format(module_info.module_name, module_info.ifc_file.path))

    return flags


cc_module_library = rule(
    doc = """
    Rule for compiling C++ module libraries.

    The cc_module_library rule is used to compile libraries containing C++ module interface files. It supports:
    - Compilation of C++ module interface files (.ixx, .cppm, .mpp)
    - Support for module partitions (represented by hyphens in file names)
    - Mixed compilation with traditional C++ code
    - Header-only libraries (only hdrs, no srcs or module_interfaces)
    - Module-only libraries (only module_interfaces, no srcs)
    - Cross-platform compiler support (MSVC, Clang)

    Library types supported:
    1. **Standard module library**: module_interfaces + srcs + hdrs
    2. **Header-only library**: only hdrs (no compilation outputs generated)
    3. **Module-only library**: only module_interfaces (templates/constexpr in interface)
    4. **Mixed library**: Any combination of the above

    Example usage:
    ```starlark
    # Standard module library
    cc_module_library(
        name = "my_module",
        module_interfaces = ["my_module.ixx"],
        srcs = ["my_module_impl.cpp"],
        hdrs = ["my_module.h"],
        deps = ["//other:module_dep"],
        copts = ["/std:c++20"],  # MSVC
        # copts = ["-std=c++20"],  # GCC/Clang
    )
    
    # Header-only library
    cc_module_library(
        name = "header_only",
        hdrs = ["utilities.h"],
        copts = ["/std:c++20"],
    )
    
    # Module-only library (templates/constexpr)
    cc_module_library(
        name = "template_module",
        module_interfaces = ["templates.ixx"],
        copts = ["/std:c++20"],
    )
    ```

    Module partition example:
    ```starlark
    cc_module_library(
        name = "partitioned_module",
        module_interfaces = [
            "module-part1.ixx",  # Partition: module:part1
            "module-part2.ixx",  # Partition: module:part2  
            "module.ixx",        # Main module: module
        ],
    )
    ```
    """,
    implementation = _cc_module_library_impl,
    attrs = {
        "hdrs": attr.label_list(
            allow_files = CC_HEADER,
            doc = """
            List of public header files.

            These header files will be included in the compilation context and can be used by other targets
            that depend on this library.
            Supported file extensions: .h, .hh, .hpp, .ipp, .hxx, .h++
            """,
        ),
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
        "srcs": attr.label_list(
            allow_files = CC_SOURCE + CC_HEADER,
            doc = """
            List of C++ source and header files.

            These are C++ implementation files and private header files that will be compiled together with module interface files.
            Supported source file extensions: .cc, .cpp, .cxx, .c++
            Supported header file extensions: .h, .hh, .hpp, .ipp, .hxx, .h++
            
            Header files included in srcs are treated as private headers and will not be propagated to targets that depend on this library.
            Use the hdrs attribute for public headers that should be available to dependent targets.
            
            Note: Source files can import modules defined in module_interfaces.
            """,
        ),
        "additional_linker_inputs": attr.label_list(
            allow_files = True,
            doc = """
            Additional linker input files.

            These files will be provided as additional inputs to the linker during the linking phase.
            Usually used for linker scripts, additional library files, etc.
            """,
        ),
        "deps": attr.label_list(
            allow_empty = True,
            providers = [[CcInfo], [CcInfo, ModuleInfo]],
            doc = """
            List of other C++ targets to depend on.

            Can depend on:
            - Other cc_module_library targets (module dependencies will be handled automatically)
            - Standard cc_library targets
            - Any target that provides CcInfo
            
            Module dependencies will be automatically propagated and handled.
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
            Examples: ["DEBUG=1", "FEATURE_ENABLED"]
            """,
        ),
        "copts": attr.string_list(
            doc = """
            List of compilation options.

            These options will be added to the C++ compilation command. For C++ modules, you usually need to specify the C++ standard:
            - MSVC: ["/std:c++20"] or ["/std:c++latest"]
            - GCC/Clang: ["-std=c++20"] or ["-std=c++23"]
            
            Other common options:
            - Optimization: ["/O2"] (MSVC) or ["-O2"] (GCC/Clang)
            - Debug: ["/Zi"] (MSVC) or ["-g"] (GCC/Clang)
            """,
        ),
        "linkopts": attr.string_list(
            doc = """
            List of linker options.

            These options will be added to the linking command.
            Examples: ["/SUBSYSTEM:CONSOLE"] (MSVC) or ["-pthread"] (GCC/Clang)
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
        "_cc_toolchain": attr.label(
            default = "@bazel_tools//tools/cpp:current_cc_toolchain",
            doc = "Internal C++ toolchain reference for internal use.",
        ),
    },
    fragments = ["cpp"],
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
)

def _cc_module_binary_impl(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    
    # Collect C++ compilation contexts
    compilation_contexts = []
    linking_contexts = []
    for dep in ctx.attr.deps:
        if CcInfo in dep:
            compilation_contexts.append(dep[CcInfo].compilation_context)
            linking_contexts.append(dep[CcInfo].linking_context)

    # Check C++ modules functionality
    cc_helper.check_cpp_modules(ctx, feature_configuration)
    
    # Filter headers from srcs (following Bazel's standard approach)
    private_hdrs, actual_srcs = _filter_headers_from_srcs(ctx.files.srcs)
    
    # Collect module compilation contexts, not including current module information yet
    module_compilation_infos = []
    for dep in ctx.attr.deps:
        if ModuleInfo in dep:
            # Extract all module compilation information from ModuleInfo
            module_compilation_infos.extend(dep[ModuleInfo].module_dependencies.to_list())

    # If there are module interface files, compile all module interface files in order
    current_module_compilation_infos = []
    if hasattr(ctx.attr, "module_interfaces") and ctx.attr.module_interfaces:
        current_module_compilation_infos = compile_module_interfaces(
            ctx = ctx,
            cc_toolchain = cc_toolchain,
            feature_configuration = feature_configuration,
            interface_files = ctx.files.module_interfaces,
            module_compilation_infos = module_compilation_infos,
            compilation_contexts = compilation_contexts,
            current_target_headers = private_hdrs,  # cc_module_binary uses private headers from srcs
        )

    # Collect all module object files for regular compilation
    module_obj_files = []
    for module_info in current_module_compilation_infos:
        module_obj_files.append(module_info.obj_file)

    # Collect dependent module information depset
    transitive_module_deps = []
    for dep in ctx.attr.deps:
        if ModuleInfo in dep:
            transitive_module_deps.append(dep[ModuleInfo].module_dependencies)
    all_module_dependencies = depset(
        direct = current_module_compilation_infos if current_module_compilation_infos else [],
        transitive = transitive_module_deps,
    )

    # Collect module dependency .ifc files as additional inputs to ensure correct compilation order
    module_ifc_inputs = []
    for module_info in all_module_dependencies.to_list():
        module_ifc_inputs.append(module_info.ifc_file)

    # Collect C++ and general compilation flags separately
    cxx_flags = []
    cxx_flags.extend(ctx.attr.copts)  # Rule-level compilation options
    cxx_flags.extend(ctx.fragments.cpp.cxxopts)  # C++ specific compilation options
    
    user_compile_flags = []
    user_compile_flags.extend(ctx.fragments.cpp.copts)  # General C/C++ compilation options
    user_compile_flags.extend(get_module_compile_flags(cc_toolchain, all_module_dependencies))  # C++ module flags

    additional_make_variable_substitutions = cc_helper.get_toolchain_global_make_variables(cc_toolchain)
    user_link_flags = cc_helper.linkopts(ctx, additional_make_variable_substitutions, cc_toolchain)

    # Regular C++ compilation
    (_compilation_context, compilation_outputs) = cc_common.compile(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = actual_srcs,
        private_hdrs = private_hdrs,
        quote_includes = ctx.attr.quote_includes,
        system_includes = cc_helper.system_include_dirs(ctx, additional_make_variable_substitutions),
        defines = ctx.attr.defines,
        compilation_contexts = compilation_contexts,
        additional_inputs = module_ifc_inputs,  # Add module .ifc files as input dependencies
        user_compile_flags = user_compile_flags,
        cxx_flags = cxx_flags,  # C++ specific compilation flags
    )
    
    # Add module object files to compilation outputs
    if module_obj_files:
        # Create new compilation outputs including original object files and module object files
        all_objects_depset = depset(
            direct = module_obj_files,
            transitive = [depset(compilation_outputs.objects)]
        )
        compilation_outputs = cc_common.create_compilation_outputs(
            objects = all_objects_depset,
            pic_objects = depset(compilation_outputs.pic_objects),
        )
    
    output_type = "dynamic_library" if ctx.attr.linkshared else "executable"
    
    # Process link flags using cc_helper directly
    additional_make_variable_substitutions = cc_helper.get_toolchain_global_make_variables(cc_toolchain)
    user_link_flags = cc_helper.linkopts(ctx, additional_make_variable_substitutions, cc_toolchain)

    malloc = ctx.attr.malloc
    linking_contexts.append(malloc[CcInfo].linking_context)

    linking_outputs = cc_common.link(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        language = "c++",
        compilation_outputs = compilation_outputs,
        linking_contexts = linking_contexts,
        user_link_flags = user_link_flags,
        link_deps_statically = ctx.attr.linkstatic,
        stamp = ctx.attr.stamp,
        additional_inputs = ctx.files.additional_linker_inputs,
        output_type = output_type,
    )
    files = []
    executable = None
    if output_type == "executable":
        files.append(linking_outputs.executable)
        executable = linking_outputs.executable  # Set executable for bazel run
    elif output_type == "dynamic_library":
        files.append(linking_outputs.library_to_link.dynamic_library)
        files.append(linking_outputs.library_to_link.resolved_symlink_dynamic_library)

    # Return providers, add ModuleInfo provider
    providers = [
        DefaultInfo(
            files = depset(_filter_none(files)),
            executable = executable,  # This tells Bazel this is an executable target
            runfiles = ctx.runfiles(files = ctx.files.data),
        ),
        ModuleInfo(
            module_dependencies = all_module_dependencies
        )
    ]
    
    return providers

cc_module_binary = rule(
    doc = """
    Rule for compiling C++ module executables.

    The cc_module_binary rule is used to create executables containing C++ modules. It supports:
    - Compilation and linking of C++ module interface files
    - Dependency management with C++ module libraries
    - Cross-platform executable generation
    - Dynamic library or static linking options

    Example usage:
    ```starlark
    cc_module_binary(
        name = "my_app",
        srcs = ["main.cpp"],
        module_interfaces = ["app_module.ixx"],  # Optional: application-level modules
        deps = [
            "//lib:my_module_lib",
            "@some_external_lib",
        ],
        copts = ["/std:c++20"],  # MSVC
        # copts = ["-std=c++20"],  # GCC/Clang
        linkstatic = True,  # Static linking (default)
    )
    ```

    Using only module libraries (no application-level modules):
    ```starlark
    cc_module_binary(
        name = "simple_app", 
        srcs = ["main.cpp"],  # main.cpp imports modules
        deps = ["//lib:math_module"],
    )
    ```
    """,
    implementation = _cc_module_binary_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = CC_SOURCE + CC_HEADER,
            doc = """
            List of C++ source and header files.

            Contains main() function and other application logic source files, plus any private header files.
            Supported source file extensions: .cc, .cpp, .cxx, .c++
            Supported header file extensions: .h, .hh, .hpp, .ipp, .hxx, .h++
            
            Header files included in srcs are treated as private headers for the binary.
            
            Source files can:
            - Contain the main() function
            - Import modules defined in module_interfaces or deps
            - Use traditional #include header files
            """,
        ),
        "module_interfaces": attr.label_list(
            allow_files = CC_MODULE,
            doc = """
            List of application-level C++ module interface files (optional).

            Usually binary files don't need to export module interfaces, but may be useful in some cases:
            - Internal modular organization of applications
            - Interface definitions in plugin architectures
            
            Supported file extensions: .ixx, .cppm, .mpp
            Module naming and partition rules are the same as cc_module_library.
            """,
        ),
        "additional_linker_inputs": attr.label_list(
            allow_files = True,
            doc = """
            Additional linker input files.

            These files will be provided as additional inputs to the linker during the linking phase.
            For executables, commonly used for:
            - Resource files
            - Version information files
            - Linker scripts
            """,
        ),
        "deps": attr.label_list(
            allow_empty = True,
            providers = [[CcInfo], [CcInfo, ModuleInfo]],
            doc = """
            List of other C++ targets to depend on.

            Can depend on:
            - cc_module_library targets (recommended, module dependencies will be handled automatically)
            - Standard cc_library targets
            - Any target that provides CcInfo
            
            Module dependencies will be automatically propagated, ensuring all required module interface files are available.
            """,
        ),
        "data": attr.label_list(
            default = [],
            allow_files = True,
            doc = """
            List of runtime data files.

            These files will be included in the executable's runtime environment.
            Commonly used for:
            - Configuration files
            - Resource files
            - Test data
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
            Examples: ["VERSION=1.0", "RELEASE_BUILD"]
            """,
        ),
        "copts": attr.string_list(
            doc = """
            List of compilation options.

            These options will be added to the C++ compilation command. For C++ modules, you must specify a supported C++ standard:
            - MSVC: ["/std:c++20"] or ["/std:c++latest"]
            - GCC/Clang: ["-std=c++20"] or ["-std=c++23"]
            
            Other common options:
            - Optimization: ["/O2"] (MSVC) or ["-O2"] (GCC/Clang)
            - Debug: ["/Zi"] (MSVC) or ["-g"] (GCC/Clang)
            """,
        ),
        "linkopts": attr.string_list(
            doc = """
            List of linker options.

            These options will be added to the linking command.
            For executables, common options:
            - Windows: ["/SUBSYSTEM:CONSOLE"] or ["/SUBSYSTEM:WINDOWS"]
            - Linux: ["-pthread"] for multithreading support
            """,
        ),
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
        "_cc_toolchain": attr.label(
            default = "@bazel_tools//tools/cpp:current_cc_toolchain",
            doc = "Internal C++ toolchain reference for internal use.",
        ),
    },
    fragments = ["cpp"],
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    executable = True,  # This tells Bazel this rule can create executable targets
)
