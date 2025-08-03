/**
 * C++ 版本的模块依赖分析工具
 * 用于快速扫描 C++20 模块文件并分析依赖关系,然后更新 BUILD 文件
 */

#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <regex>
#include <filesystem>
#include <chrono>
#include <thread>
#include <future>
#include <algorithm>
#include <sstream>

namespace fs = std::filesystem;

struct ModuleInfo {
    std::string name;
    std::vector<std::string> imports;
    std::string file_path;
    bool filename_valid = true;
    std::string expected_filename;
};

struct BuildTarget {
    std::string name;
    std::string type; // cc_module_library or cc_module_binary
    std::vector<std::string> module_interfaces;
    std::unordered_map<std::string, std::vector<std::string>> module_dependencies;
};

class ModuleScanner {
private:
    // 预编译正则表达式以提高性能
    static std::regex export_module_regex;
    static std::regex import_module_regex;
    static std::regex export_import_regex;
    static std::regex import_header_regex;
    static std::regex build_target_regex;
    static std::regex module_interfaces_regex;
    static std::regex module_dependencies_regex;
    
    std::unordered_map<std::string, ModuleInfo> modules;
    std::unordered_map<std::string, std::vector<std::string>> module_deps;
    std::unordered_map<std::string, BuildTarget> build_targets;
    
    static constexpr size_t MAX_READ_SIZE = 8192; // 只读取前8KB
    
public:
    /**
     * 验证文件名和模块名的对应关系
     * 规则：core.ixx -> core, core-config.ixx -> core:config
     */
    bool validateFilenameModuleName(const std::string& filename, const std::string& module_name, std::string& expected_filename) {
        // 移除 .ixx 扩展名
        std::string base_name = filename;
        if (base_name.ends_with(".ixx")) {
            base_name = base_name.substr(0, base_name.length() - 4);
        }
        
        // 将模块名转换为期望的文件名（: 替换为 -）
        expected_filename = module_name;
        std::replace(expected_filename.begin(), expected_filename.end(), ':', '-');
        expected_filename += ".ixx";
        
        // 检查是否匹配
        return base_name == expected_filename.substr(0, expected_filename.length() - 4);
    }
    
    /**
     * 从单个 .ixx 文件中提取模块信息
     */
    ModuleInfo extractModuleInfo(const fs::path& file_path) {
        ModuleInfo info;
        info.file_path = file_path.string();
        
        std::ifstream file(file_path);
        if (!file.is_open()) {
            std::cerr << "无法打开文件: " << file_path << std::endl;
            return info;
        }
        
        // 只读取前8KB内容
        std::string content;
        content.resize(MAX_READ_SIZE);
        file.read(content.data(), MAX_READ_SIZE);
        content.resize(file.gcount());
        
        // 提取 export module 声明
        std::smatch match;
        if (std::regex_search(content, match, export_module_regex)) {
            info.name = match[1].str();
            
            // 验证文件名和模块名的对应关系
            std::string filename = file_path.filename().string();
            info.filename_valid = validateFilenameModuleName(filename, info.name, info.expected_filename);
            
            if (!info.filename_valid) {
                std::cerr << "警告: 文件名不符合规范" << std::endl;
                std::cerr << "  文件: " << file_path << std::endl;
                std::cerr << "  模块名: " << info.name << std::endl;
                std::cerr << "  期望文件名: " << info.expected_filename << std::endl;
                std::cerr << "  实际文件名: " << filename << std::endl;
                std::cerr << std::endl;
            }
        }
        
        // 提取所有 import 语句
        std::sregex_iterator iter(content.begin(), content.end(), import_module_regex);
        std::sregex_iterator end;
        
        for (; iter != end; ++iter) {
            std::string import_name = iter->str(1);
            if (!import_name.empty() && 
                !import_name.ends_with(".h") && 
                !import_name.ends_with(".hpp")) {
                info.imports.push_back(import_name);
            }
        }
        
        // 提取 export import 语句
        iter = std::sregex_iterator(content.begin(), content.end(), export_import_regex);
        for (; iter != end; ++iter) {
            std::string import_name = iter->str(1);
            if (!import_name.empty() && 
                !import_name.ends_with(".h") && 
                !import_name.ends_with(".hpp")) {
                info.imports.push_back(import_name);
            }
        }
        
        // 去除重复的导入
        std::sort(info.imports.begin(), info.imports.end());
        info.imports.erase(std::unique(info.imports.begin(), info.imports.end()), info.imports.end());
        
        return info;
    }
    
