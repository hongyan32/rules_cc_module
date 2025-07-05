# Module Dependencies Test

This directory contains tests for the parallel compilation feature implemented via `module_dependencies`.

## Test Cases

### 1. `parallel_test_lib` - Module Name Dependencies
Tests dependency declaration using module names:
```starlark
module_dependencies = {
    "test_derived": ["test_base1", "test_base2"],
    "test_main": ["test_derived"],
}
```

Expected compilation order:
- Layer 1: `test_base1.ixx`, `test_base2.ixx` (parallel)
- Layer 2: `test_derived.ixx` (after layer 1)
- Layer 3: `test_main.ixx` (after layer 2)

### 2. `parallel_test_lib_filename` - File Name Dependencies
Tests dependency declaration using file names:
```starlark
module_dependencies = {
    "test_derived.ixx": ["test_base1.ixx", "test_base2.ixx"],
    "test_main.ixx": ["test_derived.ixx"],
}
```

### 3. `parallel_test_lib_mixed` - Mixed Dependencies
Tests mixed usage of module names and file names:
```starlark
module_dependencies = {
    "test_derived": ["test_base1.ixx", "test_base2"],  # Mixed
    "test_main.ixx": ["test_derived"],                 # File depends on module
}
```

## Module Structure

The test modules form a dependency chain:
```
test_base1 (no deps)    test_base2 (no deps)
    \                      /
     \                    /
      \                  /
       test_derived (imports both)
              |
         test_main (imports test_derived)
```

## Benefits Demonstrated

1. **Parallel Compilation**: `test_base1` and `test_base2` can compile simultaneously
2. **Dependency Respect**: Later modules wait for their dependencies 
3. **Flexibility**: Both file names and module names work as dependency keys
4. **Backward Compatibility**: Original functionality preserved when no dependencies declared

## Usage

```bash
# Build with parallel compilation
bazel build //test:parallel_test

# Build with file-name based dependencies  
bazel build //test:parallel_test_filename

# Build with mixed dependencies
bazel build //test:parallel_test_lib_mixed
```
