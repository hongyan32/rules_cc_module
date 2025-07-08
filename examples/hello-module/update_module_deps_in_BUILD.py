#!/usr/bin/env python3
"""
Scan all .ixx C++20 module files in the project, automatically update module_dependencies in the BUILD file.
"""

import os
import re
import json
from pathlib import Path
from typing import Dict, List, Set, Tuple

def extract_module_info(file_path: Path) -> tuple:
    """
    Extract module information from a .ixx file.
    Returns (module_name, list of imported modules)
    """
    module_name = None
    imports = []
    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
            
        # 匹配 export module 声明
        module_pattern = r'export\s+module\s+([a-zA-Z_][a-zA-Z0-9_.:]*)\s*;'
        module_match = re.search(module_pattern, content)
        if module_match:
            module_name = module_match.group(1)
        
        # 匹配各种 import 语句
        import_patterns = [
            r'import\s+([a-zA-Z_][a-zA-Z0-9_.:]*)\s*;',      # import module_name;
            r'export\s+import\s+([a-zA-Z_][a-zA-Z0-9_.:]*)\s*;',  # export import std;
            r'import\s+"([^"]+)"\s*;',                       # import "header.h";
        ]
        
        for pattern in import_patterns:
            import_matches = re.findall(pattern, content)
            for match in import_matches:
                # 包含 std 模块，但过滤头文件
                if not match.endswith('.h') and not match.endswith('.hpp'):
                    imports.append(match)
                    
    except Exception as e:
        print(f"Error reading {file_path}: {e}")
        
    return module_name, imports

def scan_project_modules(project_root: str) -> Dict[str, List[str]]:
    """
    扫描项目目录，找到所有 .ixx 文件并分析依赖关系
    """
    project_path = Path(project_root)
    module_deps = {}
    all_modules = {}  # 存储所有模块信息：{模块名: 文件路径}
    
    # Find all .ixx files
    ixx_files = list(project_path.rglob("*.ixx"))
    
    print(f"找到 {len(ixx_files)} 个 .ixx 文件")
    
    # First pass: collect all module names
    for file_path in ixx_files:
        rel_path = file_path.relative_to(project_path)
        module_name, imports = extract_module_info(file_path)
        
        if module_name:
            all_modules[module_name] = str(rel_path)
    
    # Second pass: analyze dependencies and handle main modules
    for file_path in ixx_files:
        rel_path = file_path.relative_to(project_path)
        module_name, imports = extract_module_info(file_path)
        
        if module_name:
            # Clean and format imports
            clean_imports = []
            for imp in imports:
                # 移除重复和无效的导入
                if imp and imp not in clean_imports and imp != module_name:
                    clean_imports.append(imp)
            
            # If this is a main module (e.g. utils), add all partition modules as dependencies
            if ':' not in module_name:  # Main module does not have ':'
                # Find all partition modules belonging to this main module
                partitions = [mod for mod in all_modules.keys() 
                            if mod.startswith(f"{module_name}:")]
                if partitions:
                    clean_imports.extend(partitions)
            
            if clean_imports:
                # Remove duplicates and sort
                clean_imports = sorted(list(set(clean_imports)))
                module_deps[module_name] = clean_imports
    
    return module_deps