    /**
     * 扫描项目目录中的所有 .ixx 文件
     */
    void scanProjectModules(const fs::path& project_root) {
        std::vector<fs::path> ixx_files;
        
        // 收集所有 .ixx 文件
        for (const auto& entry : fs::recursive_directory_iterator(project_root)) {
            if (entry.is_regular_file() && entry.path().extension() == ".ixx") {
                ixx_files.push_back(entry.path());
            }
        }
        
        std::cout << "找到 " << ixx_files.size() << " 个 .ixx 文件" << std::endl;
        
        // 使用多线程并行处理文件
        const size_t num_threads = std::min(std::thread::hardware_concurrency(), 
                                           static_cast<unsigned int>(ixx_files.size()));
        std::vector<std::future<std::vector<ModuleInfo>>> futures;
        
        // 将文件分组分配给不同线程
        size_t chunk_size = ixx_files.size() / num_threads;
        size_t remainder = ixx_files.size() % num_threads;
        
        size_t start = 0;
        for (size_t i = 0; i < num_threads; ++i) {
            size_t end = start + chunk_size + (i < remainder ? 1 : 0);
            
            auto future = std::async(std::launch::async, [this, &ixx_files, start, end]() {
                std::vector<ModuleInfo> results;
                for (size_t j = start; j < end; ++j) {
                    auto info = extractModuleInfo(ixx_files[j]);
                    if (!info.name.empty()) {
                        results.push_back(std::move(info));
                    }
                }
                return results;
            });
            
            futures.push_back(std::move(future));
            start = end;
        }
        
        // 收集所有结果
        for (auto& future : futures) {
            auto results = future.get();
            for (auto& info : results) {
                modules[info.name] = std::move(info);
            }
        }
        
        // 处理模块依赖关系
        processModuleDependencies();
    }
    
    /**
     * 处理模块依赖关系，包括主模块和分区模块
     */
    void processModuleDependencies() {
        for (const auto& [module_name, module_info] : modules) {
            std::vector<std::string> clean_imports;
            
            // 清理导入列表，处理分区导入
            for (const auto& import : module_info.imports) {
                if (!import.empty() && import != module_name) {
                    // 如果是分区导入（以:开头），需要加上主模块名
                    if (import.starts_with(":")) {
                        // 获取当前模块的主模块名
                        std::string main_module;
                        size_t colon_pos = module_name.find(':');
                        if (colon_pos != std::string::npos) {
                            // 当前是分区模块，获取主模块名
                            main_module = module_name.substr(0, colon_pos);
                        } else {
                            // 当前是主模块
                            main_module = module_name;
                        }
                        std::string full_partition_name = main_module + import;
                        clean_imports.push_back(full_partition_name);
                    } else {
                        clean_imports.push_back(import);
                    }
                }
            }
            
            // 如果是主模块，添加所有分区模块作为依赖
            if (module_name.find(':') == std::string::npos) {
                for (const auto& [other_name, other_info] : modules) {
                    if (other_name.starts_with(module_name + ":")) {
                        clean_imports.push_back(other_name);
                    }
                }
            }
            
            // 去重并排序
            if (!clean_imports.empty()) {
                std::sort(clean_imports.begin(), clean_imports.end());
                clean_imports.erase(std::unique(clean_imports.begin(), clean_imports.end()), 
                                  clean_imports.end());
                module_deps[module_name] = std::move(clean_imports);
            }
        }
    }
    
