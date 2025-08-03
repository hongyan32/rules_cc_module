# @unused
load("@rules_cc//cc:defs.bzl", "cc_library", "cc_binary")
load("@rules_cc_module//cc_module:defs.bzl", "cc_module_library", "cc_module_binary")

config_setting(
    name = "debug_mode",
    values = {"compilation_mode": "dbg"},
)
config_setting(
    name = "opt_mode",
    values = {"compilation_mode": "opt"},
)

cc_binary(
    name = "scan_module_deps",
    srcs = ["scan_module_deps.cpp"] ,
    includes = ["."], 
    copts = [
        "/std:c++latest",
    ],
    linkstatic = True,
    features = ["cpp_modules"],
    visibility = ["//visibility:public"]
)
