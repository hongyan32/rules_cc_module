"""Main exports for cc_module rules."""

load("//cc_module:cc_module_rules.bzl", 
    _cc_module_library = "cc_module_library", 
     _cc_module_binary = "cc_module_binary"
)

# Re-export the rules
cc_module_library = _cc_module_library
cc_module_binary = _cc_module_binary