    /**
     * 输出依赖关系到 JSON 文件
     */
    void outputToJson(const fs::path& output_file) {
        std::ofstream file(output_file);
        if (!file.is_open()) {
            std::cerr << "无法创建输出文件: " << output_file << std::endl;
            return;
        }
        
        file << "{\n";
        file << "  \"module_dependencies\": {\n";
        
        bool first = true;
        for (const auto& [module_name, deps] : module_deps) {
            if (!first) file << ",\n";
            first = false;
            
            file << "    \"" << module_name << "\": [";
            for (size_t i = 0; i < deps.size(); ++i) {
                if (i > 0) file << ", ";
                file << "\"" << deps[i] << "\"";
            }
            file << "]";
        }
        
        file << "\n  },\n";
        file << "  \"modules\": {\n";
        
        first = true;
        for (const auto& [module_name, module_info] : modules) {
            if (!first) file << ",\n";
            first = false;
                 file << "    \"" << module_name << "\": {\n";
        file << "      \"file_path\": \"" << module_info.file_path << "\",\n";
        file << "      \"filename_valid\": " << (module_info.filename_valid ? "true" : "false") << ",\n";
        if (!module_info.filename_valid) {
            file << "      \"expected_filename\": \"" << module_info.expected_filename << "\",\n";
        }
        file << "      \"imports\": [";
        for (size_t i = 0; i < module_info.imports.size(); ++i) {
            if (i > 0) file << ", ";
            file << "\"" << module_info.imports[i] << "\"";
        }
        file << "]\n";
        file << "    }";
        }
        
        file << "\n  }\n";
        file << "}\n";
    }
    
    /**
     * 打印统计信息
     */
    void printStats() {
        std::cout << "模块统计信息:" << std::endl;
        std::cout << "  总模块数: " << modules.size() << std::endl;
        std::cout << "  有依赖的模块数: " << module_deps.size() << std::endl;
        
        size_t total_deps = 0;
        size_t invalid_filenames = 0;
        for (const auto& [name, deps] : module_deps) {
            total_deps += deps.size();
        }
        
        for (const auto& [name, info] : modules) {
            if (!info.filename_valid) {
                invalid_filenames++;
            }
        }
        
        std::cout << "  总依赖数: " << total_deps << std::endl;
        std::cout << "  文件名不规范的模块数: " << invalid_filenames << std::endl;
        
        if (invalid_filenames > 0) {
            std::cout << std::endl << "文件名不规范的模块列表:" << std::endl;
            for (const auto& [name, info] : modules) {
                if (!info.filename_valid) {
                    std::cout << "  模块 " << name << " -> 期望文件名: " << info.expected_filename 
                              << ", 实际文件: " << fs::path(info.file_path).filename().string() << std::endl;
                }
            }
        }
    }
    
    const std::unordered_map<std::string, std::vector<std::string>>& getDependencies() const {
        return module_deps;
    }
    
    /**
     * 解析 BUILD 文件中的 cc_module_library 和 cc_module_binary 目标
     */
    void parseBuildFile(const fs::path& build_file_path) {
        std::ifstream file(build_file_path);
        if (!file.is_open()) {
            std::cerr << "无法打开 BUILD 文件: " << build_file_path << std::endl;
            return;
        }
        
        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        
        // 查找所有的 cc_module_library 和 cc_module_binary 目标
        std::sregex_iterator targets_iter(content.begin(), content.end(), build_target_regex);
        std::sregex_iterator targets_end;
        
        for (; targets_iter != targets_end; ++targets_iter) {
            std::string target_type = targets_iter->str(1);
            std::string target_name = targets_iter->str(2);
            
            BuildTarget target;
            target.name = target_name;
            target.type = target_type;
            
            // 找到目标的完整内容（匹配括号）
            size_t start_pos = targets_iter->position();
            size_t pos = start_pos;
            int paren_count = 0;
            bool found_open = false;
            
            while (pos < content.length()) {
                if (content[pos] == '(') {
                    paren_count++;
                    found_open = true;
                } else if (content[pos] == ')') {
                    paren_count--;
                    if (found_open && paren_count == 0) {
                        break;
                    }
                }
                pos++;
            }
            
            if (paren_count == 0) {
                std::string target_content = content.substr(start_pos, pos - start_pos + 1);
                
                // 解析 module_interfaces
                std::smatch interfaces_match;
                if (std::regex_search(target_content, interfaces_match, module_interfaces_regex)) {
                    std::string interfaces_str = interfaces_match[1].str();
                    parseModuleInterfaces(interfaces_str, target, build_file_path.parent_path());
                }
                
                build_targets[target_name] = std::move(target);
            }
        }
        
        std::cout << "找到 " << build_targets.size() << " 个构建目标" << std::endl;
    }
    
