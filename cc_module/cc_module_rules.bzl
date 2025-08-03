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
load("//cc_module:attrs.bzl", "CC_HEADER", "CC_MODULE", "cc_module_binary_attrs", "cc_module_library_attrs")
load("//cc_module:cc_helper.bzl", "cc_helper")
load("//cc_module:providers.bzl", "ModuleCompilationInfo", "ModuleInfo")


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

def _get_target_sub_dir(target_name):
    """Get the subdirectory part of a target name."""
    last_separator = target_name.rfind("/")
    if last_separator == -1:
        return ""
    return target_name[0:last_separator]

def _matches(extensions, target):
    """Check if target filename matches any of the given extensions."""
    for extension in extensions:
        if target.endswith(extension):
            return True
    return False

def _get_dynamic_library_for_runtime_or_none(library_to_link, link_statically):
    """Get dynamic library from library_to_link if it should be used at runtime."""
    if library_to_link.dynamic_library == None:
        return None
    if link_statically and (library_to_link.static_library != None or library_to_link.pic_static_library != None):
        return None
    return library_to_link.dynamic_library

def _get_dynamic_libraries_for_runtime(link_statically, libraries):
    """Get all dynamic libraries that are needed at runtime."""
    dynamic_libraries_for_runtime = []
    for library_to_link in libraries:
        artifact = _get_dynamic_library_for_runtime_or_none(library_to_link, link_statically)
        if artifact != None:
            dynamic_libraries_for_runtime.append(artifact)
    return dynamic_libraries_for_runtime

