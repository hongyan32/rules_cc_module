"""Providers for C++ module rules."""

ModuleCompilationInfo = provider(
    doc = "C++ module compilation information",
    fields = {
        "module_name": "The name of the C++ module",
        "ixx_file": "The module interface source file (.ixx/.cppm)",
        "ifc_file": "The compiled interface file (.ifc/.pcm) for compilation dependencies",
        "obj_file": "The object file (.obj/.o) for linking",
    }
)
ModuleInfo = provider(
    doc = "C++ module information",
    fields = {
        "module_dependencies": "depset[ModuleCompilationInfo] - Direct and transitive module dependencies! ",
    }
)