    /**
     * 解析 module_interfaces 字符串
     */
    void parseModuleInterfaces(const std::string& interfaces_str, BuildTarget& target, const fs::path& project_root) {
        if (interfaces_str.find("glob(") != std::string::npos) {
            // 处理 glob 表达式，支持多个 glob 模式
            std::regex glob_pattern(R"(glob\(\s*\[\s*([^\]]+)\s*\]\s*\))");
            std::smatch glob_match;

            if (std::regex_search(interfaces_str, glob_match, glob_pattern)) {
                std::string glob_content = glob_match[1].str();
                
                // 提取所有被引号包围的 glob 表达式
                std::regex glob_expr_pattern(R"(\"([^\"]+)\")");
                std::sregex_iterator glob_iter(glob_content.begin(), glob_content.end(), glob_expr_pattern);
                std::sregex_iterator glob_end;

                for (; glob_iter != glob_end; ++glob_iter) {
                    std::string glob_expr = glob_iter->str(1);
                    processGlobExpression(glob_expr, target, project_root);
                }
            }
        } else {
            // 处理直接列出的文件
            std::regex file_pattern(R"(\"([^\"]+\.ixx)\")");
            std::sregex_iterator file_iter(interfaces_str.begin(), interfaces_str.end(), file_pattern);
            std::sregex_iterator file_end;

            for (; file_iter != file_end; ++file_iter) {
                target.module_interfaces.push_back(file_iter->str(1));
            }
        }
    }
    
    /**
     * 处理单个 glob 表达式
     */
    void processGlobExpression(const std::string& glob_expr, BuildTarget& target, const fs::path& project_root) {
        // 支持 "qmt/*.ixx" 和 "qmt/**/*.ixx" 两种格式
        constexpr std::string_view suffix = "*.ixx";
        constexpr std::string_view suffix_recursive = "**/*.ixx";
        
        if (glob_expr.ends_with(suffix_recursive)) {
            // 递归所有子目录
            std::string dir_path = glob_expr.substr(0, glob_expr.length() - suffix_recursive.length());
            if (dir_path.ends_with("/")) {
                dir_path = dir_path.substr(0, dir_path.length() - 1);
            }
            fs::path full_dir_path = project_root / dir_path;
            if (fs::exists(full_dir_path)) {
                for (const auto& entry : fs::recursive_directory_iterator(full_dir_path)) {
                    if (entry.is_regular_file() && entry.path().extension() == ".ixx") {
                        fs::path rel_path = fs::relative(entry.path(), project_root);
                        target.module_interfaces.push_back(rel_path.string());
                    }
                }
            }
        } else if (glob_expr.ends_with(suffix)) {
            // 单层目录
            std::string dir_path = glob_expr.substr(0, glob_expr.length() - suffix.length());
            if (dir_path.ends_with("/")) {
                dir_path = dir_path.substr(0, dir_path.length() - 1);
            }
            fs::path full_dir_path = project_root / dir_path;
            if (fs::exists(full_dir_path)) {
                for (const auto& entry : fs::directory_iterator(full_dir_path)) {
                    if (entry.path().extension() == ".ixx") {
                        fs::path rel_path = fs::relative(entry.path(), project_root);
                        target.module_interfaces.push_back(rel_path.string());
                    }
                }
            }
        }
    }
    
    /**
     * 计算每个 BUILD 目标的模块依赖
     */
    void calculateTargetDependencies(const fs::path& project_root) {
        for (auto& [target_name, target] : build_targets) {
            std::cout << "处理目标: " << target_name << std::endl;
            
            for (const auto& interface_file : target.module_interfaces) {
                fs::path file_path = project_root / "src" / interface_file;
                
                if (fs::exists(file_path)) {
                    ModuleInfo info = extractModuleInfo(file_path);
                    
                    if (!info.name.empty()) {
                        // 使用 module_deps 中的结果，这里已经处理了分区模块的依赖
                        auto it = module_deps.find(info.name);
                        if (it != module_deps.end()) {
                            target.module_dependencies[info.name] = it->second;
                        }
                    }
                }
            }
        }
    }
    