def _create_dynamic_libraries_copy_actions(ctx, dynamic_libraries_for_runtime):
    """Create actions to copy dynamic libraries to the binary's directory."""
    result = []
    for lib in dynamic_libraries_for_runtime:
        # If the binary and the DLL don't belong to the same package or the DLL is a source file,
        # we should copy the DLL to the binary's directory.
        if ctx.label.package != lib.owner.package or ctx.label.workspace_name != lib.owner.workspace_name or lib.is_source:
            target_name = ctx.label.name
            target_sub_dir = _get_target_sub_dir(target_name)
            copy_file_path = lib.basename
            if target_sub_dir != "":
                copy_file_path = target_sub_dir + "/" + copy_file_path
            copy = ctx.actions.declare_file(copy_file_path)
            ctx.actions.symlink(output = copy, target_file = lib, progress_message = "Copying Execution Dynamic Library")
            result.append(copy)
        else:
            # If the library is already in the same directory as the binary, we don't need to copy it,
            # but we still add it to the result.
            result.append(lib)
    return depset(result)

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
    cxx_flags.extend(ctx.attr.cxxopts)  # Rule-level C++ compilation options

    # ctx.fragments.cpp.cxxopts will be add by cc_common.compile internally, and is immutable, so we don't need to add it here    
    user_compile_flags = []
    user_compile_flags.extend(ctx.attr.copts)  # Rule-level compilation options
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
        conly_flags = ctx.attr.conlyopts,
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
    library = None  # Initialize library variable
    
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
    # Simple runfiles handling for library - just pass through data files
    runfiles = ctx.runfiles(files = ctx.files.data)
    
    providers = [
        DefaultInfo(
            files = depset(_filter_none(files)),
            runfiles = runfiles,
        ),
        CcInfo(
            compilation_context = compilation_context,
            linking_context = linking_context,
        ),
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

def _resolve_module_key(key, interface_files):
    """Resolves a module key (file name or module name) to the actual file and module name.
    
    Args:
        key: String - either a file name (e.g., "math.ixx") or module name (e.g., "math")
        interface_files: List of interface files
        
    Returns:
        tuple: (file, module_name) or (None, None) if not found
    """
    # First try to match as file name
    for file in interface_files:
        if file.basename == key:
            return file, get_module_name_from_file(file)
    
    # Then try to match as module name
    for file in interface_files:
        module_name = get_module_name_from_file(file)
        if module_name == key:
            return file, module_name
    
    return None, None

def _build_dependency_graph(interface_files, module_dependencies):
    """Builds a dependency graph from interface files and module_dependencies.
    
    Args:
        interface_files: List of interface files
        module_dependencies: Dict mapping module keys to dependency lists
        
    Returns:
        dict: Mapping from file to list of dependency files
    """
    file_to_deps = {}
    
    # Initialize all files with empty dependencies
    for file in interface_files:
        file_to_deps[file] = []
    
    # Process declared dependencies
    for module_key, dep_keys in module_dependencies.items():
        module_file, _ = _resolve_module_key(module_key, interface_files)
        if not module_file:
            # Skip unknown modules - they might be from dependencies
            continue
            
        dep_files = []
        for dep_key in dep_keys:
            dep_file, _ = _resolve_module_key(dep_key, interface_files)
            if dep_file:
                dep_files.append(dep_file)
        
        file_to_deps[module_file] = dep_files
    
    return file_to_deps

def _topological_sort(interface_files, dependency_graph):
    """Performs topological sort on module interface files based on dependency graph.
    
    Args:
        interface_files: List of interface files
        dependency_graph: Dict mapping from file to list of dependency files
        
    Returns:
        List of lists: Each inner list contains files that can be compiled in parallel
    """
    # Create a copy of the dependency graph for modification
    remaining_files = list(interface_files)
    processed = set()
    result_layers = []
    
    # Use a simple algorithm: repeatedly find files with satisfied dependencies
    max_iterations = len(interface_files) + 1  # Prevent infinite loops
    
    for _ in range(max_iterations):
        if not remaining_files:
            break
            
        # Find files with no remaining dependencies
        ready_files = []
        for file in remaining_files:
            deps = dependency_graph.get(file, [])
            deps_satisfied = True
            for dep in deps:
                if dep not in processed:
                    deps_satisfied = False
                    break
            if deps_satisfied:
                ready_files.append(file)
        
        if not ready_files:
            # This indicates a circular dependency or other issue
            # Print involved file names for easier debugging
            involved_files = [file.basename for file in remaining_files]
            fail("Circular dependency or unresolved dependencies detected. Involved files: {}. Please check your dependency declarations.".format(", ".join(involved_files)))
        
        # Add ready files to current layer
        result_layers.append(ready_files)
        
        # Mark files as processed and remove them from remaining
        for file in ready_files:
            processed.add(file)
        
        # Remove processed files from remaining list
        new_remaining = []
        for f in remaining_files:
            if f not in processed:
                new_remaining.append(f)
        remaining_files = new_remaining
    
    return result_layers

def sort_module_interface_files_with_dependencies(interface_files, module_dependencies):
    """Sorts module interface files based on explicit dependencies for parallel compilation.
    
    This function replaces the simple partition-first sorting with dependency-aware
    topological sorting, enabling parallel compilation of independent modules.
    
    Args:
        interface_files: List of interface files to sort
        module_dependencies: Dict mapping module keys to dependency lists
        
    Returns:
        List of lists: Each inner list contains files that can be compiled in parallel
    """
    if not module_dependencies:
        # Fall back to simple partition-first ordering if no dependencies declared
        return [sort_module_interface_files(interface_files)]
    
    # Build dependency graph
    dependency_graph = _build_dependency_graph(interface_files, module_dependencies)
    
    # Perform topological sort
    return _topological_sort(interface_files, dependency_graph)

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
    """Compiles multiple C++ module interface files with support for parallel compilation.

    This function now supports parallel compilation based on explicit module dependencies
    declared in the module_dependencies attribute. If module_dependencies is provided,
    modules will be compiled in topological order with parallel compilation of independent modules.
    If not provided, falls back to simple partition-first ordering for compatibility.

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

    # All module dependency information, because later compiled modules will depend on earlier modules
    all_module_compilation_infos = module_compilation_infos[:]
    
    # Get module dependencies from context if available
    module_dependencies = {}
    if hasattr(ctx.attr, "module_dependencies") and ctx.attr.module_dependencies:
        module_dependencies = ctx.attr.module_dependencies
    
    # Sort interface files based on dependencies for parallel compilation
    if module_dependencies:
        # Use dependency-aware topological sorting for parallel compilation
        compilation_layers = sort_module_interface_files_with_dependencies(interface_files, module_dependencies)
    else:
        # Fall back to simple partition-first ordering for compatibility
        sorted_files = sort_module_interface_files(interface_files)
        compilation_layers = [sorted_files]  # Single layer, sequential compilation
    
    # Compile modules layer by layer
    for layer in compilation_layers:
        # All modules in the same layer can be compiled in parallel
        # Note: Bazel will automatically parallelize these actions
        layer_module_compilation_infos = []
        for interface_file in layer:
            module_name = get_module_name_from_file(interface_file)
            
            # Compile single module interface with optimized dependency resolution
            module_compilation_info = compile_single_module_interface(
                ctx = ctx,
                cc_toolchain = cc_toolchain,
                feature_configuration = feature_configuration,
                module_name = module_name,
                interface_file = interface_file,
                module_compilation_infos = all_module_compilation_infos,
                compilation_contexts = compilation_contexts,
                current_target_headers = current_target_headers,
                module_dependencies = module_dependencies,
            )
            # Add module compilation info to current layer
            layer_module_compilation_infos.append(module_compilation_info)
        all_module_compilation_infos.extend(layer_module_compilation_infos)
        current_module_compilation_infos.extend(layer_module_compilation_infos)

    return current_module_compilation_infos

def compile_single_module_interface(ctx, cc_toolchain, feature_configuration, module_name, interface_file, module_compilation_infos, compilation_contexts, current_target_headers, module_dependencies = None):
    """
    Compiles a single module interface file, generating .ifc and .obj files.
    
    This function uses cc_common.create_compile_variables and cc_common.get_memory_inefficient_command_line
    to ensure module compilation uses the same toolchain configuration and feature flags as cc_common.compile.
    
    Optimized dependency resolution:
    - If module_dependencies is specified, only the explicitly declared dependencies will be included as inputs
    - Dependencies are resolved from both current_target_modules and module_compilation_infos
    - This reduces unnecessary file dependencies and improves build performance
    
    Args:
        ctx: Rule context
        cc_toolchain: C++ toolchain
        feature_configuration: Feature configuration
        module_name: Module name
        interface_file: Module interface file
        module_compilation_infos: List of module compilation information from dependencies
        compilation_contexts: List of compilation contexts (from dependencies)
        current_target_headers: List of header files from the current target (hdrs + private_hdrs)
        module_dependencies: Optional dict mapping module keys to dependency lists (for optimized input dependency resolution)
        
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
    all_user_compile_flags.extend(ctx.attr.cxxopts)
    all_user_compile_flags.extend(ctx.fragments.cpp.copts)
    all_user_compile_flags.extend(ctx.fragments.cpp.cxxopts)
    # Optimized module dependency resolution
    # Only include explicitly declared dependencies or all dependencies if no explicit declaration
    direct_module_dependencies = cc_helper.resolve_module_dependencies_for_compilation(
        module_name, module_dependencies, module_compilation_infos
    )
    
    # Create optimized module compilation flags based on resolved dependencies
    module_deps_depset = depset(direct = module_compilation_infos)
    # here we need to add all module dependencies, they may be indirectly referenced by current module
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
    
    # Always use param file for module compilation
    # This ensures consistent behavior and avoids command line length issues
    # Bazel will automatically create and manage the params file
    compile_args.use_param_file("@%s", use_always = True)
    compile_args.set_param_file_format("multiline")
    
    # Add base compilation options (standard options from cc_common), filter out -c file, will add later
    for option in base_compiler_options:
        # Filter out -c, /c and the file argument that follows it
        if option == "-c" or option == "/c":
            continue
        if option.endswith(".ixx") or option.endswith(".cppm") or option.endswith(".mpp"):
            continue
        compile_args.add(option)
    
    # Add module-specific output arguments
    # Note: cc_common.get_memory_inefficient_command_line already includes standard output file arguments
    # We only need to add module interface file output arguments
    if is_msvc:
        # MSVC compiler: add interface file output
        compile_args.add("/ifcOutput"+ifc_file.path)
        compile_args.add("/c", interface_file.path) 
    else:
        # GCC/Clang compilers: add module output
        compile_args.add("-fmodule-output=" + ifc_file.path)
        # Here we need to change "-c ixxfile" to "-x c++-module -c ixxfile", additionally specify module file with -x c++-module
        compile_args.add("-x" + "c++-module")
        compile_args.add("-c", interface_file.path)  # Ensure compiler knows this is a module interface file
    # Collect input files with optimized dependency resolution
    direct_inputs = [interface_file]
    transitive_inputs = []
    
    # Add only the explicitly resolved module dependency .ifc files as inputs
    # This reduces unnecessary file dependencies and improves build performance
    for module_dep in direct_module_dependencies:
        direct_inputs.append(module_dep.ifc_file)
    
    # Always include current target headers as they may be needed by module interfaces
    if current_target_headers:
        direct_inputs.extend(current_target_headers)
    
    # Create final input depset
    all_inputs = depset(
        direct = direct_inputs,
        transitive = transitive_inputs
    )
    
    # For Args objects, Bazel automatically handles param files when needed
    # The use_param_file argument can be used to control this behavior
    # Execute compilation
    # This method ensures that module interface compilation uses exactly the same toolchain settings
    # as regular C++ compilation, including all feature flags, optimization options, and platform-specific configurations
    ctx.actions.run(
        executable = c_compiler_path,
        arguments = [compile_args],
        env = env,
        inputs = all_inputs,
        outputs = [ifc_file, obj_file],  # Bazel automatically manages params file
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
    attrs = cc_module_library_attrs(),
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
    
    # ========== Module-specific handling ==========
    # Collect module compilation contexts, not including current module information yet
    module_compilation_infos = []
    for dep in ctx.attr.deps:
        if ModuleInfo in dep:
            # Extract all module compilation information from ModuleInfo
            module_compilation_infos.extend(dep[ModuleInfo].module_dependencies.to_list())

    # Compile module interfaces if present
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

    # Collect current module object files for regular compilation
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
    cxx_flags.extend(ctx.attr.cxxopts)  # Rule-level C++ compilation options

    # cxx_flags.extend(ctx.fragments.cpp.cxxopts)  # This will be added automatically
    
    user_compile_flags = []
    user_compile_flags.extend(ctx.attr.copts)  # Rule-level compilation options
    user_compile_flags.extend(get_module_compile_flags(cc_toolchain, all_module_dependencies))  # C++ module flags


    additional_make_variable_substitutions = cc_helper.get_toolchain_global_make_variables(cc_toolchain)

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
        conly_flags = ctx.attr.conlyopts,
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
    user_link_flags = cc_helper.linkopts(ctx, additional_make_variable_substitutions, cc_toolchain)

    # Handle malloc
    if ctx.attr.malloc:
        linking_contexts.append(ctx.attr.malloc[CcInfo].linking_context)

    # Determine the libraries to link in.
    # First libraries from srcs. Shared library artifacts here are substituted with mangled symlink
    # artifacts generated by getDynamicLibraryLink(). This is done to minimize number of -rpath
    # entries during linking process.
    precompiled_files = cc_helper.build_precompiled_files(ctx)
    libraries_for_current_cc_linking_context = []
    for libs in precompiled_files:
        for artifact in libs:
            if _matches([".so", ".dylib", ".dll", ".ifso", ".tbd", ".lib", ".dll.a"], artifact.basename) or cc_helper.is_valid_shared_library_artifact(artifact):
                library_to_link = cc_common.create_library_to_link(
                    actions = ctx.actions,
                    feature_configuration = feature_configuration,
                    cc_toolchain = cc_toolchain,
                    dynamic_library = artifact,
                )
                libraries_for_current_cc_linking_context.append(library_to_link)
            elif _matches([".pic.lo", ".lo", ".lo.lib"], artifact.basename):
                library_to_link = cc_common.create_library_to_link(
                    actions = ctx.actions,
                    feature_configuration = feature_configuration,
                    cc_toolchain = cc_toolchain,
                    static_library = artifact,
                    alwayslink = True,
                )
                libraries_for_current_cc_linking_context.append(library_to_link)
            elif _matches([".a", ".lib", ".pic.a", ".rlib"], artifact.basename) and not _matches([".if.lib"], artifact.basename):
                library_to_link = cc_common.create_library_to_link(
                    actions = ctx.actions,
                    feature_configuration = feature_configuration,
                    cc_toolchain = cc_toolchain,
                    static_library = artifact,
                )
                libraries_for_current_cc_linking_context.append(library_to_link)

    linker_inputs = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset(libraries_for_current_cc_linking_context),
        user_link_flags = cc_helper.linkopts(ctx, additional_make_variable_substitutions, cc_toolchain) ,
        additional_inputs = depset(cc_helper.linker_scripts(ctx)),
    )

    current_cc_linking_context = cc_common.create_linking_context(linker_inputs = depset([linker_inputs]))
    cc_info_current_cc_linking_context = cc_common.merge_cc_infos(cc_infos = [CcInfo(linking_context = current_cc_linking_context)])
    linking_contexts.append(cc_info_current_cc_linking_context.linking_context)

    linking_outputs = cc_common.link(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        # language = "c++",
        compilation_outputs = compilation_outputs,
        linking_contexts = linking_contexts,
        user_link_flags = user_link_flags,
        link_deps_statically = ctx.attr.linkstatic,
        stamp = cc_helper.is_stamping_enabled(ctx),
        additional_inputs = ctx.files.additional_linker_inputs,
        output_type = output_type,
    )

    # ========== Return providers ==========
    files = []
    executable = None
    if output_type == "executable":
        files.append(linking_outputs.executable)
        executable = linking_outputs.executable
    elif output_type == "dynamic_library":
        if linking_outputs.library_to_link.dynamic_library:
            files.append(linking_outputs.library_to_link.dynamic_library)
        if linking_outputs.library_to_link.resolved_symlink_dynamic_library:
            files.append(linking_outputs.library_to_link.resolved_symlink_dynamic_library)

    # ========== DLL copy logic (based on cc_binary's implementation) ==========
    # Determine if it is static linking mode
    is_static_mode = ctx.attr.linkstatic
    
    # Collect all dynamic libraries needed at runtime
    all_libraries = []
    
    # Collect all libraries from linking contexts
    for linking_context in linking_contexts:
        for linker_input in linking_context.linker_inputs.to_list():
            all_libraries.extend(linker_input.libraries)
    
    # If the copy_dynamic_libraries_to_binary feature is enabled, copy DLLs
    copied_runtime_dynamic_libraries = None
    if cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = "copy_dynamic_libraries_to_binary"):
        dynamic_libraries_for_runtime = _get_dynamic_libraries_for_runtime(is_static_mode, all_libraries)
        copied_runtime_dynamic_libraries = _create_dynamic_libraries_copy_actions(ctx, dynamic_libraries_for_runtime)

    # Collect runfiles
    runfiles_files = []
    runfiles_files.extend(ctx.files.data)
    
    # Collect transitive runfiles
    transitive_runfiles = []
    for dep in ctx.attr.deps:
        if DefaultInfo in dep and dep[DefaultInfo].default_runfiles:
            transitive_runfiles.append(dep[DefaultInfo].default_runfiles)

    # Add the current linking output dynamic library to runfiles
    if output_type == "executable" and linking_outputs.library_to_link:
        lib = linking_outputs.library_to_link
        if lib.dynamic_library:
            runfiles_files.append(lib.dynamic_library)
        if lib.resolved_symlink_dynamic_library:
            runfiles_files.append(lib.resolved_symlink_dynamic_library)
    
    # Use cc_helper's standard method to collect dependent dynamic libraries
    for linking_context in linking_contexts:
        dynamic_libs = cc_helper.get_dynamic_libraries_for_runtime(linking_context, is_static_mode)
        runfiles_files.extend(dynamic_libs)

    # Prepare the final file list
    final_files = list(files)
    if copied_runtime_dynamic_libraries:
        final_files.extend(copied_runtime_dynamic_libraries.to_list())

    runfiles = ctx.runfiles(
        files = runfiles_files,
    ).merge_all(transitive_runfiles)

    providers = [
        DefaultInfo(
            files = depset(final_files),
            executable = executable,
            runfiles = runfiles,
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
    attrs = cc_module_binary_attrs(),
    fragments = ["cpp"],
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    executable = True,  # This tells Bazel this rule can create executable targets
)
