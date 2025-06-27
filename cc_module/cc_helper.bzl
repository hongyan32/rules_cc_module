# Copyright 2020 The Bazel Authors. All rights reserved.
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

"""Utility functions for C++ rules."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")


CC_SOURCE = [".cc", ".cpp", ".cxx", ".c++", ".C", ".cu", ".cl"]
C_SOURCE = [".c"]
OBJC_SOURCE = [".m"]
OBJCPP_SOURCE = [".mm"]
CLIF_INPUT_PROTO = [".ipb"]
CLIF_OUTPUT_PROTO = [".opb"]
CC_HEADER = [".h", ".hh", ".hpp", ".ipp", ".hxx", ".h++", ".inc", ".inl", ".tlh", ".tli", ".H", ".tcc"]
ASSESMBLER_WITH_C_PREPROCESSOR = [".S"]
ASSEMBLER = [".s", ".asm"]
ARCHIVE = [".a", ".lib"]
PIC_ARCHIVE = [".pic.a"]
ALWAYSLINK_LIBRARY = [".lo"]
ALWAYSLINK_PIC_LIBRARY = [".pic.lo"]
SHARED_LIBRARY = [".so", ".dylib", ".dll", ".wasm"]
INTERFACE_SHARED_LIBRARY = [".ifso", ".tbd", ".lib", ".dll.a"]
OBJECT_FILE = [".o", ".obj"]
PIC_OBJECT_FILE = [".pic.o"]

CC_AND_OBJC = []
CC_AND_OBJC.extend(CC_SOURCE)
CC_AND_OBJC.extend(C_SOURCE)
CC_AND_OBJC.extend(OBJC_SOURCE)
CC_AND_OBJC.extend(OBJCPP_SOURCE)
CC_AND_OBJC.extend(CC_HEADER)
CC_AND_OBJC.extend(ASSEMBLER)
CC_AND_OBJC.extend(ASSESMBLER_WITH_C_PREPROCESSOR)

DISALLOWED_HDRS_FILES = []
DISALLOWED_HDRS_FILES.extend(ARCHIVE)
DISALLOWED_HDRS_FILES.extend(PIC_ARCHIVE)
DISALLOWED_HDRS_FILES.extend(ALWAYSLINK_LIBRARY)
DISALLOWED_HDRS_FILES.extend(ALWAYSLINK_PIC_LIBRARY)
DISALLOWED_HDRS_FILES.extend(SHARED_LIBRARY)
DISALLOWED_HDRS_FILES.extend(INTERFACE_SHARED_LIBRARY)
DISALLOWED_HDRS_FILES.extend(OBJECT_FILE)
DISALLOWED_HDRS_FILES.extend(PIC_OBJECT_FILE)

extensions = struct(
    CC_SOURCE = CC_SOURCE,
    C_SOURCE = C_SOURCE,
    CC_HEADER = CC_HEADER,
    ASSESMBLER_WITH_C_PREPROCESSOR = ASSESMBLER_WITH_C_PREPROCESSOR,
    ASSEMBLER = ASSEMBLER,
    ARCHIVE = ARCHIVE,
    PIC_ARCHIVE = PIC_ARCHIVE,
    ALWAYSLINK_LIBRARY = ALWAYSLINK_LIBRARY,
    ALWAYSLINK_PIC_LIBRARY = ALWAYSLINK_PIC_LIBRARY,
    SHARED_LIBRARY = SHARED_LIBRARY,
    OBJECT_FILE = OBJECT_FILE,
    PIC_OBJECT_FILE = PIC_OBJECT_FILE,
    CC_AND_OBJC = CC_AND_OBJC,
    DISALLOWED_HDRS_FILES = DISALLOWED_HDRS_FILES,  # Also includes VERSIONED_SHARED_LIBRARY files.
)

def _is_compilation_outputs_empty(compilation_outputs):
    return (len(compilation_outputs.pic_objects) == 0 and
            len(compilation_outputs.objects) == 0)

# This should be enough to assume if two labels are equal.
def _are_labels_equal(a, b):
    return a.name == b.name and a.package == b.package

def _map_to_list(m):
    result = []
    for k, v in m.items():
        result.append((k, v))
    return result

def _calculate_artifact_label_map(attr_list, attr_name):
    """
    Converts a label_list attribute into a list of (Artifact, Label) tuples.

    Each tuple represents an input source file and the label of the rule that generates it
    (or the label of the source file itself if it is an input file).
    """
    artifact_label_map = {}
    for attr in attr_list:
        if DefaultInfo in attr:
            for artifact in attr[DefaultInfo].files.to_list():
                if "." + artifact.extension not in CC_HEADER:
                    old_label = artifact_label_map.get(artifact, None)
                    artifact_label_map[artifact] = attr.label
                    if old_label != None and not _are_labels_equal(old_label, attr.label) and ("." + artifact.extension in CC_AND_OBJC or attr_name == "module_interfaces"):
                        fail(
                            "Artifact '{}' is duplicated (through '{}' and '{}')".format(artifact, old_label, attr),
                            attr = attr_name,
                        )
    return artifact_label_map

def _get_srcs(ctx):
    if not hasattr(ctx.attr, "srcs"):
        return []
    artifact_label_map = _calculate_artifact_label_map(ctx.attr.srcs, "srcs")
    return _map_to_list(artifact_label_map)

def _get_cpp_module_interfaces(ctx):
    if not hasattr(ctx.attr, "module_interfaces"):
        return []
    artifact_label_map = _calculate_artifact_label_map(ctx.attr.module_interfaces, "module_interfaces")
    return _map_to_list(artifact_label_map)



def _matches_extension(extension, patterns):
    for pattern in patterns:
        if extension.endswith(pattern):
            return True
    return False

def _check_file_extension(file, allowed_extensions):
    extension = "." + file.extension
    if _matches_extension(extension, allowed_extensions):
        return True
    return False

def _get_public_hdrs(ctx):
    if not hasattr(ctx.attr, "hdrs"):
        return []
    artifact_label_map = {}
    for hdr in ctx.attr.hdrs:
        if DefaultInfo in hdr:
            for artifact in hdr[DefaultInfo].files.to_list():
                if _check_file_extension(artifact, DISALLOWED_HDRS_FILES):
                    continue
                artifact_label_map[artifact] = hdr.label
    return _map_to_list(artifact_label_map)

def _is_repository_main(repository):
    return repository == ""

def _repository_exec_path(repository, sibling_repository_layout):
    if _is_repository_main(repository):
        return ""
    prefix = "external"
    if sibling_repository_layout:
        prefix = ".."
    if repository.startswith("@"):
        repository = repository[1:]
    return paths.get_relative(prefix, repository)

def _package_exec_path(ctx, package, sibling_repository_layout):
    return paths.get_relative(_repository_exec_path(ctx.label.workspace_name, sibling_repository_layout), package)

def _package_source_root(repository, package, sibling_repository_layout):
    if _is_repository_main(repository) or sibling_repository_layout:
        return package
    if repository.startswith("@"):
        repository = repository[1:]
    return paths.get_relative(paths.get_relative("external", repository), package)

def _system_include_dirs(ctx, additional_make_variable_substitutions):
    result = []
    sibling_repository_layout = ctx.configuration.is_sibling_repository_layout()
    package = ctx.label.package
    package_exec_path = _package_exec_path(ctx, package, sibling_repository_layout)
    package_source_root = _package_source_root(ctx.label.workspace_name, package, sibling_repository_layout)
    for include in ctx.attr.includes:
        includes_attr = _expand(ctx, include, additional_make_variable_substitutions)
        if includes_attr.startswith("/"):
            continue
        includes_path = paths.get_relative(package_exec_path, includes_attr)
        if not sibling_repository_layout and paths.contains_up_level_references(includes_path):
            fail("Path references a path above the execution root.", attr = "includes")

        if includes_path == ".":
            fail("'" + includes_attr + "' resolves to the workspace root, which would allow this rule and all of its " +
                 "transitive dependents to include any file in your workspace. Please include only" +
                 " what you need", attr = "includes")
        result.append(includes_path)

        # We don't need to perform the above checks against out_includes_path again since any errors
        # must have manifested in includesPath already.
        out_includes_path = paths.get_relative(package_source_root, includes_attr)
        if (ctx.configuration.has_separate_genfiles_directory()):
            result.append(paths.get_relative(ctx.genfiles_dir.path, out_includes_path))
        result.append(paths.get_relative(ctx.bin_dir.path, out_includes_path))
    return result

def _lookup_var(ctx, additional_vars, var):
    expanded_make_var_ctx = ctx.var.get(var)
    expanded_make_var_additional = additional_vars.get(var)
    if expanded_make_var_additional != None:
        return expanded_make_var_additional
    if expanded_make_var_ctx != None:
        return expanded_make_var_ctx
    fail("{}: {} not defined".format(ctx.label, "$(" + var + ")"))

def _expand_nested_variable(ctx, additional_vars, exp, execpath = True, targets = []):
    # If make variable is predefined path variable(like $(location ...))
    # we will expand it first.
    if exp.find(" ") != -1:
        if not execpath:
            if exp.startswith("location"):
                exp = exp.replace("location", "rootpath", 1)
        data_targets = []
        if ctx.attr.data != None:
            data_targets = ctx.attr.data

        # Make sure we do not duplicate targets.
        unified_targets_set = {}
        for data_target in data_targets:
            unified_targets_set[data_target] = True
        for target in targets:
            unified_targets_set[target] = True
        return ctx.expand_location("$({})".format(exp), targets = unified_targets_set.keys())

    # Recursively expand nested make variables, but since there is no recursion
    # in Starlark we will do it via for loop.
    unbounded_recursion = True

    # The only way to check if the unbounded recursion is happening or not
    # is to have a look at the depth of the recursion.
    # 10 seems to be a reasonable number, since it is highly unexpected
    # to have nested make variables which are expanding more than 10 times.
    for _ in range(10):
        exp = _lookup_var(ctx, additional_vars, exp)
        if len(exp) >= 3 and exp[0] == "$" and exp[1] == "(" and exp[len(exp) - 1] == ")":
            # Try to expand once more.
            exp = exp[2:len(exp) - 1]
            continue
        unbounded_recursion = False
        break

    if unbounded_recursion:
        fail("potentially unbounded recursion during expansion of {}".format(exp))
    return exp

def _expand(ctx, expression, additional_make_variable_substitutions, execpath = True, targets = []):
    idx = 0
    last_make_var_end = 0
    result = []
    n = len(expression)
    for _ in range(n):
        if idx >= n:
            break
        if expression[idx] != "$":
            idx += 1
            continue

        idx += 1

        # We've met $$ pattern, so $ is escaped.
        if idx < n and expression[idx] == "$":
            idx += 1
            result.append(expression[last_make_var_end:idx - 1])
            last_make_var_end = idx
            # We might have found a potential start for Make Variable.

        elif idx < n and expression[idx] == "(":
            # Try to find the closing parentheses.
            make_var_start = idx
            make_var_end = make_var_start
            for j in range(idx + 1, n):
                if expression[j] == ")":
                    make_var_end = j
                    break

            # Note we cannot go out of string's bounds here,
            # because of this check.
            # If start of the variable is different from the end,
            # we found a make variable.
            if make_var_start != make_var_end:
                # Some clarifications:
                # *****$(MAKE_VAR_1)*******$(MAKE_VAR_2)*****
                #                   ^       ^          ^
                #                   |       |          |
                #   last_make_var_end  make_var_start make_var_end
                result.append(expression[last_make_var_end:make_var_start - 1])
                make_var = expression[make_var_start + 1:make_var_end]
                exp = _expand_nested_variable(ctx, additional_make_variable_substitutions, make_var, execpath, targets)
                result.append(exp)

                # Update indexes.
                idx = make_var_end + 1
                last_make_var_end = idx

    # Add the last substring which would be skipped by for loop.
    if last_make_var_end < n:
        result.append(expression[last_make_var_end:n])

    return "".join(result)

def _check_cpp_modules(ctx, feature_configuration):
    if len(ctx.files.module_interfaces) == 0:
        return
    if not cc_common.is_enabled(
        feature_configuration = feature_configuration,
        feature_name = "cpp_modules",
    ):
        fail("to use C++ modules, the feature cpp_modules must be enabled")
    
    # 检查 C++ 标准版本 是否支持模块
    _check_cpp_standard_for_modules(ctx)


def _tool_path(cc_toolchain, tool):
    return cc_toolchain._tool_paths.get(tool, None)

def _get_toolchain_global_make_variables(cc_toolchain):
    result = {
        "CC": _tool_path(cc_toolchain, "gcc"),
        "AR": _tool_path(cc_toolchain, "ar"),
        "NM": _tool_path(cc_toolchain, "nm"),
        "LD": _tool_path(cc_toolchain, "ld"),
        "STRIP": _tool_path(cc_toolchain, "strip"),
        "C_COMPILER": cc_toolchain.compiler,
    }
    obj_copy_tool = _tool_path(cc_toolchain, "objcopy")
    if obj_copy_tool != None:
        # objcopy is optional in Crostool.
        result["OBJCOPY"] = obj_copy_tool
    gcov_tool = _tool_path(cc_toolchain, "gcov-tool")
    if gcov_tool != None:
        # gcovtool is optional in Crostool.
        result["GCOVTOOL"] = gcov_tool

    libc = cc_toolchain.libc
    if libc.startswith("glibc-"):
        # Strip "glibc-" prefix.
        result["GLIBC_VERSION"] = libc[6:]
    else:
        result["GLIBC_VERSION"] = libc

    abi_glibc_version = cc_toolchain._abi_glibc_version
    if abi_glibc_version != None:
        result["ABI_GLIBC_VERSION"] = abi_glibc_version

    abi = cc_toolchain._abi
    if abi != None:
        result["ABI"] = abi

    result["CROSSTOOLTOP"] = cc_toolchain._crosstool_top_path
    return result


# Implementation of Bourne shell tokenization.
# Tokenizes str and appends result to the options list.
def _tokenize(options, options_string):
    token = []
    force_token = False
    quotation = "\0"
    length = len(options_string)

    # Since it is impossible to modify loop variable inside loop
    # in Starlark, and also there is no while loop, I have to
    # use this ugly hack.
    i = -1
    for _ in range(length):
        i += 1
        if i >= length:
            break
        c = options_string[i]
        if quotation != "\0":
            # In quotation.
            if c == quotation:
                # End quotation.
                quotation = "\0"
            elif c == "\\" and quotation == "\"":
                i += 1
                if i == length:
                    fail("backslash at the end of the string: {}".format(options_string))
                c = options_string[i]
                if c != "\\" and c != "\"":
                    token.append("\\")
                token.append(c)
            else:
                # Regular char, in quotation.
                token.append(c)
        else:
            # Not in quotation.
            if c == "'" or c == "\"":
                # Begin single double quotation.
                quotation = c
                force_token = True
            elif c == " " or c == "\t":
                # Space not quoted.
                if force_token or len(token) > 0:
                    options.append("".join(token))
                    token = []
                    force_token = False
            elif c == "\\":
                # Backslash not quoted.
                i += 1
                if i == length:
                    fail("backslash at the end of the string: {}".format(options_string))
                token.append(options_string[i])
            else:
                # Regular char, not quoted.
                token.append(c)
    if quotation != "\0":
        fail("unterminated quotation at the end of the string: {}".format(options_string))

    if force_token or len(token) > 0:
        options.append("".join(token))


def _linkopts(ctx, additional_make_variable_substitutions, _cc_toolchain):
    linkopts = getattr(ctx.attr, "linkopts", [])
    if len(linkopts) == 0:
        return []
    targets = []
    for additional_linker_input in getattr(ctx.attr, "additional_linker_inputs", []):
        targets.append(additional_linker_input)
    tokens = []
    for linkopt in linkopts:
        expanded_linkopt = _expand(ctx, linkopt, additional_make_variable_substitutions, targets = targets)
        _tokenize(tokens, expanded_linkopt)
    return tokens


def _check_cpp_standard_for_modules(ctx):
    """检查当前的 C++ 标准设置是否支持 C++ 模块
    
    Args:
        ctx: 规则上下文
    """
    # 收集所有可能的编译标志来源
    all_flags = []
    
    # 从规则级别的 copts 收集
    if hasattr(ctx.attr, "copts"):
        all_flags.extend(ctx.attr.copts)
    
    # 从 fragments.cpp 收集全局设置
    if hasattr(ctx.fragments, "cpp"):
        cpp_fragment = ctx.fragments.cpp
        if hasattr(cpp_fragment, "copts"):
            all_flags.extend(cpp_fragment.copts)
        if hasattr(cpp_fragment, "cxxopts"):
            all_flags.extend(cpp_fragment.cxxopts)
    
    # 检查是否包含支持模块的 C++ 标准
    has_cpp_std = False
    
    for flag in all_flags:
        # 检查各种 C++ 标准标志格式
        if flag.startswith("/std:") or flag.startswith("-std="):
            has_cpp_std = True
            std_value = flag.split(":", 1)[-1] if flag.startswith("/std:") else flag.split("=", 1)[-1]
            
            # 支持模块的标准版本
            supported_versions = [
                "c++20", "c++2a",           # C++20
                "c++23", "c++2b",           # C++23  
                "c++26", "c++2c",           # C++26 (draft)
                "c++latest", "c++experimental"  # 最新版本
            ]
            
            # MSVC 特定的标准版本
            msvc_supported = [
                "c++20", "c++latest"
            ]
            
            if std_value.lower() in supported_versions or std_value.lower() in msvc_supported:
                return  # 找到支持的版本，直接返回
    
    # 如果没有显式设置 C++ 标准，暂时允许通过（可能工具链有默认设置）
    if not has_cpp_std:
        # 输出错误，提示用户可能需要指定 C++20 或更高标准
        fail("C++ modules require C++20 or later. No explicit C++ standard flag found." +
             " Please ensure your build configuration specifies a C++ standard that supports modules." +
             " Supported versions: C++20, C++23, C++latest. " + 
             "For MSVC, use /std:c++20 or /std:c++latest. " +
             "For GCC/Clang, use -std=c++20 or -std=c++23.")
    else:
        # 如果设置了标准但不支持模块，报错
        fail("C++ modules require C++20 or later. Current C++ standard may not support modules. " +
             "Supported versions: C++20, C++23, C++latest. " + 
             "For MSVC, use /std:c++20 or /std:c++latest. " +
             "For GCC/Clang, use -std=c++20 or -std=c++23.")


cc_helper = struct(
    are_labels_equal = _are_labels_equal,
    get_srcs = _get_srcs,
    calculate_artifact_label_map = _calculate_artifact_label_map,
    map_to_list = _map_to_list,
    get_cpp_module_interfaces = _get_cpp_module_interfaces,
    check_cpp_modules = _check_cpp_modules,
    get_public_hdrs = _get_public_hdrs,
    system_include_dirs = _system_include_dirs,
    is_compilation_outputs_empty = _is_compilation_outputs_empty,
    get_toolchain_global_make_variables = _get_toolchain_global_make_variables,
    linkopts = _linkopts,
)