    /**
     * 更新 BUILD 文件
     */
    void updateBuildFile(const fs::path& build_file_path) {
        std::ifstream file(build_file_path);
        if (!file.is_open()) {
            std::cerr << "无法打开 BUILD 文件: " << build_file_path << std::endl;
            return;
        }
        
        std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        file.close();
        
        std::string original_content = content;
        std::vector<std::string> updated_targets;
        
        for (const auto& [target_name, target] : build_targets) {
            if (target.module_dependencies.empty()) {
                continue;
            }
            
            // 构建新的 module_dependencies 字符串
            std::ostringstream deps_stream;
            deps_stream << "module_dependencies = {\n";
            
            // 检查是否有文件名不规范的模块
            bool has_invalid_filenames = false;
            std::vector<std::string> invalid_modules;
            
            for (const auto& [module_name, module_deps] : target.module_dependencies) {
                auto module_it = modules.find(module_name);
                if (module_it != modules.end() && !module_it->second.filename_valid) {
                    has_invalid_filenames = true;
                    invalid_modules.push_back(module_name + " (期望: " + module_it->second.expected_filename + ")");
                }
                
                deps_stream << "        \"" << module_name << "\": [";
                for (size_t i = 0; i < module_deps.size(); ++i) {
                    if (i > 0) deps_stream << ", ";
                    deps_stream << "\"" << module_deps[i] << "\"";
                }
                deps_stream << "],\n";
            }
            
            deps_stream << "    }";
            
            // 如果有文件名不规范的模块，添加注释
            if (has_invalid_filenames) {
                deps_stream << ", # 警告: 以下模块文件名不规范: ";
                for (size_t i = 0; i < invalid_modules.size(); ++i) {
                    if (i > 0) deps_stream << ", ";
                    deps_stream << invalid_modules[i];
                }
            }
            
            deps_stream << ",";
            std::string new_module_deps = deps_stream.str();
            
            // 查找目标的位置
            std::string target_pattern = "(" + target.type + R"()\s*\(\s*name\s*=\s*\")" + target_name + "\"";
            std::regex target_regex(target_pattern);
            std::smatch target_match;
            
            if (std::regex_search(content, target_match, target_regex)) {
                size_t start_pos = target_match.position();
                size_t pos = start_pos;
                int paren_count = 0;
                bool found_open = false;
                
                // 找到目标的完整内容
                while (pos < content.length()) {
                    if (content[pos] == '(') {
                        paren_count++;
                        found_open = true;
                    } else if (content[pos] == ')') {
                        paren_count--;
                        if (found_open && paren_count == 0) {
                            break;
                        }
                    }
                    pos++;
                }
                
                if (paren_count == 0) {
                    std::string target_content = content.substr(start_pos, pos - start_pos + 1);
                    
                    // 检查是否已存在 module_dependencies
                    std::regex existing_deps_regex(R"(module_dependencies\s*=\s*\{[^}]*\},?)");
                    std::smatch existing_match;
                    
                    if (std::regex_search(target_content, existing_match, existing_deps_regex)) {
                        // 替换现有的 module_dependencies
                        std::string old_deps = existing_match[0].str();
                        std::string new_target_content = std::regex_replace(target_content, existing_deps_regex, new_module_deps);
                        content.replace(start_pos, pos - start_pos + 1, new_target_content);
                        updated_targets.push_back("已更新 " + target_name + " 的 module_dependencies");
                    } else {
                        // 添加新的 module_dependencies
                        size_t interfaces_pos = target_content.find("module_interfaces");
                        if (interfaces_pos != std::string::npos) {
                            // 找到 module_interfaces 行的结尾
                            size_t equals_pos = target_content.find('=', interfaces_pos);
                            if (equals_pos != std::string::npos) {
                                size_t line_pos = equals_pos + 1;
                                int depth = 0;
                                
                                while (line_pos < target_content.length()) {
                                    char c = target_content[line_pos];
                                    if (c == '[' || c == '(') {
                                        depth++;
                                    } else if (c == ']' || c == ')') {
                                        depth--;
                                    } else if (c == ',' && depth == 0) {
                                        // 找到行结尾
                                        std::string interfaces_line = target_content.substr(interfaces_pos, line_pos - interfaces_pos + 1);
                                        std::string new_target_content = target_content;
                                        new_target_content.replace(interfaces_pos, line_pos - interfaces_pos + 1, 
                                                                 interfaces_line + "\n    " + new_module_deps);
                                        content.replace(start_pos, pos - start_pos + 1, new_target_content);
                                        updated_targets.push_back("已添加 " + target_name + " 的 module_dependencies");
                                        break;
                                    }
                                    line_pos++;
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // 如果内容有变化，写回文件
        if (content != original_content) {
            std::ofstream outfile(build_file_path);
            if (outfile.is_open()) {
                outfile << content;
                outfile.close();
                std::cout << "BUILD 文件已更新: " << build_file_path << std::endl;
                for (const auto& msg : updated_targets) {
                    std::cout << "  " << msg << std::endl;
                }
            } else {
                std::cerr << "无法写入 BUILD 文件: " << build_file_path << std::endl;
            }
        } else {
            std::cout << "BUILD 文件无需更新" << std::endl;
        }
    }
};

// 静态成员初始化
std::regex ModuleScanner::export_module_regex(R"(export\s+module\s+([a-zA-Z_][a-zA-Z0-9_.:]*)\s*;)");
std::regex ModuleScanner::import_module_regex(R"(import\s+([a-zA-Z_:][a-zA-Z0-9_.:]*)\s*;)");
std::regex ModuleScanner::export_import_regex(R"(export\s+import\s+([a-zA-Z_:][a-zA-Z0-9_.:]*)\s*;)");
std::regex ModuleScanner::import_header_regex(R"(import\s+\"([^\"]+)\"\s*;)");
std::regex ModuleScanner::build_target_regex(R"((cc_module_library|cc_module_binary)\s*\(\s*name\s*=\s*\"([^\"]+)\")");
std::regex ModuleScanner::module_interfaces_regex(R"(module_interfaces\s*=\s*(\[[^\]]*\]|glob\([^)]*\)))");
std::regex ModuleScanner::module_dependencies_regex(R"(module_dependencies\s*=\s*\{[^}]*\})");

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cout << "用法: " << argv[0] << " <项目根目录>" << std::endl;
        return 1;
    }
    
    fs::path project_root(argv[1]);
    
    if (!fs::exists(project_root)) {
        std::cerr << "项目目录不存在: " << project_root << std::endl;
        return 1;
    }
    
    // 查找 BUILD 文件：先查找 src/BUILD，如果不存在则查找根目录下的 BUILD
    fs::path build_file_path = project_root / "src" / "BUILD";
    if (!fs::exists(build_file_path)) {
        build_file_path = project_root / "BUILD";
        if (!fs::exists(build_file_path)) {
            std::cerr << "未找到 BUILD 文件，请检查项目结构" << std::endl;
            return 1;
        }
    }
    
    std::cout << "C++ 模块依赖分析工具" << std::endl;
    std::cout << "项目目录: " << project_root << std::endl;
    std::cout << "BUILD 文件: " << build_file_path << std::endl;
    std::cout << "使用线程数: " << std::thread::hardware_concurrency() << std::endl;
    std::cout << "=" << std::string(60, '=') << std::endl;
    
    auto start_time = std::chrono::high_resolution_clock::now();
    
    ModuleScanner scanner;
    
    // 1. 解析 BUILD 文件
    std::cout << "1. 解析 BUILD 文件..." << std::endl;
    scanner.parseBuildFile(build_file_path);
    
    // 2. 扫描模块依赖关系
    std::cout << "\n2. 分析模块依赖关系..." << std::endl;
    scanner.scanProjectModules(project_root);
    
    // 3. 计算每个目标的模块依赖
    std::cout << "\n3. 计算每个 target 的 module_dependencies..." << std::endl;
    scanner.calculateTargetDependencies(project_root);
    
    // 4. 更新 BUILD 文件
    std::cout << "\n4. 更新 BUILD 文件..." << std::endl;
    scanner.updateBuildFile(build_file_path);
    
    auto end_time = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time);
    
    std::cout << "\n总耗时: " << duration.count() << " 毫秒" << std::endl;
    
    scanner.printStats();
    
    std::cout << "BUILD 文件更新完成！" << std::endl;
    
    return 0;
}
