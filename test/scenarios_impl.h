#pragma once

#include <iostream>
#include <string>
#include <typeinfo>

// =================================================================
// ===== 情况 1: 模板函数及其特化
// =================================================================

template<typename T>
void inner_func(T val) {
    std::cout << "    -> called generic inner_func\n";
}

// 使用 inline 来避免 ODR (One Definition Rule) 错误
template<>
inline void inner_func<std::string>(std::string val) {
    std::cout << "    -> called SPECIALIZED inner_func\n";
}

// =================================================================
// ===== 情况 2: 模板类及其完整特化
// =================================================================

template<typename T>
struct FullClassHelper {
    void do_work() {
        std::cout << "    -> used generic FullClassHelper\n";
    }
};

// 完整的类特化
template<>
struct FullClassHelper<std::string> {
    void do_work() {
        std::cout << "    -> used SPECIALIZED FullClassHelper\n";
    }
};

// =================================================================
// ===== 情况 3: 模板类及其成员函数特化
// =================================================================

template<typename T>
struct MemberHelper {
    T prefix;
    MemberHelper() : prefix(T()) {
    }
    void do_work() {
        std::cout << "#" << prefix << "    -> used generic MemberHelper::do_work\n";
    }
};

// 成员函数的特化，同样需要 inline
template<>
inline void MemberHelper<std::string>::do_work() {
    std::cout << "#" << prefix << "    -> used SPECIALIZED MemberHelper::do_work\n";
}

// =================================================================
// ===== 情况 4: 模板类及其模板成员函数特化
// =================================================================

template<typename T>
struct TplMemberHelper {
    T prefix;
    TplMemberHelper(T val) : prefix(val) {
    }
    template<typename U>
    void do_work(U val) {
        std::cout << "#" << prefix << "    -> used generic TplMemberHelper::do_work with value: " << val << "\n";
    }
};

// 完整的类特化
template<>
struct TplMemberHelper<std::string> {
    std::string prefix;
    TplMemberHelper(std::string val) : prefix(val) {
    }
    template<typename U>
    void do_work(U val) {
        std::cout << "#" << prefix << "    -> used Class SPECIALIZED TplMemberHelper with value: " << val << "\n";
    }
};

// 成员函数的特化，同样需要 inline
template<>
inline void TplMemberHelper<std::string>::do_work<std::string>(std::string val) {
    std::cout << "#" << prefix << "    -> used Class::Member SPECIALIZED TplMemberHelper::do_work with value: " << val << "\n";
}