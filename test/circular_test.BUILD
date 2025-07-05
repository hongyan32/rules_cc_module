# Test with circular dependency (should fail)
cc_module_library(
    name = "circular_test_lib", 
    module_interfaces = [
        "test_base1.ixx",
        "test_base2.ixx",
    ],
    module_dependencies = {
        # This creates a circular dependency
        "test_base1": ["test_base2"],
        "test_base2": ["test_base1"],
    },
    copts = [
        "/std:c++latest",
    ],
    features = ["cpp_modules"],
    tags = ["manual"],  # Don't include in wildcard builds
)