def parse_build_targets(build_file_path: Path) -> Dict[str, List[str]]:
    """
    Parse the BUILD file, extract all cc_module_library and cc_module_binary targets and their module_interfaces.
    Returns {target_name: [module_interface_files]}
    """
    target_interfaces = {}
    
    try:
        with open(build_file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Use a more robust method to match complete cc_module_library and cc_module_binary blocks
        # Find all target start positions and names
        target_pattern = r'(cc_module_library|cc_module_binary)\s*\(\s*name\s*=\s*"([^"]+)"'
        targets = []
        
        for match in re.finditer(target_pattern, content):
            target_type = match.group(1)  # cc_module_library or cc_module_binary
            target_name = match.group(2)
            start_pos = match.start()
            
            # Find the end position of this target (match parentheses)
            paren_count = 0
            i = match.end()
            while i < len(content):
                if content[i] == '(':
                    paren_count += 1
                elif content[i] == ')':
                    if paren_count == 0:
                        end_pos = i + 1
                        break
                    paren_count -= 1
                i += 1
            else:
                continue  # 没有找到匹配的结束括号
            
            target_content = content[start_pos:end_pos]
            targets.append((target_name, target_content))
        
        # Parse module_interfaces for each target
        for target_name, target_content in targets:
            # Find module_interfaces
            interfaces_pattern = r'module_interfaces\s*=\s*(\[[^\]]*\]|glob\([^)]*\))'
            interfaces_match = re.search(interfaces_pattern, target_content, re.DOTALL)
            
            if interfaces_match:
                interfaces_str = interfaces_match.group(1)
                interface_files = []
                
                # Handle glob expression
                if 'glob(' in interfaces_str:
                    # Match pattern inside glob expression
                    glob_pattern = r'glob\(\s*\[\s*"([^"]+)"\s*\]\s*\)'
                    glob_match = re.search(glob_pattern, interfaces_str)
                    if glob_match:
                        glob_expr = glob_match.group(1)
                        project_root = build_file_path.parent
                        
                        # Handle glob pattern
                        if glob_expr.endswith('*.ixx'):
                            # Remove *.ixx to get directory
                            dir_path = glob_expr[:-5]  # 移除 *.ixx
                            if dir_path.endswith('/'):
                                dir_path = dir_path[:-1]
                            
                            full_dir_path = project_root / dir_path
                            if full_dir_path.exists():
                                # Find all matching .ixx files
                                for ixx_file in full_dir_path.glob('*.ixx'):
                                    rel_path = ixx_file.relative_to(project_root)
                                    interface_files.append(str(rel_path))
                        else:
                            # Direct file path
                            interface_files.append(glob_expr)
                else:
                    # Handle directly listed files
                    file_pattern = r'"([^"]+\.ixx)"'
                    interface_files = re.findall(file_pattern, interfaces_str)
                
                if interface_files:
                    target_interfaces[target_name] = interface_files
                    
    except Exception as e:
        print(f"Error parsing BUILD file {build_file_path}: {e}")
    
    return target_interfaces

def update_build_file(build_file_path: Path, target_dependencies: Dict[str, Dict[str, List[str]]]):
    """
    Update module_dependencies in the BUILD file
    """
    try:
        with open(build_file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        original_content = content
        updated_targets = []
        
        for target_name, deps in target_dependencies.items():
            if not deps:  # 如果没有依赖，跳过
                continue
                
            # Format dependency dictionary
            deps_lines = []
            for module_name, module_deps in sorted(deps.items()):
                deps_str = ', '.join(f'"{dep}"' for dep in sorted(module_deps))
                deps_lines.append(f'        "{module_name}": [{deps_str}],')
            
            deps_content = '\n'.join(deps_lines)
            new_module_deps = f'module_dependencies = {{\n{deps_content}\n    }},'
            
            # Use a more accurate method to match and replace the target
            # First, find the start position of the target
            target_pattern = rf'(cc_module_library|cc_module_binary)\s*\(\s*name\s*=\s*"{re.escape(target_name)}"'
            target_match = re.search(target_pattern, content)
            
            if target_match:
                # Find the complete content of this target
                start_pos = target_match.start()
                paren_count = 0
                i = target_match.end()
                while i < len(content):
                    if content[i] == '(':
                        paren_count += 1
                    elif content[i] == ')':
                        if paren_count == 0:
                            end_pos = i + 1
                            break
                        paren_count -= 1
                    i += 1
                else:
                    continue
                
                target_content = content[start_pos:end_pos]
                
                # Check if module_dependencies already exists
                existing_deps_pattern = r'module_dependencies\s*=\s*\{[^}]*\},'
                existing_match = re.search(existing_deps_pattern, target_content, re.DOTALL)
                
                if existing_match:
                    # Replace existing module_dependencies
                    old_deps = existing_match.group(0)
                    new_target_content = target_content.replace(old_deps, new_module_deps)
                    content = content.replace(target_content, new_target_content)
                    updated_targets.append(f"  已更新 {target_name} 的 module_dependencies")
                else:
                    # Add new module_dependencies
                    # Insert after module_interfaces (find the complete module_interfaces line)
                    interfaces_start = target_content.find('module_interfaces')
                    if interfaces_start != -1:
                        # Find the end of the module_interfaces assignment
                        equals_pos = target_content.find('=', interfaces_start)
                        if equals_pos != -1:
                            # Look for the matching closing bracket/parenthesis and then comma
                            pos = equals_pos + 1
                            depth = 0
                            while pos < len(target_content):
                                char = target_content[pos]
                                if char in '[(':
                                    depth += 1
                                elif char in '])':
                                    depth -= 1
                                elif char == ',' and depth == 0:
                                    # Found the end of module_interfaces
                                    interfaces_line = target_content[interfaces_start:pos+1]
                                    new_target_content = target_content.replace(
                                        interfaces_line, 
                                        f'{interfaces_line}\n    {new_module_deps}'
                                    )
                                    content = content.replace(target_content, new_target_content)
                                    updated_targets.append(f"  已添加 {target_name} 的 module_dependencies")
                                    break
                                pos += 1
        
        # Only write to file if content has changed
        if content != original_content:
            with open(build_file_path, 'w', encoding='utf-8') as f:
                f.write(content)
            print(f"BUILD 文件已更新: {build_file_path}")
            for msg in updated_targets:
                print(msg)
        else:
            print("BUILD 文件无需更新")
            
    except Exception as e:
        print(f"Error updating BUILD file {build_file_path}: {e}")

def main():
    # Project root directory (same as script location)
    script_dir = Path(__file__).parent
    project_root = script_dir
    build_file_path = project_root / "src" / "BUILD"
    
    print(f"扫描项目目录: {project_root}")
    print(f"BUILD 文件路径: {build_file_path}")
    print("=" * 60)
    
    # Parse BUILD file to get target info
    print("1. 解析 BUILD 文件...")
    target_interfaces = parse_build_targets(build_file_path)
    
    print(f"找到 {len(target_interfaces)} 个 cc_module_library/cc_module_binary targets:")
    for target_name, interfaces in target_interfaces.items():
        print(f"  {target_name}: {interfaces}")
    
    print("\n" + "=" * 60)
    
    # Scan module dependencies
    print("2. 分析模块依赖关系...")
    all_module_deps = scan_project_modules(str(project_root))
    
    # For each target, calculate its required module_dependencies
    print("\n" + "=" * 60)
    print("3. 计算每个 target 的 module_dependencies...")
    
    target_dependencies = {}
    
    for target_name, interface_files in target_interfaces.items():
        target_deps = {}
        
        print(f"  处理 target: {target_name}")
        
        # Collect dependencies for all modules in this target
        for interface_file in interface_files:
            file_path = project_root / "src" / interface_file
            
            if file_path.exists():
                module_name, imports = extract_module_info(file_path)
                
                if module_name:
                    # Clean and format imports
                    clean_imports = []
                    for imp in imports:
                        # 移除重复和无效的导入
                        if imp and imp not in clean_imports and imp != module_name:
                            clean_imports.append(imp)
                    
                    # If this is a main module (e.g. utils), add all partition modules as dependencies
                    if ':' not in module_name and module_name in all_module_deps:
                        clean_imports = all_module_deps[module_name]
                    elif clean_imports:
                        # Remove duplicates and sort
                        clean_imports = sorted(list(set(clean_imports)))
                    
                    if clean_imports:
                        target_deps[module_name] = clean_imports
                        print(f"    Add dependency: {module_name} -> {clean_imports}")
        
        if target_deps:
            target_dependencies[target_name] = target_deps
            print(f"  {target_name} final dependencies:")
            for mod_name, mod_deps in target_deps.items():
                print(f"    {mod_name}: {mod_deps}")
        else:
            print(f"  {target_name}: no module dependencies")
    
    print("\n" + "=" * 60)
    print("4. 更新 BUILD 文件...")
    
    # Update BUILD file
    update_build_file(build_file_path, target_dependencies)
    
    # Save debug info to file
    output_file = script_dir / "module_dependencies.txt"
    json_file = script_dir / "module_dependencies.json"
    
    # Generate complete dependency info for debugging
    debug_info = {
        "target_interfaces": target_interfaces,
        "all_module_deps": all_module_deps,
        "target_dependencies": target_dependencies
    }
    
    with open(json_file, 'w', encoding='utf-8') as f:
        json.dump(debug_info, f, indent=2, ensure_ascii=False)
    
    print(f"\n调试信息已保存到: {json_file}")
    print("BUILD 文件更新完成！")

if __name__ == "__main__":
    main()
