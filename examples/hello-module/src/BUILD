load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_cc_module//cc_module:defs.bzl", "cc_module_library", "cc_module_binary")


cc_module_library(
    name = "std.compat",
    module_interfaces= ["std.ixx","std.compat.ixx"],
    module_dependencies = {
        "std.compat": ["std"],
    },
    features = ["cpp_modules"],
    visibility = ["//visibility:public"]
)


cc_module_library(
    name = "module1",
    module_interfaces= ["module1/module1.ixx"],
    features = ["cpp_modules"],
    visibility = ["//visibility:public"]
)

cc_module_library(
    name = "module2",
    module_interfaces = [
        "module2/module2.ixx",
        "module2/module2-part.ixx",
    ],
    module_dependencies = {
        "module2": ["module2:part"],
    },
    includes = ["."],  # Include directory for module2
    hdrs = ["module2/header_only.hpp"],  # Include the header-only library
    srcs = glob(["module2/**/*.cpp"]),
    deps = [":module1"],
    features = ["cpp_modules"],
    visibility = ["//visibility:public"]
)


cc_module_library(
    name = "module3",
    module_interfaces = ["module3/module3.ixx"],
    srcs = ["module3/module3_impl.cpp"],
    deps = [
        ":module1",
        ":module2",
    ],
    features = ["cpp_modules"],
    visibility = ["//visibility:public"]
)

cc_library(
    name = "application",
    deps = [
        ":module1",
        ":module2",
        ":module3",
    ],
    features = ["cpp_modules"],
)

cc_module_binary(
    name = "main",
    srcs = ["main.cpp"],
    linkstatic = True,
    deps = [
        ":std.compat",
        ":module1",
        ":module2",
        ":module3",
    ],
    features = ["cpp_modules"],
)
